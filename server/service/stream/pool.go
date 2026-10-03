package stream

import (
	"bytes"
	"sync"
)

var BufferPool = sync.Pool{
	New: func() interface{} {
		return new(bytes.Buffer)
	},
}

const (
	DefaultFrameBufferSize   = 512 * 1024
	MaxPooledFrameBufferSize = 4 * 1024 * 1024
	DefaultAudioBufferSize   = 4 * 1024
	MaxPooledAudioBufferSize = 64 * 1024
)

// FrameBufferPool provides reusable *[]byte buffers for video frame ingestion.
// Default capacity of 512KB fits typical 1080p/2K/4K P-frames without allocation,
// expanding automatically for large I-frames.
var FrameBufferPool = sync.Pool{
	New: func() any {
		b := make([]byte, DefaultFrameBufferSize)
		return &b
	},
}

// AudioBufferPool provides reusable *[]byte buffers for audio packet ingestion.
var AudioBufferPool = sync.Pool{
	New: func() any {
		b := make([]byte, DefaultAudioBufferSize)
		return &b
	},
}

// PutFrameBuffer safely returns a frame buffer to the pool, resetting oversized slices.
func PutFrameBuffer(bufPtr *[]byte) {
	if bufPtr == nil {
		return
	}
	if *bufPtr == nil || cap(*bufPtr) > MaxPooledFrameBufferSize || cap(*bufPtr) < DefaultFrameBufferSize {
		b := make([]byte, DefaultFrameBufferSize)
		*bufPtr = b
	} else {
		*bufPtr = (*bufPtr)[:DefaultFrameBufferSize]
	}
	FrameBufferPool.Put(bufPtr)
}

// PutAudioBuffer safely returns an audio buffer to the pool, resetting oversized slices.
func PutAudioBuffer(bufPtr *[]byte) {
	if bufPtr == nil {
		return
	}
	if *bufPtr == nil || cap(*bufPtr) > MaxPooledAudioBufferSize || cap(*bufPtr) < DefaultAudioBufferSize {
		b := make([]byte, DefaultAudioBufferSize)
		*bufPtr = b
	} else {
		*bufPtr = (*bufPtr)[:DefaultAudioBufferSize]
	}
	AudioBufferPool.Put(bufPtr)
}

