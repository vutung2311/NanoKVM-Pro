package jiggler

import (
	"sync"
	"testing"
	"time"
)

func TestJiggler_EnableDisableImmediateStop(t *testing.T) {
	j := &Jiggler{
		mode: "relative",
	}
	j.lastUpdated.Store(time.Now().UnixNano())

	j.mutex.Lock()
	j.enabled = true
	j.mutex.Unlock()

	j.Run()

	if !j.IsEnabled() {
		t.Fatal("expected jiggler to be enabled")
	}

	start := time.Now()
	// Disable should cancel ticker immediately, well within 15s interval
	j.mutex.Lock()
	j.enabled = false
	if j.stopChan != nil {
		close(j.stopChan)
		j.stopChan = nil
	}
	j.running = 0
	j.mutex.Unlock()

	elapsed := time.Since(start)
	if elapsed > 1*time.Second {
		t.Fatalf("expected immediate stop, took %v", elapsed)
	}

	if j.IsEnabled() {
		t.Fatal("expected jiggler to be disabled")
	}
}

func TestJiggler_ConcurrentUpdatesUnderRace(t *testing.T) {
	j := &Jiggler{
		mode: "relative",
	}
	j.lastUpdated.Store(time.Now().UnixNano())
	j.running = 1

	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for k := 0; k < 1000; k++ {
				j.Update()
			}
		}()
	}

	wg.Wait()
}
