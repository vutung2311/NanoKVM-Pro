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

func TestPutFrameBuffer_ResetOversized(t *testing.T) {
	oversized := make([]byte, MaxPooledFrameBufferSize+1024)
	bufPtr := &oversized

	PutFrameBuffer(bufPtr)

	if cap(*bufPtr) > MaxPooledFrameBufferSize {
		t.Fatalf("expected oversized buffer to be reset to cap <= %d, got %d", MaxPooledFrameBufferSize, cap(*bufPtr))
	}
	if len(*bufPtr) != DefaultFrameBufferSize {
		t.Fatalf("expected reset buffer len %d, got %d", DefaultFrameBufferSize, len(*bufPtr))
	}
}

func TestPutAudioBuffer_ResetOversized(t *testing.T) {
	oversized := make([]byte, MaxPooledAudioBufferSize+1024)
	bufPtr := &oversized

	PutAudioBuffer(bufPtr)

	if cap(*bufPtr) > MaxPooledAudioBufferSize {
		t.Fatalf("expected oversized audio buffer to be reset to cap <= %d, got %d", MaxPooledAudioBufferSize, cap(*bufPtr))
	}
	if len(*bufPtr) != DefaultAudioBufferSize {
		t.Fatalf("expected reset audio buffer len %d, got %d", DefaultAudioBufferSize, len(*bufPtr))
	}
}

func TestPutFrameBuffer_PointerToNilSlice(t *testing.T) {
	var nilSlice []byte
	bufPtr := &nilSlice
	PutFrameBuffer(bufPtr)

	if *bufPtr == nil || len(*bufPtr) != DefaultFrameBufferSize {
		t.Fatalf("expected initialized buffer, got %v", *bufPtr)
	}
}

func TestPutAudioBuffer_PointerToNilSlice(t *testing.T) {
	var nilSlice []byte
	bufPtr := &nilSlice
	PutAudioBuffer(bufPtr)

	if *bufPtr == nil || len(*bufPtr) != DefaultAudioBufferSize {
		t.Fatalf("expected initialized audio buffer, got %v", *bufPtr)
	}
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

func TestPutFrameBuffer_ResetUndersized(t *testing.T) {
	undersized := make([]byte, 128)
	bufPtr := &undersized

	PutFrameBuffer(bufPtr)

	if len(*bufPtr) != DefaultFrameBufferSize || cap(*bufPtr) < DefaultFrameBufferSize {
		t.Fatalf("expected undersized buffer reset to len=%d cap>=%d, got len=%d cap=%d", DefaultFrameBufferSize, DefaultFrameBufferSize, len(*bufPtr), cap(*bufPtr))
	}
}

func TestPutAudioBuffer_ResetUndersized(t *testing.T) {
	undersized := make([]byte, 64)
	bufPtr := &undersized

	PutAudioBuffer(bufPtr)

	if len(*bufPtr) != DefaultAudioBufferSize || cap(*bufPtr) < DefaultAudioBufferSize {
		t.Fatalf("expected undersized audio buffer reset to len=%d cap>=%d, got len=%d cap=%d", DefaultAudioBufferSize, DefaultAudioBufferSize, len(*bufPtr), cap(*bufPtr))
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
