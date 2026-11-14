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

func GetStreamTickerDuration() time.Duration {
	screen := common.GetScreen()
	targetFps := int(screen.Snapshot().FPS)
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

// pollRefreshInterval is how often a running stream re-reads its target fps,
// so an fps change (setting or HDMI input) applies without reconnecting.
const pollRefreshInterval = 2 * time.Second

// PollTicker paces a stream's encoder reads at GetStreamTickerDuration and
// follows changes to it while the stream runs.
type PollTicker struct {
	t       *time.Ticker
	d       time.Duration
	checked time.Time
	compute func() time.Duration
}

func NewPollTicker() *PollTicker {
	return newPollTicker(GetStreamTickerDuration)
}

func newPollTicker(compute func() time.Duration) *PollTicker {
	d := compute()
	return &PollTicker{t: time.NewTicker(d), d: d, checked: time.Now(), compute: compute}
}

// C is the tick channel; it stays the same across Refresh.
func (p *PollTicker) C() <-chan time.Time { return p.t.C }

// Refresh re-reads the target rate at most every pollRefreshInterval and
// resets the ticker if it changed. Call it from the loop that reads C.
func (p *PollTicker) Refresh() {
	now := time.Now()
	if now.Sub(p.checked) < pollRefreshInterval {
		return
	}
	p.checked = now
	if d := p.compute(); d > 0 && d != p.d {
		p.d = d
		p.t.Reset(d)
	}
}

// Interval returns the current tick interval.
func (p *PollTicker) Interval() time.Duration { return p.d }

func (p *PollTicker) Stop() { p.t.Stop() }
