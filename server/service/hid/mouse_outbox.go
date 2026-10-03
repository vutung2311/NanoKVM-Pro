package hid

import (
	"errors"
	"io/fs"
	"time"

	log "github.com/sirupsen/logrus"
)

const (
	// Pending reports older than this are no longer replayed (no ghost clicks
	// after host sleep/BIOS); only the latest button state is delivered.
	mouseStaleAfter = time.Second
	// Upper bound on queued reports while the host is stalled.
	mouseOutboxMax = 64
)

// mouseEntry is one pending HID report. Relative entries accumulate motion
// without the ±127 limit and are split into chunks only when written.
type mouseEntry struct {
	absolute bool
	buttons  byte

	dx, dy, wheel, hwheel int // relative

	abs [7]byte // absolute: buttons, x lo/hi, y lo/hi, wheel, hwheel

	since time.Time // when this entry started waiting
}

func (e *mouseEntry) hasAbsWheel() bool {
	return e.abs[5] != 0 || e.abs[6] != 0
}

// mouseOutbox holds reports not yet accepted by the gadget. It is owned by the
// single mouse writer goroutine (see writer.go), so it needs no locking.
//
// Invariants: motion is never lost while fresh, button transitions keep their
// order, and the host always converges to the latest button state.
type mouseOutbox struct {
	entries []mouseEntry
	now     func() time.Time

	// Latest submitted state per device, used to synthesize releases.
	relButtons byte
	lastAbs    [7]byte
	absKnown   bool
}

func newMouseOutbox() *mouseOutbox {
	return &mouseOutbox{now: time.Now}
}

func parseMouseEvent(ev []byte, now time.Time) (mouseEntry, bool) {
	switch len(ev) {
	case 4, 5:
		e := mouseEntry{
			buttons: ev[0],
			dx:      int(int8(ev[1])),
			dy:      int(int8(ev[2])),
			wheel:   int(int8(ev[3])),
			since:   now,
		}
		if len(ev) == 5 {
			e.hwheel = int(int8(ev[4]))
		}
		return e, true
	case 6, 7:
		e := mouseEntry{absolute: true, buttons: ev[0], since: now}
		copy(e.abs[:], ev)
		return e, true
	default:
		return mouseEntry{}, false
	}
}

// add merges ev into the newest pending entry when that is indistinguishable
// to the host, otherwise appends it:
//   - relative, same buttons: deltas are summed
//   - absolute, same buttons, no wheel on either: latest position wins
//   - button change, mode switch, or absolute wheel tick: new entry
func (o *mouseOutbox) add(msg hidMsg) {
	if msg.release {
		o.release()
		return
	}

	now := o.now()
	e, ok := parseMouseEvent(msg.report, now)
	if !ok {
		log.Debugf("invalid mouse event: %v", msg.report)
		return
	}
	o.addEntry(e, now)
}

// release queues button-up reports for whichever device still has buttons
// held. The absolute release keeps the last position so the cursor doesn't jump.
func (o *mouseOutbox) release() {
	now := o.now()
	if o.relButtons != 0 {
		o.addEntry(mouseEntry{since: now}, now)
	}
	if o.absKnown && o.lastAbs[0] != 0 {
		e := mouseEntry{absolute: true, abs: o.lastAbs, since: now}
		e.abs[0], e.abs[5], e.abs[6] = 0, 0, 0
		o.addEntry(e, now)
	}
}

func (o *mouseOutbox) addEntry(e mouseEntry, now time.Time) {
	if e.absolute {
		o.lastAbs, o.absKnown = e.abs, true
	} else {
		o.relButtons = e.buttons
	}

	if n := len(o.entries); n > 0 {
		last := &o.entries[n-1]
		if last.absolute == e.absolute && last.buttons == e.buttons {
			if !e.absolute {
				last.dx += e.dx
				last.dy += e.dy
				last.wheel += e.wheel
				last.hwheel += e.hwheel
				return
			}
			if !last.hasAbsWheel() && !e.hasAbsWheel() {
				last.abs = e.abs
				return
			}
		}
	}

	if len(o.entries) >= mouseOutboxMax {
		log.Debugf("mouse outbox full (%d), collapsing to latest button state", len(o.entries))
		o.collapse(now)
	}
	o.entries = append(o.entries, e)
}

// collapse replaces all pending entries with a single state-sync report that
// carries the latest buttons (and absolute position) but no motion or wheel.
func (o *mouseOutbox) collapse(now time.Time) {
	sync := o.entries[len(o.entries)-1]
	sync.dx, sync.dy, sync.wheel, sync.hwheel = 0, 0, 0, 0
	sync.abs[5], sync.abs[6] = 0, 0
	sync.since = now
	o.entries = append(o.entries[:0], sync)
}

// dropStale discards entries that have waited longer than mouseStaleAfter.
// If every entry is stale, a single state-sync report is kept so the host
// still ends up with the correct button state.
func (o *mouseOutbox) dropStale() {
	if len(o.entries) == 0 {
		return
	}
	now := o.now()
	firstFresh := 0
	for firstFresh < len(o.entries) && now.Sub(o.entries[firstFresh].since) >= mouseStaleAfter {
		firstFresh++
	}
	switch {
	case firstFresh == 0:
		return
	case firstFresh == len(o.entries):
		log.Debugf("dropping %d stale mouse reports, keeping state sync", len(o.entries))
		o.collapse(now)
	default:
		log.Debugf("dropping %d stale mouse reports", firstFresh)
		n := copy(o.entries, o.entries[firstFresh:])
		o.entries = o.entries[:n]
	}
}

// full leaves one slot of headroom: release() may append two entries.
func (o *mouseOutbox) full() bool { return len(o.entries) >= mouseOutboxMax-1 }

func (o *mouseOutbox) pop() {
	n := copy(o.entries, o.entries[1:])
	o.entries = o.entries[:n]
}

// flush writes pending entries in order and stops at the first failure,
// keeping that entry (and any unsent part of it) for the next attempt.
func (o *mouseOutbox) flush(h *Hid) error {
	for len(o.entries) > 0 {
		e := &o.entries[0]

		var err error
		if e.absolute {
			err = h.WriteHid2(e.abs[:])
		} else {
			err = h.writeRelative(e)
		}

		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				// Gadget function absent (e.g. touchpad disabled): nothing to retry against.
				o.pop()
				continue
			}
			return err
		}
		o.pop()
	}
	return nil
}

// writeRelative sends e as one or more ±127 reports. After each accepted chunk
// the sent amount is subtracted from e, so a timeout mid-way only leaves the
// unsent remainder pending.
func (h *Hid) writeRelative(e *mouseEntry) error {
	var report [5]byte
	report[0] = e.buttons

	if e.dx == 0 && e.dy == 0 && e.wheel == 0 && e.hwheel == 0 {
		return h.WriteHid1(report[:])
	}

	for e.dx != 0 || e.dy != 0 || e.wheel != 0 || e.hwheel != 0 {
		cx, cy := clampInt8(e.dx), clampInt8(e.dy)
		cw, ch := clampInt8(e.wheel), clampInt8(e.hwheel)
		report[1], report[2], report[3], report[4] = byte(cx), byte(cy), byte(cw), byte(ch)

		if err := h.WriteHid1(report[:]); err != nil {
			return err
		}
		e.dx -= int(cx)
		e.dy -= int(cy)
		e.wheel -= int(cw)
		e.hwheel -= int(ch)
	}
	return nil
}
