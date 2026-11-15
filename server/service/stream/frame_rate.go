package stream

import (
	"NanoKVM-Server/common"
	"sync"
	"sync/atomic"
	"time"
)

var (
	counter     *FrameRateCounter
	counterOnce sync.Once
)

type FrameRateCounter struct {
	frameCount int32
	fps        int32
	mutex      sync.Mutex
}

func GetFrameRateCounter() *FrameRateCounter {
	screen := common.GetScreen()

	counterOnce.Do(func() {
		counter = &FrameRateCounter{}

		go func() {
			ticker := time.NewTicker(3 * time.Second)
			defer ticker.Stop()

			for range ticker.C {
				counter.mutex.Lock()

				currentCount := atomic.LoadInt32(&counter.frameCount)

				counter.fps = currentCount / 3
				atomic.StoreInt32(&counter.frameCount, 0)

				counter.mutex.Unlock()

				fps := int(counter.fps)
				screen.Update(func(s *common.Screen) { s.RealFPS = fps })
			}
		}()
	})

	return counter
}

func (f *FrameRateCounter) Update() {
	atomic.AddInt32(&f.frameCount, 1)
}

func (f *FrameRateCounter) GetFPS() int32 {
	f.mutex.Lock()
	defer f.mutex.Unlock()

	return f.fps
}

// Read pacing for the video loops.
//
// kvmv_read_img blocks in AX_VENC_GetStream until the encoder has a frame
// (timeout 300 ms), so the loops read back to back and collect each frame the
// moment it is encoded. Polling on a timer instead left finished frames in the
// encoder's 2-deep output FIFO until the next tick, which backed up its
// 1-deep input FIFO and dropped input frames. The encoder's own output rate
// (kvmv_set_fps) paces the stream.
const (
	// A read that returns no frame faster than this did not block, so the
	// loop backs off rather than spinning on it.
	readFastFail   = 2 * time.Millisecond
	readBackoffMin = 5 * time.Millisecond
	readBackoffMax = 100 * time.Millisecond
	// Wait used while the stream is not the active codec.
	readIdleWait = 20 * time.Millisecond
)

// ReadPacer paces one video loop's encoder reads.
type ReadPacer struct {
	backoff time.Duration
	sleep   func(time.Duration)
}

func NewReadPacer() *ReadPacer {
	return &ReadPacer{sleep: time.Sleep}
}

// Got records a read that returned a frame; the next read follows at once.
func (p *ReadPacer) Got() { p.backoff = 0 }

// Missed records a read that returned no frame after took. A read that
// blocked (the encoder timed out) is already paced; one that failed at once
// backs off, doubling up to readBackoffMax.
func (p *ReadPacer) Missed(took time.Duration) {
	if took >= readFastFail {
		p.backoff = 0
		return
	}
	if p.backoff == 0 {
		p.backoff = readBackoffMin
	} else {
		p.backoff = min(p.backoff*2, readBackoffMax)
	}
	p.sleep(p.backoff)
}

// Idle waits while this stream is not the active codec.
func (p *ReadPacer) Idle() { p.sleep(readIdleWait) }
