package stream

import (
	"testing"
	"time"
)

func newTestPacer() (*ReadPacer, *[]time.Duration) {
	var slept []time.Duration
	p := NewReadPacer()
	p.sleep = func(d time.Duration) { slept = append(slept, d) }
	return p, &slept
}

// A frame or a read that blocked (encoder timeout) is followed by the next
// read at once: the encoder paces the loop, not a timer.
func TestReadPacerNoWaitAfterFrameOrBlockedRead(t *testing.T) {
	p, slept := newTestPacer()
	p.Got()
	p.Missed(300 * time.Millisecond) // GetStream timed out: already paced
	p.Got()
	if len(*slept) != 0 {
		t.Fatalf("slept %v, want no waits", *slept)
	}
}

// A read that fails at once backs off, doubling up to readBackoffMax, and a
// frame resets the backoff.
func TestReadPacerBacksOffOnFastFailures(t *testing.T) {
	p, slept := newTestPacer()
	for i := 0; i < 7; i++ {
		p.Missed(0)
	}
	want := []time.Duration{5, 10, 20, 40, 80, 100, 100}
	for i, w := range want {
		if (*slept)[i] != w*time.Millisecond {
			t.Fatalf("backoff %d = %v, want %v (all: %v)", i, (*slept)[i], w*time.Millisecond, *slept)
		}
	}

	p.Got()
	p.Missed(0)
	if last := (*slept)[len(*slept)-1]; last != readBackoffMin {
		t.Fatalf("after a frame the backoff restarted at %v, want %v", last, readBackoffMin)
	}
}

func TestReadPacerIdleWaits(t *testing.T) {
	p, slept := newTestPacer()
	p.Idle()
	if len(*slept) != 1 || (*slept)[0] != readIdleWait {
		t.Fatalf("Idle slept %v, want [%v]", *slept, readIdleWait)
	}
}
