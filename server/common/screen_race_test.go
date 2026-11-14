package common

import (
	"sync"
	"testing"
)

// Settings handlers and capture loops touch Screen concurrently; with the
// race detector this fails if any access bypasses the lock.
func TestScreenConcurrentUpdateAndCheck(t *testing.T) {
	s := &Screen{BitRate: 8000, GOP: 50, Quality: 80}
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		for i := 0; i < 1000; i++ {
			s.Update(func(s *Screen) { s.BitRate = uint16(1000 + i); s.FPS = uint8(i % 60) })
		}
	}()
	go func() {
		defer wg.Done()
		for i := 0; i < 1000; i++ {
			p := s.Check()
			if p.BitRate < 1000 {
				t.Errorf("Check returned unclamped bitrate %d", p.BitRate)
				return
			}
			_ = s.Snapshot()
		}
	}()
	wg.Wait()
}
