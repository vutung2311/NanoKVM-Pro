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

func TestWriteRelativeChunksZero(t *testing.T) {
	h := &Hid{}
	// Should not panic on zero deltas even if g1 is nil
	h.writeRelativeChunks(0, 0, 0, 0)
	h.writeRelativeChunks(1, 0, 0, 0)
}

func TestWriteRelativeChunksLarge(t *testing.T) {
	h := &Hid{}
	// Test that chunking handles large deltas (>127) safely without infinite loop
	h.writeRelativeChunks(0, 300, -250, 50)
}

func TestMouseClickAndReleaseNotDropped(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("failed to create pipe: %v", err)
	}
	defer r.Close()

	h := &Hid{g1: w}
	queue := make(chan []byte, 10)

	// Pre-queue a click down and immediate release
	queue <- []byte{1, 0, 0, 0}
	queue <- []byte{0, 0, 0, 0}
	close(queue)

	h.Mouse(queue)
	_ = w.Close()

	buf := make([]byte, 16)
	n, _ := r.Read(buf)
	if n != 8 {
		t.Fatalf("expected 8 bytes (2 reports), got %d bytes: %v", n, buf[:n])
	}

	// First report: Button 1 pressed
	if buf[0] != 1 || buf[1] != 0 || buf[2] != 0 || buf[3] != 0 {
		t.Errorf("report 1 mismatch: got %v, want [1 0 0 0]", buf[:4])
	}

	// Second report: Button released
	if buf[4] != 0 || buf[5] != 0 || buf[6] != 0 || buf[7] != 0 {
		t.Errorf("report 2 mismatch: got %v, want [0 0 0 0]", buf[4:8])
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

	// Pre-queue 3 small movements with same button state (0)
	queue <- []byte{0, 10, 5, 1}
	queue <- []byte{0, 20, 15, 2}
	queue <- []byte{0, 5, 0xf6, 0}
	close(queue)

	h.Mouse(queue)
	_ = w.Close()

	buf := make([]byte, 16)
	n, _ := r.Read(buf)
	if n != 4 {
		t.Fatalf("expected 4 bytes (1 coalesced report), got %d bytes: %v", n, buf[:n])
	}

	// Expected sum: dx = 10+20+5 = 35, dy = 5+15-10 = 10, wheel = 1+2+0 = 3
	if buf[0] != 0 || buf[1] != 35 || buf[2] != 10 || buf[3] != 3 {
		t.Errorf("coalesced report mismatch: got %v, want [0 35 10 3]", buf[:4])
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

	h.Mouse(queue)
	_ = w1.Close()
	_ = w2.Close()

	buf1 := make([]byte, 16)
	n1, _ := r1.Read(buf1)
	if n1 != 4 {
		t.Fatalf("expected 4 bytes on g1, got %d: %v", n1, buf1[:n1])
	}

	buf2 := make([]byte, 16)
	n2, _ := r2.Read(buf2)
	if n2 != 6 {
		t.Fatalf("expected 6 bytes on g2, got %d: %v", n2, buf2[:n2])
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
	queue <- []byte{0, 10, 0, 10, 0, 0}
	queue <- []byte{0, 20, 0, 20, 0, 0}
	queue <- []byte{0, 20, 0, 20, 0, 1} // wheel scroll
	queue <- []byte{0, 30, 0, 30, 0, 0} // subsequent move
	close(queue)

	h.Mouse(queue)
	_ = w.Close()

	buf := make([]byte, 32)
	n, _ := r.Read(buf)
	// Expected 3 reports:
	// 1. Move coalesced to [0, 20, 0, 20, 0, 0] (6 bytes)
	// 2. Wheel event [0, 20, 0, 20, 0, 1] (6 bytes)
	// 3. Final move [0, 30, 0, 30, 0, 0] (6 bytes)
	if n != 18 {
		t.Fatalf("expected 18 bytes (3 reports), got %d bytes: %v", n, buf[:n])
	}
	if buf[5] != 0 || buf[11] != 1 || buf[17] != 0 {
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
	queue <- []byte{0, 10, 0, 10, 0, 0}
	queue <- []byte{1, 10, 0, 10, 0, 0}
	queue <- []byte{0, 10, 0, 10, 0, 0}
	close(queue)

	h.Mouse(queue)
	_ = w.Close()

	buf := make([]byte, 32)
	n, _ := r.Read(buf)
	if n != 18 {
		t.Fatalf("expected 18 bytes (3 reports), got %d bytes: %v", n, buf[:n])
	}
	if buf[0] != 0 || buf[6] != 1 || buf[12] != 0 {
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
	queue <- []byte{0, 10, 0, 10, 0, 1}
	queue <- []byte{0, 10, 0, 10, 0, 1}
	queue <- []byte{0, 10, 0, 10, 0, 0xff} // scroll down (-1)
	close(queue)

	h.Mouse(queue)
	_ = w.Close()

	buf := make([]byte, 32)
	n, _ := r.Read(buf)
	if n != 18 {
		t.Fatalf("expected 18 bytes (3 reports), got %d bytes: %v", n, buf[:n])
	}
	if buf[5] != 1 || buf[11] != 1 || buf[17] != 0xff {
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
		queue <- []byte{0, byte(i * 10), 0, byte(i * 10), 0, 0}
	}
	close(queue)

	h.Mouse(queue)
	_ = w.Close()

	buf := make([]byte, 32)
	n, _ := r.Read(buf)
	// All 5 moves should coalesce into a single report with the latest coordinate (50, 50)
	if n != 6 {
		t.Fatalf("expected 6 bytes (1 coalesced report), got %d bytes: %v", n, buf[:n])
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
	queue <- []byte{0, 10, 0, 10, 0, 0}
	queue <- []byte{0, 1, 2} // invalid
	queue <- []byte{0, 20, 0, 20, 0, 0}
	close(queue)

	h.Mouse(queue)
	_ = w.Close()

	buf := make([]byte, 32)
	n, _ := r.Read(buf)
	// Expected 2 valid 6-byte reports
	if n != 12 {
		t.Fatalf("expected 12 bytes (2 reports), got %d bytes: %v", n, buf[:n])
	}
	if buf[1] != 10 || buf[7] != 20 {
		t.Errorf("unexpected reports: %v", buf[:n])
	}
}


