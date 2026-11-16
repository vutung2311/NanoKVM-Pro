package stream

import (
	"testing"
	"time"
)

type fakeEncoder struct {
	fps  int
	sets []uint8
	fail bool
}

func (e *fakeEncoder) set(fps uint8) int {
	if e.fail {
		return -1
	}
	e.fps = int(fps)
	e.sets = append(e.sets, fps)
	return 0
}

func (e *fakeEncoder) get() int { return e.fps }

func newTestGovernor(fps int) (*FpsGovernor, *fakeEncoder, *time.Time) {
	clock := time.Unix(1000, 0)
	enc := &fakeEncoder{fps: fps}
	g := newFpsGovernor(func() time.Time { return clock }, enc.set, enc.get)
	return g, enc, &clock
}

func TestGovernorLowersAfterIdleAndWakesOnInput(t *testing.T) {
	g, enc, clock := newTestGovernor(60)

	g.NoteFrame(500, false)
	if enc.fps != 60 {
		t.Fatalf("lowered before idleAfter: %d", enc.fps)
	}

	*clock = clock.Add(idleAfter)
	g.NoteFrame(500, false)
	if enc.fps != idleFps {
		t.Fatalf("want %d fps after idle, got %d", idleFps, enc.fps)
	}
	g.NoteFrame(500, false)
	if len(enc.sets) != 1 {
		t.Fatalf("rate set again while idle: %v", enc.sets)
	}

	g.Wake()
	if enc.fps != 60 {
		t.Fatalf("input did not restore 60 fps: %d", enc.fps)
	}
	*clock = clock.Add(idleAfter - time.Millisecond)
	g.NoteFrame(500, false)
	if enc.fps != 60 {
		t.Fatal("input did not restart the idle timer")
	}
}

func TestGovernorSustainedLargeFramesAreActivity(t *testing.T) {
	g, enc, clock := newTestGovernor(60)
	*clock = clock.Add(idleAfter)
	g.NoteFrame(500, false)
	if enc.fps != idleFps {
		t.Fatalf("not idle: %d", enc.fps)
	}

	g.NoteFrame(200000, true) // keyframe: large on any screen
	if enc.fps != idleFps {
		t.Fatal("keyframe woke the encoder")
	}

	// A blink or a clock: one large frame a second never counts as busy.
	for i := 0; i < 10; i++ {
		*clock = clock.Add(time.Second)
		g.NoteFrame(20000, false)
	}
	if enc.fps != idleFps {
		t.Fatalf("occasional large frames woke the encoder: %d", enc.fps)
	}

	// A video: large frames back to back, here at the idle rate.
	for i := 0; i < busyFrames; i++ {
		*clock = clock.Add(time.Second / idleFps)
		g.NoteFrame(25000, false)
	}
	if enc.fps != 60 {
		t.Fatalf("sustained large frames did not restore 60 fps: %d", enc.fps)
	}
}

func TestGovernorKeepsConfiguredRate(t *testing.T) {
	g, enc, clock := newTestGovernor(60)

	if g.SetTarget(30) < 0 || enc.fps != 30 {
		t.Fatalf("SetTarget(30): %d", enc.fps)
	}
	*clock = clock.Add(idleAfter)
	g.NoteFrame(500, false)
	g.Wake()
	if enc.fps != 30 {
		t.Fatalf("restored %d instead of the configured 30", enc.fps)
	}

	// A configured rate at or below the idle rate is never changed.
	g.SetTarget(10)
	*clock = clock.Add(idleAfter)
	g.NoteFrame(500, false)
	if enc.fps != 10 {
		t.Fatalf("lowered a 10 fps setting to %d", enc.fps)
	}
}

func TestGovernorSetTargetWhileIdle(t *testing.T) {
	g, enc, clock := newTestGovernor(60)
	*clock = clock.Add(idleAfter)
	g.NoteFrame(500, false)

	g.SetTarget(50)
	if enc.fps != 50 {
		t.Fatalf("SetTarget while idle: %d", enc.fps)
	}
	g.Wake() // not idle any more: nothing to restore
	if n := len(enc.sets); enc.sets[n-1] != 50 || n != 2 {
		t.Fatalf("unexpected sets %v", enc.sets)
	}
}

func TestGovernorRetriesFailedRestore(t *testing.T) {
	g, enc, clock := newTestGovernor(60)
	*clock = clock.Add(idleAfter)
	g.NoteFrame(500, false)

	enc.fail = true
	g.Wake()
	enc.fail = false
	g.Wake()
	if enc.fps != 60 {
		t.Fatalf("failed restore not retried: %d", enc.fps)
	}
}

func TestGovernorMeasuresUnconfiguredRate(t *testing.T) {
	// libkvm reports 0 until the first kvmv_set_fps after boot.
	g, enc, clock := newTestGovernor(0)

	for i := 0; i < int(idleAfter/time.Second)*60; i++ {
		*clock = clock.Add(time.Second / 60)
		g.NoteFrame(500, false)
	}
	*clock = clock.Add(time.Second / 60)
	g.NoteFrame(500, false)
	if enc.fps != idleFps {
		t.Fatalf("not lowered with an unconfigured rate: %d", enc.fps)
	}
	g.Wake()
	if enc.fps != 60 {
		t.Fatalf("restored %d instead of the measured 60", enc.fps)
	}
}
