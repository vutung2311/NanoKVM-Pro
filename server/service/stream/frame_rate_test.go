package stream

import (
	"testing"
	"time"
)

func TestPollTickerFollowsRateChange(t *testing.T) {
	d := 25 * time.Millisecond
	p := newPollTicker(func() time.Duration { return d })
	defer p.Stop()

	d = 10 * time.Millisecond
	p.Refresh() // too soon: unchanged
	if p.Interval() != 25*time.Millisecond {
		t.Fatalf("interval changed before refresh interval: %s", p.Interval())
	}

	p.checked = time.Now().Add(-pollRefreshInterval)
	p.Refresh()
	if p.Interval() != 10*time.Millisecond {
		t.Fatalf("interval = %s, want 10ms after refresh", p.Interval())
	}
	select {
	case <-p.C():
	case <-time.After(time.Second):
		t.Fatal("ticker stopped delivering after reset")
	}
}
