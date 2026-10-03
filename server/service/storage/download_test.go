package storage

import (
	"io"
	"sync"
	"testing"
	"time"
)

type syncWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func (s *syncWriter) Write(p []byte) (n int, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.w.Write(p)
}

func TestLoggingWriter_Lifecycle(t *testing.T) {
	lw := &loggingWriter{
		writer:    io.Discard,
		totalSize: 1000,
	}

	lw.startTicker()

	n, err := lw.Write([]byte("hello world"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if n != 11 {
		t.Fatalf("expected 11 bytes written, got %d", n)
	}

	// Multiple stop calls must be idempotent and not panic
	lw.stopTicker()
	lw.stopTicker()
}

func TestLoggingWriter_ConcurrentWritesAndTicker(t *testing.T) {
	sw := &syncWriter{w: io.Discard}
	lw := &loggingWriter{
		writer:    sw,
		totalSize: 100000,
	}

	lw.startTicker()
	defer lw.stopTicker()

	var wg sync.WaitGroup
	chunk := make([]byte, 100)

	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 50; j++ {
				_, _ = lw.Write(chunk)
				time.Sleep(500 * time.Microsecond)
			}
		}()
	}

	wg.Wait()
}
