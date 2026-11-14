package stream

import (
	"testing"
)

func TestFrameBufferPool_Capacity(t *testing.T) {
	bufPtr := FrameBufferPool.Get().(*[]byte)
	defer PutFrameBuffer(bufPtr)

	if bufPtr == nil {
		t.Fatal("expected non-nil buffer from FrameBufferPool")
	}
	if len(*bufPtr) != DefaultFrameBufferSize {
		t.Fatalf("expected initial buffer len %d, got %d", DefaultFrameBufferSize, len(*bufPtr))
	}
	if cap(*bufPtr) < DefaultFrameBufferSize {
		t.Fatalf("expected initial buffer cap >= %d, got %d", DefaultFrameBufferSize, cap(*bufPtr))
	}
}

func TestAudioBufferPool_Capacity(t *testing.T) {
	bufPtr := AudioBufferPool.Get().(*[]byte)
	defer PutAudioBuffer(bufPtr)

	if bufPtr == nil {
		t.Fatal("expected non-nil buffer from AudioBufferPool")
	}
	if len(*bufPtr) != DefaultAudioBufferSize {
		t.Fatalf("expected initial buffer len %d, got %d", DefaultAudioBufferSize, len(*bufPtr))
	}
	if cap(*bufPtr) < DefaultAudioBufferSize {
		t.Fatalf("expected initial buffer cap >= %d, got %d", DefaultAudioBufferSize, cap(*bufPtr))
	}
}

func TestPutFrameBuffer_NilSafe(t *testing.T) {
	// Should not panic
	PutFrameBuffer(nil)
}

func TestPutAudioBuffer_NilSafe(t *testing.T) {
	// Should not panic
	PutAudioBuffer(nil)
}

func TestPutFrameBuffer_NormalizeResliced(t *testing.T) {
	buf := make([]byte, DefaultFrameBufferSize)
	resliced := buf[:1024]
	bufPtr := &resliced

	PutFrameBuffer(bufPtr)

	if len(*bufPtr) != DefaultFrameBufferSize {
		t.Fatalf("expected resliced buffer len normalized to %d, got %d", DefaultFrameBufferSize, len(*bufPtr))
	}
	if cap(*bufPtr) < DefaultFrameBufferSize {
		t.Fatalf("expected buffer cap >= %d, got %d", DefaultFrameBufferSize, cap(*bufPtr))
	}
}

func TestPutAudioBuffer_NormalizeResliced(t *testing.T) {
	buf := make([]byte, DefaultAudioBufferSize)
	resliced := buf[:128]
	bufPtr := &resliced

	PutAudioBuffer(bufPtr)

	if len(*bufPtr) != DefaultAudioBufferSize {
		t.Fatalf("expected resliced audio buffer len normalized to %d, got %d", DefaultAudioBufferSize, len(*bufPtr))
	}
	if cap(*bufPtr) < DefaultAudioBufferSize {
		t.Fatalf("expected audio buffer cap >= %d, got %d", DefaultAudioBufferSize, cap(*bufPtr))
	}
}

// Buffers outside the pooled size range (oversized, undersized, nil) are
// dropped, not swapped for a freshly allocated default buffer on every put.
func TestPutBuffersDropOutOfRangeWithoutAllocating(t *testing.T) {
	cases := []struct {
		name string
		put  func(*[]byte)
		size int
	}{
		{"frame oversized", PutFrameBuffer, MaxPooledFrameBufferSize + 1024},
		{"frame undersized", PutFrameBuffer, 128},
		{"frame nil", PutFrameBuffer, -1},
		{"audio oversized", PutAudioBuffer, MaxPooledAudioBufferSize + 1024},
		{"audio undersized", PutAudioBuffer, 64},
		{"audio nil", PutAudioBuffer, -1},
	}
	for _, tc := range cases {
		var buf []byte
		if tc.size >= 0 {
			buf = make([]byte, tc.size)
		}
		ptr := &buf
		allocs := testing.AllocsPerRun(10, func() { tc.put(ptr) })
		if allocs != 0 {
			t.Errorf("%s: put allocated %.0f times, want 0", tc.name, allocs)
		}
	}
}

func BenchmarkFrameBufferPool_GetPut(b *testing.B) {
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		bufPtr := FrameBufferPool.Get().(*[]byte)
		PutFrameBuffer(bufPtr)
	}
}

func BenchmarkFrameBuffer_Unpooled(b *testing.B) {
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		buf := make([]byte, DefaultFrameBufferSize)
		_ = buf
	}
}

func BenchmarkAudioBufferPool_GetPut(b *testing.B) {
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		bufPtr := AudioBufferPool.Get().(*[]byte)
		PutAudioBuffer(bufPtr)
	}
}

func BenchmarkAudioBuffer_Unpooled(b *testing.B) {
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		buf := make([]byte, DefaultAudioBufferSize)
		_ = buf
	}
}
