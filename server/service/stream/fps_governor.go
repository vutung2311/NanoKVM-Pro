package stream

import (
	"sync"
	"time"

	"NanoKVM-Server/common"

	log "github.com/sirupsen/logrus"
)

// Idle frame rate.
//
// The encoder produces frames at the configured rate whether or not the
// screen changes, and every frame costs the server a read, packetisation,
// encryption and a send. On a static 2560x1440 screen the device measured
// 26% server CPU at 60 fps against 9% at 15 fps (23% against 13% for the
// whole system), so while nothing happens the governor lowers the encoder to
// idleFps. Anything that may change the picture restores the configured rate
// at once: keyboard or mouse input (before the report reaches the host, so
// the first changed frame is already captured at the full rate), or
// busyFrames inter frames larger than busyFrameBytes within busyWindow (the
// host changes the screen by itself, e.g. a video). MJPEG has no inter frames
// to measure, so the MJPEG loop wakes the governor with every frame.
//
// One large frame is not enough: on an otherwise static desktop a blinking
// cursor or a clock makes about one a second (measured: p50 442 B, p99
// 10 KB, max 25 KB), while a video makes nearly every frame large (p10 24 KB).
// Keyframes are left out, as they are large on any screen.
const (
	idleFps        = 15
	idleAfter      = 3 * time.Second
	busyFrameBytes = 4096
	busyFrames     = 4
	busyWindow     = time.Second
)

type FpsGovernor struct {
	mu       sync.Mutex
	target   uint8 // rate to restore; 0 until known
	idle     bool
	lastBusy time.Time
	frames   int                   // frames since lastBusy, to measure an unconfigured rate
	large    [busyFrames]time.Time // arrival of the last large inter frames
	nLarge   int

	now    func() time.Time
	setFps func(uint8) int
	getFps func() int
}

var (
	governor     *FpsGovernor
	governorOnce sync.Once
)

// GetFpsGovernor returns the governor driving the shared encoder, and makes
// HID input wake it.
func GetFpsGovernor() *FpsGovernor {
	governorOnce.Do(func() {
		vision := common.GetKvmVision()
		governor = newFpsGovernor(time.Now, vision.SetFps, vision.GetFps)
		common.SetInputHook(governor.Wake)
	})
	return governor
}

func newFpsGovernor(now func() time.Time, set func(uint8) int, get func() int) *FpsGovernor {
	return &FpsGovernor{now: now, setFps: set, getFps: get, lastBusy: now()}
}

// SetTarget sets the configured frame rate and applies it now.
func (g *FpsGovernor) SetTarget(fps uint8) int {
	g.mu.Lock()
	defer g.mu.Unlock()

	result := g.setFps(fps)
	if result < 0 {
		return result
	}
	g.target = fps
	g.idle = false
	g.lastBusy = g.now()
	return result
}

// Wake restores the configured rate if it was lowered, and restarts the
// idle timer.
func (g *FpsGovernor) Wake() {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.busyLocked()
}

// NoteFrame records one encoded H.264/H.265 frame of size bytes and lowers
// the rate once the screen has been idle for idleAfter.
func (g *FpsGovernor) NoteFrame(size int, keyframe bool) {
	g.mu.Lock()
	defer g.mu.Unlock()

	if !keyframe && size > busyFrameBytes && g.noteLargeLocked() {
		g.busyLocked()
		return
	}
	g.frames++
	elapsed := g.now().Sub(g.lastBusy)
	if g.idle || elapsed < idleAfter {
		return
	}

	if g.target == 0 {
		g.target = g.currentRateLocked(elapsed)
	}
	if g.target <= idleFps {
		return
	}
	if g.setFps(idleFps) >= 0 {
		g.idle = true
		log.Debugf("screen idle: encoder rate %d -> %d fps", g.target, idleFps)
	}
}

// noteLargeLocked records a large inter frame and reports whether it is the
// busyFrames-th within busyWindow.
func (g *FpsGovernor) noteLargeLocked() bool {
	now := g.now()
	oldest := g.large[g.nLarge%busyFrames] // overwritten next: busyFrames back
	g.large[g.nLarge%busyFrames] = now
	g.nLarge++
	return g.nLarge >= busyFrames && now.Sub(oldest) <= busyWindow
}

// currentRateLocked is the rate to restore when none was configured: the
// encoder's, or, while libkvm still reports 0 (its value until the first
// kvmv_set_fps after boot, when the encoder runs at the capture rate), the
// rate the frames arrived at.
func (g *FpsGovernor) currentRateLocked(elapsed time.Duration) uint8 {
	if fps := g.getFps(); fps > 0 {
		return uint8(min(fps, 120))
	}
	measured := float64(g.frames) / elapsed.Seconds()
	return uint8(max(1, min(120, int(measured+0.5))))
}

func (g *FpsGovernor) busyLocked() {
	g.lastBusy = g.now()
	g.frames = 0
	if !g.idle {
		return
	}
	if g.setFps(g.target) < 0 {
		log.Errorf("failed to restore encoder rate %d fps", g.target) // retried on the next event
		return
	}
	g.idle = false
	log.Debugf("screen busy: encoder rate %d -> %d fps", idleFps, g.target)
}
