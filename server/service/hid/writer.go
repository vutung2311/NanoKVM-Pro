package hid

import (
	"errors"
	"time"
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
		go h.runWriter(h.kbInbox, newKeyboardOutbox())
		go h.runWriter(h.mouseInbox, newMouseOutbox())
	})
}

func cloneReport(report []byte) []byte {
	return append([]byte(nil), report...)
}

// SubmitKeyboard queues an 8-byte keyboard report for delivery. It never drops.
func (h *Hid) SubmitKeyboard(report []byte) {
	h.startWriters()
	h.kbInbox <- hidMsg{report: cloneReport(report)}
}

// SubmitKeyboardWait queues a keyboard report and waits until the host has
// accepted it, it was superseded (ErrReportStale), or timeout elapses
// (ErrReportTimeout; the report stays queued).
func (h *Hid) SubmitKeyboardWait(report []byte, timeout time.Duration) error {
	h.startWriters()
	done := make(chan error, 1)
	h.kbInbox <- hidMsg{report: cloneReport(report), done: done}

	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case err := <-done:
		return err
	case <-timer.C:
		return ErrReportTimeout
	}
}

// SubmitMouse queues a relative (4/5-byte) or absolute (6/7-byte) mouse report.
func (h *Hid) SubmitMouse(report []byte) {
	h.startWriters()
	h.mouseInbox <- hidMsg{report: cloneReport(report)}
}

// ReleaseAll queues a release of every key and button that is currently held,
// e.g. when a client disconnects mid-press. Nothing is sent if nothing is held.
func (h *Hid) ReleaseAll() {
	h.startWriters()
	h.kbInbox <- hidMsg{release: true}
	h.mouseInbox <- hidMsg{release: true}
}

// runWriter is the per-device delivery loop. It returns when inbox is closed.
func (h *Hid) runWriter(inbox <-chan hidMsg, ob outbox) {
	backoff := writerRetryMin
	var retryC <-chan time.Time // non-nil while a failed delivery awaits retry

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
				continue // keep accepting until the retry timer fires
			case <-retryC:
				retryC = nil
			}
		}

		// Coalesce what is already queued (up to the outbox limit) before writing.
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
				break drain
			}
		}

		ob.dropStale()
		if err := ob.flush(h); err != nil {
			retryC = time.After(backoff)
			backoff = min(backoff*2, writerRetryMax)
		} else {
			backoff = writerRetryMin
		}

		if closed {
			return
		}
	}
}
