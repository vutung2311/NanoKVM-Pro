package hid

import (
	"errors"
	"io"
	"io/fs"
	"os"
	"testing"
	"time"
)

// ---- helpers ----

func newPipe(t *testing.T) (*os.File, *os.File) {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	t.Cleanup(func() { _ = r.Close(); _ = w.Close() })
	return r, w
}

func readExactly(t *testing.T, r *os.File, n int) []byte {
	t.Helper()
	_ = r.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		t.Fatalf("read %d bytes: %v", n, err)
	}
	return buf
}

// stallPipe fills the pipe buffer so further writes time out, simulating a
// host that stopped polling. It returns the number of filler bytes written.
func stallPipe(t *testing.T, w *os.File) int {
	t.Helper()
	junk := make([]byte, 1<<20)
	_ = w.SetWriteDeadline(time.Now().Add(50 * time.Millisecond))
	n, err := w.Write(junk)
	if !errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatalf("expected pipe to fill up, wrote %d err=%v", n, err)
	}
	return n
}

// runMouse feeds queued mouse reports through the real writer loop and
// returns once everything has been flushed.
func runMouse(h *Hid, queue chan []byte) {
	inbox := make(chan hidMsg, len(queue)+1)
	for r := range queue {
		inbox <- hidMsg{report: r}
	}
	close(inbox)
	h.runWriter(inbox, newMouseOutbox())
}

type fakeClock struct{ t time.Time }

func (c *fakeClock) now() time.Time          { return c.t }
func (c *fakeClock) advance(d time.Duration) { c.t = c.t.Add(d) }

func kbReport(mod, key byte) []byte { return []byte{mod, 0, key, 0, 0, 0, 0, 0} }

// ---- keyboard ----

func TestKeyboardLosslessOrder(t *testing.T) {
	r, w := newPipe(t)
	h := &Hid{g0: w}

	const n = 300
	inbox := make(chan hidMsg, n)
	want := make([]byte, 0, n*8)
	for i := 0; i < n; i++ {
		var rep []byte
		if i%2 == 0 {
			rep = kbReport(0, byte(4+(i/2)%26)) // key down
		} else {
			rep = kbReport(0, 0) // key up
		}
		inbox <- hidMsg{report: rep}
		want = append(want, rep...)
	}
	close(inbox)

	done := make(chan struct{})
	go func() { h.runWriter(inbox, newKeyboardOutbox()); close(done) }()

	got := readExactly(t, r, len(want))
	<-done
	if string(got) != string(want) {
		t.Fatalf("keyboard reports reordered or lost")
	}
}

func TestKeyboardRetryAfterStall(t *testing.T) {
	r, w := newPipe(t)
	h := &Hid{g0: w}
	junk := stallPipe(t, w)

	inbox := make(chan hidMsg, 8)
	done := make(chan struct{})
	go func() { h.runWriter(inbox, newKeyboardOutbox()); close(done) }()

	seq := [][]byte{kbReport(0, 4), kbReport(0, 0), kbReport(2, 5), kbReport(0, 0)}
	var want []byte
	for _, rep := range seq {
		inbox <- hidMsg{report: rep}
		want = append(want, rep...)
	}

	time.Sleep(200 * time.Millisecond) // several failed attempts
	readExactly(t, r, junk)            // host resumes polling
	got := readExactly(t, r, len(want))
	close(inbox)
	<-done

	if string(got) != string(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestKeyboardStaleCollapseKeepsLatest(t *testing.T) {
	clk := &fakeClock{t: time.Unix(0, 0)}
	o := &keyboardOutbox{now: clk.now}

	d1, d2, d3 := make(chan error, 1), make(chan error, 1), make(chan error, 1)
	o.add(hidMsg{report: kbReport(0, 4), done: d1})
	o.add(hidMsg{report: kbReport(0, 0), done: d2})
	o.add(hidMsg{report: kbReport(0, 5), done: d3})

	clk.advance(keyboardStaleAfter)
	o.dropStale()

	if len(o.entries) != 1 || o.entries[0].report[2] != 5 {
		t.Fatalf("expected only latest state (key 5), got %+v", o.entries)
	}
	for i, d := range []chan error{d1, d2} {
		if err := <-d; !errors.Is(err, ErrReportStale) {
			t.Errorf("done %d: got %v, want ErrReportStale", i+1, err)
		}
	}
	if !o.entries[0].since.Equal(clk.t) {
		t.Errorf("kept entry should get a fresh stale window")
	}
}

func TestKeyboardStaleDropsOnlyOldEntries(t *testing.T) {
	clk := &fakeClock{t: time.Unix(0, 0)}
	o := &keyboardOutbox{now: clk.now}

	o.add(hidMsg{report: kbReport(0, 4)})
	clk.advance(keyboardStaleAfter - time.Millisecond)
	o.add(hidMsg{report: kbReport(0, 0)})
	clk.advance(time.Millisecond)
	o.dropStale()

	if len(o.entries) != 1 || o.entries[0].report[2] != 0 {
		t.Fatalf("expected only the fresh key-up, got %+v", o.entries)
	}
}

func TestKeyboardReleaseOnlyWhenHeld(t *testing.T) {
	o := newKeyboardOutbox()

	o.add(hidMsg{release: true})
	if len(o.entries) != 0 {
		t.Fatalf("release with nothing held queued %d reports", len(o.entries))
	}

	o.add(hidMsg{report: kbReport(2, 4)})
	o.add(hidMsg{release: true})
	if len(o.entries) != 2 || o.entries[1].report != [8]byte{} {
		t.Fatalf("expected key-down + all-zero release, got %+v", o.entries)
	}

	o.add(hidMsg{release: true})
	if len(o.entries) != 2 {
		t.Fatalf("second release should be a no-op, got %d entries", len(o.entries))
	}
}

func TestKeyboardDropsOnlyConsecutiveDuplicates(t *testing.T) {
	o := newKeyboardOutbox()
	for _, rep := range [][]byte{kbReport(0, 4), kbReport(0, 4), kbReport(0, 0), kbReport(0, 4)} {
		o.add(hidMsg{report: rep})
	}
	if len(o.entries) != 3 {
		t.Fatalf("expected 3 entries (down, up, down), got %d", len(o.entries))
	}
}

func TestKeyboardInvalidReportRejected(t *testing.T) {
	o := newKeyboardOutbox()
	done := make(chan error, 1)
	o.add(hidMsg{report: []byte{1, 2, 3}, done: done})
	if err := <-done; !errors.Is(err, ErrInvalidReport) {
		t.Fatalf("got %v, want ErrInvalidReport", err)
	}
	if len(o.entries) != 0 {
		t.Fatalf("invalid report was queued")
	}
}

func TestKeyboardOutboxCap(t *testing.T) {
	o := newKeyboardOutbox()
	for i := 0; i <= keyboardOutboxMax; i++ {
		o.add(hidMsg{report: kbReport(0, byte(i%2*4))}) // alternate down/up
	}
	if len(o.entries) > keyboardOutboxMax {
		t.Fatalf("outbox exceeded cap: %d", len(o.entries))
	}
	if o.entries[len(o.entries)-1].report != o.last {
		t.Fatalf("latest state not kept")
	}
}

func TestSubmitKeyboardWaitGadgetAbsent(t *testing.T) {
	if _, err := os.Stat(HID0); err == nil {
		t.Skip("real HID gadget present")
	}
	h := &Hid{}
	err := h.SubmitKeyboardWait(kbReport(0, 4), time.Second)
	if !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("got %v, want ErrNotExist", err)
	}
}

// ---- mouse ----

func TestMouseRelativeMotionCarriedOverStall(t *testing.T) {
	r, w := newPipe(t)
	h := &Hid{g1: w}
	junk := stallPipe(t, w)

	inbox := make(chan hidMsg, 64)
	done := make(chan struct{})
	go func() { h.runWriter(inbox, newMouseOutbox()); close(done) }()

	for i := 0; i < 50; i++ {
		inbox <- hidMsg{report: []byte{0, 10, 0xfb, 0, 0}} // dx=10, dy=-5
	}
	time.Sleep(200 * time.Millisecond)
	readExactly(t, r, junk)

	sumX, sumY := 0, 0
	for sumX < 500 {
		rep := readExactly(t, r, 5)
		sumX += int(int8(rep[1]))
		sumY += int(int8(rep[2]))
	}
	close(inbox)
	<-done

	if sumX != 500 || sumY != -250 {
		t.Fatalf("motion lost: got (%d,%d), want (500,-250)", sumX, sumY)
	}
}

func TestMouseButtonUpRetriedAfterStall(t *testing.T) {
	r, w := newPipe(t)
	h := &Hid{g1: w}
	junk := stallPipe(t, w)

	inbox := make(chan hidMsg, 4)
	done := make(chan struct{})
	go func() { h.runWriter(inbox, newMouseOutbox()); close(done) }()

	inbox <- hidMsg{report: []byte{1, 0, 0, 0, 0}}
	inbox <- hidMsg{report: []byte{0, 0, 0, 0, 0}}
	time.Sleep(200 * time.Millisecond)
	readExactly(t, r, junk)
	got := readExactly(t, r, 10)
	close(inbox)
	<-done

	if got[0] != 1 || got[5] != 0 {
		t.Fatalf("expected down then up, got %v", got)
	}
}

func TestMouseStaleCollapseKeepsButtonState(t *testing.T) {
	clk := &fakeClock{t: time.Unix(0, 0)}
	o := &mouseOutbox{now: clk.now}

	o.add(hidMsg{report: []byte{1, 5, 5, 0, 0}})
	o.add(hidMsg{report: []byte{0, 5, 5, 1, 0}})
	o.add(hidMsg{report: []byte{2, 5, 5, 0, 0}})
	clk.advance(mouseStaleAfter)
	o.dropStale()

	if len(o.entries) != 1 {
		t.Fatalf("expected a single state-sync entry, got %d", len(o.entries))
	}
	e := o.entries[0]
	if e.buttons != 2 || e.dx != 0 || e.dy != 0 || e.wheel != 0 {
		t.Fatalf("state sync should carry latest buttons and no motion, got %+v", e)
	}
}

func TestMouseOutboxCap(t *testing.T) {
	o := newMouseOutbox()
	for i := 0; i <= mouseOutboxMax; i++ {
		o.add(hidMsg{report: []byte{byte(i % 2), 1, 0, 0, 0}})
	}
	if len(o.entries) > mouseOutboxMax {
		t.Fatalf("outbox exceeded cap: %d", len(o.entries))
	}
	if last := o.entries[len(o.entries)-1]; last.buttons != byte(mouseOutboxMax%2) {
		t.Fatalf("latest button state not kept: %+v", last)
	}
}

func TestMouseReleaseOnlyWhenHeld(t *testing.T) {
	o := newMouseOutbox()
	o.add(hidMsg{release: true})
	if len(o.entries) != 0 {
		t.Fatalf("release with nothing held queued %d entries", len(o.entries))
	}

	o.add(hidMsg{report: []byte{1, 3, 0, 0, 0}})
	o.add(hidMsg{release: true})
	if len(o.entries) != 2 || o.entries[1].buttons != 0 || o.entries[1].absolute {
		t.Fatalf("expected relative button-up, got %+v", o.entries)
	}
}

func TestMouseAbsoluteReleaseKeepsPosition(t *testing.T) {
	o := newMouseOutbox()
	o.add(hidMsg{report: []byte{1, 0x34, 0x12, 0x78, 0x56, 1, 0}})
	o.add(hidMsg{release: true})

	if len(o.entries) != 2 {
		t.Fatalf("expected press + release, got %d entries", len(o.entries))
	}
	rel := o.entries[1]
	want := [7]byte{0, 0x34, 0x12, 0x78, 0x56, 0, 0}
	if !rel.absolute || rel.abs != want {
		t.Fatalf("release should keep position without wheel, got %v", rel.abs)
	}
}

func TestMouseInvalidReportIgnored(t *testing.T) {
	o := newMouseOutbox()
	o.add(hidMsg{report: []byte{1, 2, 3}})
	if len(o.entries) != 0 {
		t.Fatalf("invalid report was queued")
	}
}
