package hid

import (
	"errors"
	"io/fs"
	"time"

	log "github.com/sirupsen/logrus"
)

const (
	keyboardReportLen = 8
	// Covers a host resuming from sleep (the first keystroke triggers remote
	// wakeup); older pending keystrokes are not replayed into the woken host.
	keyboardStaleAfter = 3 * time.Second
	keyboardOutboxMax  = 256
)

type kbEntry struct {
	report [keyboardReportLen]byte
	done   chan error
	since  time.Time
}

// keyboardOutbox delivers keyboard reports strictly in order. Each report is
// the full key state, and every intermediate state matters (a skipped
// down/up pair is a lost character), so nothing is merged except exact
// consecutive duplicates. Owned by the keyboard writer goroutine.
type keyboardOutbox struct {
	entries []kbEntry
	last    [keyboardReportLen]byte // latest submitted state
	now     func() time.Time
}

func newKeyboardOutbox() *keyboardOutbox {
	return &keyboardOutbox{now: time.Now}
}

func (o *keyboardOutbox) add(msg hidMsg) {
	if msg.release {
		var zero [keyboardReportLen]byte
		if o.last != zero {
			o.append(zero, nil)
		}
		return
	}

	if len(msg.report) != keyboardReportLen {
		log.Debugf("invalid keyboard event: %v", msg.report)
		notify(msg.done, ErrInvalidReport)
		return
	}

	var r [keyboardReportLen]byte
	copy(r[:], msg.report)

	if n := len(o.entries); n > 0 && msg.done == nil {
		if last := &o.entries[n-1]; last.done == nil && last.report == r {
			return // identical consecutive state: invisible to the host
		}
	}
	o.append(r, msg.done)
}

func (o *keyboardOutbox) append(r [keyboardReportLen]byte, done chan error) {
	now := o.now()
	if len(o.entries) >= keyboardOutboxMax {
		log.Warnf("keyboard outbox full (%d), keeping latest state only", len(o.entries))
		o.collapse()
	}
	o.entries = append(o.entries, kbEntry{report: r, done: done, since: now})
	o.last = r
}

// collapse keeps only the newest entry (the current key state).
func (o *keyboardOutbox) collapse() {
	n := len(o.entries)
	for i := 0; i < n-1; i++ {
		notify(o.entries[i].done, ErrReportStale)
	}
	keep := o.entries[n-1]
	keep.since = o.now()
	o.entries = append(o.entries[:0], keep)
}

func (o *keyboardOutbox) dropStale() {
	if len(o.entries) == 0 {
		return
	}
	now := o.now()
	firstFresh := 0
	for firstFresh < len(o.entries) && now.Sub(o.entries[firstFresh].since) >= keyboardStaleAfter {
		firstFresh++
	}
	switch {
	case firstFresh == 0:
		return
	case firstFresh == len(o.entries):
		log.Debugf("dropping %d stale keyboard reports, keeping latest state", len(o.entries)-1)
		o.collapse()
	default:
		log.Debugf("dropping %d stale keyboard reports", firstFresh)
		for i := 0; i < firstFresh; i++ {
			notify(o.entries[i].done, ErrReportStale)
		}
		n := copy(o.entries, o.entries[firstFresh:])
		o.entries = o.entries[:n]
	}
}

func (o *keyboardOutbox) full() bool { return len(o.entries) >= keyboardOutboxMax }

func (o *keyboardOutbox) pop(err error) {
	notify(o.entries[0].done, err)
	n := copy(o.entries, o.entries[1:])
	o.entries = o.entries[:n]
}

func (o *keyboardOutbox) flush(h *Hid) error {
	for len(o.entries) > 0 {
		err := h.WriteHid0(o.entries[0].report[:])
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				o.pop(err) // gadget absent: nothing to retry against
				continue
			}
			return err
		}
		o.pop(nil)
	}
	return nil
}
