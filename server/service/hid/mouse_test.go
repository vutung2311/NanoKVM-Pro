package hid

import (
	"os"
	"testing"
)

func TestClampInt8(t *testing.T) {
	tests := []struct {
		input    int
		expected int8
	}{
		{0, 0},
		{50, 50},
		{127, 127},
		{128, 127},
		{300, 127},
		{-50, -50},
		{-127, -127},
		{-128, -127},
		{-300, -127},
	}

	for _, tc := range tests {
		got := clampInt8(tc.input)
		if got != tc.expected {
			t.Errorf("clampInt8(%d) = %d; want %d", tc.input, got, tc.expected)
		}
	}
}

func TestWriteRelativeZeroMotionSendsButtons(t *testing.T) {
	r, w := newPipe(t)
	h := &Hid{g1: w}

	e := mouseEntry{buttons: 1}
	if err := h.writeRelative(&e); err != nil {
		t.Fatalf("writeRelative: %v", err)
	}
	got := readExactly(t, r, 5)
	if string(got) != string([]byte{1, 0, 0, 0, 0}) {
		t.Fatalf("got %v, want [1 0 0 0 0]", got)
	}
}

func TestWriteRelativeSplitsLargeDeltas(t *testing.T) {
	r, w := newPipe(t)
	h := &Hid{g1: w}

	e := mouseEntry{buttons: 2, dx: 300, dy: -250, wheel: 50, hwheel: -40}
	if err := h.writeRelative(&e); err != nil {
		t.Fatalf("writeRelative: %v", err)
	}
	if e.dx != 0 || e.dy != 0 || e.wheel != 0 || e.hwheel != 0 {
		t.Fatalf("entry not fully consumed: %+v", e)
	}

	m127 := byte(0x81) // int8(-127)
	want := []byte{
		2, 127, m127, 50, byte(0xd8), // -40
		2, 127, byte(0x85), 0, 0, // -123
		2, 46, 0, 0, 0,
	}
	got := readExactly(t, r, len(want))
	if string(got) != string(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestMouseClickAndReleaseNotDropped(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("failed to create pipe: %v", err)
	}
	defer r.Close()

	h := &Hid{g1: w}
	queue := make(chan []byte, 10)

	// Pre-queue a click down and immediate release (4 or 5 bytes)
	queue <- []byte{1, 0, 0, 0, 0}
	queue <- []byte{0, 0, 0, 0, 0}
	close(queue)

	runMouse(h, queue)
	_ = w.Close()

	buf := make([]byte, 16)
	n, _ := r.Read(buf)
	if n != 10 {
		t.Fatalf("expected 10 bytes (2 reports of 5 bytes), got %d bytes: %v", n, buf[:n])
	}

	// First report: Button 1 pressed
	if buf[0] != 1 || buf[1] != 0 || buf[2] != 0 || buf[3] != 0 || buf[4] != 0 {
		t.Errorf("report 1 mismatch: got %v, want [1 0 0 0 0]", buf[:5])
	}

	// Second report: Button released
	if buf[5] != 0 || buf[6] != 0 || buf[7] != 0 || buf[8] != 0 || buf[9] != 0 {
		t.Errorf("report 2 mismatch: got %v, want [0 0 0 0 0]", buf[5:10])
	}
}

func TestMouseRelativeCoalescing(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("failed to create pipe: %v", err)
	}
	defer r.Close()

	h := &Hid{g1: w}
	queue := make(chan []byte, 10)

	// Pre-queue 3 small movements with same button state (0) including horizontal wheel
	queue <- []byte{0, 10, 5, 1, 2}
	queue <- []byte{0, 20, 15, 2, 0xff}
	queue <- []byte{0, 5, 0xf6, 0, 0}
	close(queue)

	runMouse(h, queue)
	_ = w.Close()

	buf := make([]byte, 16)
	n, _ := r.Read(buf)
	if n != 5 {
		t.Fatalf("expected 5 bytes (1 coalesced report), got %d bytes: %v", n, buf[:n])
	}

	// Expected sum: dx = 10+20+5 = 35, dy = 5+15-10 = 10, wheel = 1+2+0 = 3, hwheel = 2-1+0 = 1
	if buf[0] != 0 || buf[1] != 35 || buf[2] != 10 || buf[3] != 3 || buf[4] != 1 {
		t.Errorf("coalesced report mismatch: got %v, want [0 35 10 3 1]", buf[:5])
	}
}

func TestMouseMixedRelativeAndAbsolute(t *testing.T) {
	r1, w1, err := os.Pipe()
	if err != nil {
		t.Fatalf("failed to create pipe 1: %v", err)
	}
	defer r1.Close()

	r2, w2, err := os.Pipe()
	if err != nil {
		t.Fatalf("failed to create pipe 2: %v", err)
	}
	defer r2.Close()

	h := &Hid{g1: w1, g2: w2}
	queue := make(chan []byte, 10)

	// Relative movement followed by absolute position report
	queue <- []byte{0, 10, 20, 0}
	queue <- []byte{0, 0x10, 0x20, 0x30, 0x40, 0}
	close(queue)

	runMouse(h, queue)
	_ = w1.Close()
	_ = w2.Close()

	buf1 := make([]byte, 16)
	n1, _ := r1.Read(buf1)
	if n1 != 5 {
		t.Fatalf("expected 5 bytes on g1, got %d: %v", n1, buf1[:n1])
	}

	buf2 := make([]byte, 16)
	n2, _ := r2.Read(buf2)
	if n2 != 7 {
		t.Fatalf("expected 7 bytes on g2, got %d: %v", n2, buf2[:n2])
	}
}

func TestMouseAbsoluteCoalescingAndWheel(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("failed to create pipe: %v", err)
	}
	defer r.Close()

	h := &Hid{g2: w}
	queue := make(chan []byte, 10)

	// Pre-queue 2 move events, 1 wheel event, and 1 final move event
	queue <- []byte{0, 10, 0, 10, 0, 0, 0}
	queue <- []byte{0, 20, 0, 20, 0, 0, 0}
	queue <- []byte{0, 20, 0, 20, 0, 1, 2} // vertical wheel = 1, horizontal wheel = 2
	queue <- []byte{0, 30, 0, 30, 0, 0, 0} // subsequent move
	close(queue)

	runMouse(h, queue)
	_ = w.Close()

	buf := make([]byte, 32)
	n, _ := r.Read(buf)
	// Expected 3 reports (each 7 bytes = 21 bytes):
	// 1. Move coalesced to [0, 20, 0, 20, 0, 0, 0]
	// 2. Wheel event [0, 20, 0, 20, 0, 1, 2]
	// 3. Final move [0, 30, 0, 30, 0, 0, 0]
	if n != 21 {
		t.Fatalf("expected 21 bytes (3 reports), got %d bytes: %v", n, buf[:n])
	}
	if buf[5] != 0 || buf[6] != 0 || buf[12] != 1 || buf[13] != 2 || buf[19] != 0 || buf[20] != 0 {
		t.Errorf("wheel preservation mismatch: reports=%v", buf[:n])
	}
}

func TestMouseAbsoluteClickAndReleaseNotDropped(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("failed to create pipe: %v", err)
	}
	defer r.Close()

	h := &Hid{g2: w}
	queue := make(chan []byte, 10)

	// Pre-queue mouse move, button 1 down, and button 1 release
	queue <- []byte{0, 10, 0, 10, 0, 0, 0}
	queue <- []byte{1, 10, 0, 10, 0, 0, 0}
	queue <- []byte{0, 10, 0, 10, 0, 0, 0}
	close(queue)

	runMouse(h, queue)
	_ = w.Close()

	buf := make([]byte, 32)
	n, _ := r.Read(buf)
	if n != 21 {
		t.Fatalf("expected 21 bytes (3 reports), got %d bytes: %v", n, buf[:n])
	}
	if buf[0] != 0 || buf[7] != 1 || buf[14] != 0 {
		t.Errorf("button transition mismatch: reports=%v", buf[:n])
	}
}

func TestMouseConsecutiveWheelReportsNotDropped(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("failed to create pipe: %v", err)
	}
	defer r.Close()

	h := &Hid{g2: w}
	queue := make(chan []byte, 10)

	// Queue 3 consecutive scroll ticks without intervening moves
	queue <- []byte{0, 10, 0, 10, 0, 1, 0}
	queue <- []byte{0, 10, 0, 10, 0, 0, 1}    // horizontal scroll right (+1)
	queue <- []byte{0, 10, 0, 10, 0, 0xff, 0} // scroll down (-1)
	close(queue)

	runMouse(h, queue)
	_ = w.Close()

	buf := make([]byte, 32)
	n, _ := r.Read(buf)
	if n != 21 {
		t.Fatalf("expected 21 bytes (3 reports), got %d bytes: %v", n, buf[:n])
	}
	if buf[5] != 1 || buf[13] != 1 || buf[19] != 0xff {
		t.Errorf("consecutive wheel mismatch: reports=%v", buf[:n])
	}
}

func TestMouseAbsoluteMovePreservesLatestCoordinate(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("failed to create pipe: %v", err)
	}
	defer r.Close()

	h := &Hid{g2: w}
	queue := make(chan []byte, 20)

	// Queue a burst of 5 moves with the same button state
	for i := 1; i <= 5; i++ {
		queue <- []byte{0, byte(i * 10), 0, byte(i * 10), 0, 0, 0}
	}
	close(queue)

	runMouse(h, queue)
	_ = w.Close()

	buf := make([]byte, 32)
	n, _ := r.Read(buf)
	// All 5 moves should coalesce into a single report with the latest coordinate (50, 50)
	if n != 7 {
		t.Fatalf("expected 7 bytes (1 coalesced report), got %d bytes: %v", n, buf[:n])
	}
	if buf[1] != 50 || buf[3] != 50 {
		t.Errorf("expected final coordinates (50, 50), got x=%d y=%d", buf[1], buf[3])
	}
}

func TestMouseInvalidEventIgnoredGracefully(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("failed to create pipe: %v", err)
	}
	defer r.Close()

	h := &Hid{g2: w}
	queue := make(chan []byte, 10)

	// Queue valid move, malformed packet (len 3), and another valid move
	queue <- []byte{0, 10, 0, 10, 0, 0, 0}
	queue <- []byte{0, 1, 2} // invalid
	queue <- []byte{0, 20, 0, 20, 0, 0, 0}
	close(queue)

	runMouse(h, queue)
	_ = w.Close()

	buf := make([]byte, 32)
	n, _ := r.Read(buf)
	// The invalid packet is skipped; both valid moves coalesce (latest wins)
	if n != 7 {
		t.Fatalf("expected 7 bytes (1 coalesced report), got %d bytes: %v", n, buf[:n])
	}
	if buf[1] != 20 || buf[3] != 20 {
		t.Errorf("unexpected reports: %v", buf[:n])
	}
}

func TestWriteHid1PadsLegacy4ByteReport(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("failed to create pipe: %v", err)
	}
	defer r.Close()

	h := &Hid{g1: w}
	h.WriteHid1([]byte{1, 10, 20, 30})
	_ = w.Close()

	buf := make([]byte, 16)
	n, _ := r.Read(buf)
	if n != 5 {
		t.Fatalf("expected 5 bytes written, got %d: %v", n, buf[:n])
	}
	if buf[0] != 1 || buf[1] != 10 || buf[2] != 20 || buf[3] != 30 || buf[4] != 0 {
		t.Errorf("expected padded 5-byte report [1 10 20 30 0], got %v", buf[:n])
	}
}

func TestWriteHid2PadsLegacy6ByteReport(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("failed to create pipe: %v", err)
	}
	defer r.Close()

	h := &Hid{g2: w}
	h.WriteHid2([]byte{2, 0x11, 0x22, 0x33, 0x44, 0x55})
	_ = w.Close()

	buf := make([]byte, 16)
	n, _ := r.Read(buf)
	if n != 7 {
		t.Fatalf("expected 7 bytes written, got %d: %v", n, buf[:n])
	}
	if buf[0] != 2 || buf[1] != 0x11 || buf[2] != 0x22 || buf[3] != 0x33 || buf[4] != 0x44 || buf[5] != 0x55 || buf[6] != 0 {
		t.Errorf("expected padded 7-byte report [2 17 34 51 68 85 0], got %v", buf[:n])
	}
}

func TestWriteHid1LegacyLatched(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("failed to create pipe: %v", err)
	}
	defer r.Close()

	h := &Hid{g1: w, legacyHid1: true}
	// Writing a 5-byte report when legacyHid1 is true should truncate to 4 bytes
	h.WriteHid1([]byte{1, 10, 20, 30, 40})
	_ = w.Close()

	buf := make([]byte, 16)
	n, _ := r.Read(buf)
	if n != 4 {
		t.Fatalf("expected 4 bytes written for legacy gadget, got %d: %v", n, buf[:n])
	}
	if buf[0] != 1 || buf[1] != 10 || buf[2] != 20 || buf[3] != 30 {
		t.Errorf("expected [1 10 20 30], got %v", buf[:n])
	}
}

func TestWriteHid2LegacyLatched(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("failed to create pipe: %v", err)
	}
	defer r.Close()

	h := &Hid{g2: w, legacyHid2: true}
	// Writing a 7-byte report when legacyHid2 is true should truncate to 6 bytes
	h.WriteHid2([]byte{2, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66})
	_ = w.Close()

	buf := make([]byte, 16)
	n, _ := r.Read(buf)
	if n != 6 {
		t.Fatalf("expected 6 bytes written for legacy gadget, got %d: %v", n, buf[:n])
	}
	if buf[0] != 2 || buf[1] != 0x11 || buf[2] != 0x22 || buf[3] != 0x33 || buf[4] != 0x44 || buf[5] != 0x55 {
		t.Errorf("expected [2 17 34 51 68 85], got %v", buf[:n])
	}
}


