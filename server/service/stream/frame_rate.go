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

				screen.RealFPS = int(counter.fps)
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

func GetStreamTickerDuration() time.Duration {
	screen := common.GetScreen()
	targetFps := int(screen.FPS)
	if targetFps <= 0 {
		if hwFps := common.GetKvmVision().GetFps(); hwFps > 0 && hwFps <= 120 {
			targetFps = hwFps
		} else {
			targetFps = 60
		}
	}

	pollRate := (targetFps * 5) / 4
	if pollRate < 40 {
		pollRate = 40
	} else if pollRate > 120 {
		pollRate = 120
	}

	return time.Second / time.Duration(pollRate)
}
