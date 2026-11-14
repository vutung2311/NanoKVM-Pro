package hid

import (
	"errors"
	"sync"
	"sync/atomic"
	"time"

	log "github.com/sirupsen/logrus"
)

// Input delivery model
//
// Every producer (all WebSocket clients, Paste, the jiggler) submits reports to
// a per-device inbox. One writer goroutine per device drains its inbox into an
// outbox and delivers to /dev/hidgN:
//
//   - Accepting never waits on the host: the writer keeps draining the inbox
//     even while a delivery is being retried, so the WS reader never stalls.
//   - Healthy path adds no latency and loses nothing: the host polls about
//     every 1 ms; merging only happens when a backlog already exists.
//   - If the host stops polling (sleep, BIOS, hung), the pending report is
//     retried with backoff instead of being dropped.
//   - Only reports that waited longer than the device's stale window are
//     dropped, and the latest state is always delivered (no stuck keys or
//     buttons, no replayed input after the host wakes).

const (
	inboxSize = 1024

	writerRetryMin = 10 * time.Millisecond
	writerRetryMax = 100 * time.Millisecond

	// Once the host has refused reports for longer than writerIdleAfter (past
	// every stale window, so only a state sync is left), retry at
	// writerIdleRetry instead of writerRetryMax. New input brings the retry
	// back to writerRetryMin, so a waking host is still served promptly.
	writerIdleAfter = 3 * time.Second
	writerIdleRetry = time.Second

	// How long a producer waits for inbox space before its report goes to the
	// overflow slot instead. Only reached while the writer is blocked (e.g.
	// the device mutex is held during a HID mode switch).
	submitWait = 200 * time.Millisecond
)

var (
	// ErrReportStale means the report waited longer than the stale window and
	// was superseded by newer state.
	ErrReportStale = errors.New("hid report dropped: host not accepting reports")
	// ErrReportTimeout means the caller stopped waiting; the report may still
	// be delivered later.
	ErrReportTimeout = errors.New("hid report not accepted in time")
	// ErrInvalidReport means the report has an unexpected length.
	ErrInvalidReport = errors.New("invalid hid report")
)

// hidMsg is one inbox item.
type hidMsg struct {
	report  []byte
	release bool       // release all currently held keys/buttons
	done    chan error // optional; receives the delivery result exactly once
	at      time.Time  // when the producer submitted it; zero = when dequeued
}

// overflowSlot holds the newest report per class that could not be queued
// because the inbox was full. HID reports carry full button/key state, so
// keeping only the newest per class loses no state, only stale motion.
// While it holds anything, producers write here instead of the inbox so the
// writer sees reports in submission order.
type overflowSlot struct {
	mu      sync.Mutex
	release *hidMsg
	byClass map[int]hidMsg
	pending atomic.Bool
}

// put stores msg as the newest report of its class. A release supersedes
// every state stored before it.
func (s *overflowSlot) put(class int, msg hidMsg) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if msg.release {
		s.release = &msg
		clear(s.byClass)
	} else {
		if s.byClass == nil {
			s.byClass = make(map[int]hidMsg)
		}
		s.byClass[class] = msg
	}
	s.pending.Store(true)
}

// putIfPending stores msg only if the slot is already in use, so ordering is
// kept with reports that overflowed earlier. It reports whether it stored.
func (s *overflowSlot) putIfPending(class int, msg hidMsg) bool {
	if !s.pending.Load() {
		return false
	}
	s.mu.Lock()
	if !s.pending.Load() {
		s.mu.Unlock()
		return false
	}
	s.mu.Unlock()
	s.put(class, msg)
	return true
}

// take empties the slot: the release first (it is older than any state kept
// after it), then the newest state per class in class order.
func (s *overflowSlot) take() []hidMsg {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []hidMsg
	if s.release != nil {
		out = append(out, *s.release)
		s.release = nil
	}
	for class := 0; class < 2; class++ {
		if m, ok := s.byClass[class]; ok {
			out = append(out, m)
		}
	}
	clear(s.byClass)
	s.pending.Store(false)
	return out
}

// mouseClass separates relative (hidg1) from absolute (hidg2) reports so the
// overflow slot keeps the latest state of each device.
func mouseClass(report []byte) int {
	if len(report) >= 6 {
		return 1
	}
	return 0
}

// enqueue delivers msg to inbox, or to ov if the inbox stays full for
// submitWait. It never blocks longer than submitWait.
func enqueue(inbox chan<- hidMsg, ov *overflowSlot, class int, msg hidMsg) {
	if ov.putIfPending(class, msg) {
		return
	}
	select {
	case inbox <- msg:
		return
	default:
	}
	timer := time.NewTimer(submitWait)
	defer timer.Stop()
	select {
	case inbox <- msg:
	case <-timer.C:
		log.Debugf("hid inbox full, keeping newest report in overflow slot")
		ov.put(class, msg)
	}
}

func notify(done chan error, err error) {
	if done != nil {
		done <- err // buffered (cap 1)
	}
}

// outbox is a device-specific buffer of not-yet-delivered reports.
type outbox interface {
	add(msg hidMsg)
	dropStale()
	flush(h *Hid) error
	// full reports that no more input should be accepted until a flush makes
	// room; the bounded inbox (and then the producer) waits instead.
	full() bool
}

func (h *Hid) startWriters() {
	h.writersOnce.Do(func() {
		h.kbInbox = make(chan hidMsg, inboxSize)
		h.mouseInbox = make(chan hidMsg, inboxSize)
		go h.runWriter(h.kbInbox, &h.kbOverflow, newKeyboardOutbox())
		go h.runWriter(h.mouseInbox, &h.mouseOverflow, newMouseOutbox())
	})
}

func cloneReport(report []byte) []byte {
	return append([]byte(nil), report...)
}

// SubmitKeyboard queues an 8-byte keyboard report for delivery. It waits at
// most submitWait for inbox space; after that only the newest key state is
// kept until the writer catches up, so the caller (the WebSocket reader) is
// never stalled by a blocked device.
func (h *Hid) SubmitKeyboard(report []byte) {
	h.startWriters()
	enqueue(h.kbInbox, &h.kbOverflow, 0, hidMsg{report: cloneReport(report), at: time.Now()})
}

// SubmitKeyboardWait queues a keyboard report and waits until the host has
// accepted it, it was superseded (ErrReportStale), or timeout elapses
// (ErrReportTimeout). The timeout covers queueing too: if the report could
// not be queued in time it is not sent at all.
func (h *Hid) SubmitKeyboardWait(report []byte, timeout time.Duration) error {
	h.startWriters()
	timer := time.NewTimer(timeout)
	defer timer.Stop()

	if h.kbOverflow.pending.Load() {
		return ErrReportTimeout // the writer is behind; don't jump the queue
	}
	done := make(chan error, 1)
	select {
	case h.kbInbox <- hidMsg{report: cloneReport(report), done: done, at: time.Now()}:
	case <-timer.C:
		return ErrReportTimeout
	}

	select {
	case err := <-done:
		return err
	case <-timer.C:
		return ErrReportTimeout
	}
}

// SubmitMouse queues a relative (4/5-byte) or absolute (6/7-byte) mouse
// report, with the same bounded wait as SubmitKeyboard.
func (h *Hid) SubmitMouse(report []byte) {
	h.startWriters()
	enqueue(h.mouseInbox, &h.mouseOverflow, mouseClass(report), hidMsg{report: cloneReport(report), at: time.Now()})
}

// ReleaseAll queues a release of every key and button that is currently held,
// e.g. when a client disconnects mid-press. Nothing is sent if nothing is held.
func (h *Hid) ReleaseAll() {
	h.ReleaseKeyboard()
	h.ReleaseMouse()
}

// ReleaseKeyboard queues a release of every held key and modifier.
func (h *Hid) ReleaseKeyboard() {
	h.startWriters()
	enqueue(h.kbInbox, &h.kbOverflow, 0, hidMsg{release: true, at: time.Now()})
}

// ReleaseMouse queues a release of every held mouse button (both devices).
func (h *Hid) ReleaseMouse() {
	h.startWriters()
	enqueue(h.mouseInbox, &h.mouseOverflow, 0, hidMsg{release: true, at: time.Now()})
}

// runWriter is the per-device delivery loop. It returns when inbox is closed.
// ov may be nil (tests that feed the inbox directly).
func (h *Hid) runWriter(inbox <-chan hidMsg, ov *overflowSlot, ob outbox) {
	backoff := writerRetryMin
	var retryC <-chan time.Time // non-nil while a failed delivery awaits retry
	var failingSince time.Time  // zero while deliveries succeed
	idle := false               // retrying at writerIdleRetry

	for {
		if retryC == nil {
			msg, ok := <-inbox
			if !ok {
				return
			}
			ob.add(msg)
		} else {
			var in <-chan hidMsg
			if !ob.full() {
				in = inbox // stop accepting (backpressure) while full
			}
			select {
			case msg, ok := <-in:
				if !ok {
					_ = ob.flush(h) // final attempt
					return
				}
				ob.add(msg)
				if idle {
					// Fresh input while the host was away: try again soon,
					// the host may be waking up.
					idle = false
					backoff = writerRetryMin
					retryC = time.After(backoff)
				}
				continue // keep accepting until the retry timer fires
			case <-retryC:
				retryC = nil
			}
		}

		// Coalesce what is already queued (up to the outbox limit) before
		// writing. Overflowed reports are newer than anything in the inbox,
		// so they are only taken once the inbox is empty.
		closed := false
	drain:
		for !ob.full() {
			select {
			case msg, ok := <-inbox:
				if !ok {
					closed = true
					break drain
				}
				ob.add(msg)
			default:
				if ov != nil && ov.pending.Load() {
					for _, m := range ov.take() {
						ob.add(m)
					}
				}
				break drain
			}
		}

		ob.dropStale()
		err := ob.flush(h)
		switch {
		case err == nil:
			backoff = writerRetryMin
			failingSince = time.Time{}
			idle = false
		default:
			now := time.Now()
			if failingSince.IsZero() {
				failingSince = now
			}
			if errors.Is(err, ErrHostNotReady) && now.Sub(failingSince) >= writerIdleAfter {
				if !idle {
					log.Debugf("hid host unreachable for %s, retrying every %s", now.Sub(failingSince).Round(time.Second), writerIdleRetry)
				}
				idle = true
				retryC = time.After(writerIdleRetry)
			} else {
				retryC = time.After(backoff)
				backoff = min(backoff*2, writerRetryMax)
			}
		}

		if closed {
			return
		}
	}
}
