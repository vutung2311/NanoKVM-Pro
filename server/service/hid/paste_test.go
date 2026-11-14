package hid

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

type fakeKeyboard struct {
	mu      sync.Mutex
	reports [][]byte
	failAt  int // fail the Nth SubmitKeyboardWait (1-based); 0 = never
	waits   int
	onWait  func(n int)
}

func (f *fakeKeyboard) SubmitKeyboard(r []byte) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.reports = append(f.reports, append([]byte(nil), r...))
}

func (f *fakeKeyboard) SubmitKeyboardWait(r []byte, _ time.Duration) error {
	f.mu.Lock()
	f.waits++
	n := f.waits
	f.reports = append(f.reports, append([]byte(nil), r...))
	f.mu.Unlock()
	if f.onWait != nil {
		f.onWait(n)
	}
	if f.failAt == n {
		return ErrReportTimeout
	}
	return nil
}

func (f *fakeKeyboard) last() []byte {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.reports[len(f.reports)-1]
}

func isRelease(r []byte) bool {
	for _, b := range r {
		if b != 0 {
			return false
		}
	}
	return true
}

func TestTypeTextTypesAll(t *testing.T) {
	kb := &fakeKeyboard{}
	n, err := typeText(context.Background(), kb, "aB")
	if err != nil || n != 2 {
		t.Fatalf("typeText = %d, %v; want 2, nil", n, err)
	}
	// 'a': down, up; 'B': modDown, keyDown, modDown, up
	if len(kb.reports) != 6 || !isRelease(kb.last()) {
		t.Fatalf("reports = %v", kb.reports)
	}
}

// Cancelling mid-press (client went away) stops typing and releases keys.
func TestTypeTextStopsOnCancelAndReleases(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	kb := &fakeKeyboard{}
	kb.onWait = func(n int) {
		if n == 3 { // keyDown of the second character
			cancel()
		}
	}
	n, err := typeText(ctx, kb, "abcdef")
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want context.Canceled", err)
	}
	if n != 1 {
		t.Fatalf("typed %d characters, want 1", n)
	}
	if !isRelease(kb.last()) {
		t.Fatalf("last report %v is not a release", kb.last())
	}
}

func TestTypeTextReleasesAfterRejectedReport(t *testing.T) {
	kb := &fakeKeyboard{failAt: 1}
	if _, err := typeText(context.Background(), kb, "a"); !errors.Is(err, ErrReportTimeout) {
		t.Fatalf("err = %v, want ErrReportTimeout", err)
	}
	if !isRelease(kb.last()) {
		t.Fatalf("last report %v is not a release", kb.last())
	}
}
