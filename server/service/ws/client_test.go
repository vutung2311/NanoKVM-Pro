package ws

import (
	"testing"
	"time"
)

func TestWriteQueue_Immediate(t *testing.T) {
	ch := make(chan []byte, 1)
	data := []byte{0x01, 0x02}

	writeQueue(ch, data)

	select {
	case received := <-ch:
		if len(received) != 2 || received[0] != 0x01 || received[1] != 0x02 {
			t.Fatalf("unexpected data received: %v", received)
		}
	default:
		t.Fatal("expected item in queue, but queue was empty")
	}
}

func TestWriteQueue_DropWhenFull(t *testing.T) {
	ch := make(chan []byte, 1)
	ch <- []byte{0x00} // fill queue

	done := make(chan struct{})
	go func() {
		writeQueue(ch, []byte{0x01})
		close(done)
	}()

	select {
	case <-done:
		// Succeeded immediately without blocking
	case <-time.After(100 * time.Millisecond):
		t.Fatal("writeQueue blocked on full channel")
	}

	select {
	case item := <-ch:
		if len(item) != 1 || item[0] != 0x01 {
			t.Fatalf("expected newer item 0x01, got %v", item)
		}
	default:
		t.Fatal("expected item in channel")
	}
}

func TestWriteKeyboardQueue_Immediate(t *testing.T) {
	ch := make(chan []byte, 1)
	data := []byte{0x04, 0x00}

	writeKeyboardQueue(ch, data)

	select {
	case received := <-ch:
		if len(received) != 2 || received[0] != 0x04 {
			t.Fatalf("unexpected data received: %v", received)
		}
	default:
		t.Fatal("expected item in keyboard queue, but queue was empty")
	}
}

func TestWriteKeyboardQueue_DropOldestWhenFull(t *testing.T) {
	ch := make(chan []byte, 1)
	ch <- []byte{0x00} // fill queue

	done := make(chan struct{})
	go func() {
		writeKeyboardQueue(ch, []byte{0x02})
		close(done)
	}()

	select {
	case <-done:
		// Succeeded immediately without blocking
	case <-time.After(100 * time.Millisecond):
		t.Fatal("writeKeyboardQueue blocked on full channel")
	}

	select {
	case item := <-ch:
		if len(item) != 1 || item[0] != 0x02 {
			t.Fatalf("expected newer item 0x02, got %v", item)
		}
	default:
		t.Fatal("expected item in channel")
	}
}

func BenchmarkWriteQueue_Immediate(b *testing.B) {
	ch := make(chan []byte, b.N)
	data := []byte{0x00, 0x01, 0x02}

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		writeQueue(ch, data)
	}
}

func BenchmarkWriteQueue_FullQueue(b *testing.B) {
	ch := make(chan []byte, 1)
	ch <- []byte{0x00}
	data := []byte{0x00, 0x01, 0x02}

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		writeQueue(ch, data)
	}
}

func BenchmarkWriteKeyboardQueue_Immediate(b *testing.B) {
	ch := make(chan []byte, b.N)
	data := []byte{0x04, 0x00}

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		writeKeyboardQueue(ch, data)
	}
}

func BenchmarkWriteKeyboardQueue_FullQueue(b *testing.B) {
	ch := make(chan []byte, 1)
	ch <- []byte{0x00}
	data := []byte{0x04, 0x00}

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		writeKeyboardQueue(ch, data)
	}
}
