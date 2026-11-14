package common

import (
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Screen struct {
	mutex sync.Mutex

	Width  uint16
	Height uint16

	StreamType      int
	RateControlMode uint8
	BitRate         uint16
	FPS             uint8
	GOP             uint8
	Quality         uint16

	RealFPS int

	lastCheck time.Time
}

const (
	WidthPath  = "/proc/lt6911_info/width"
	HeightPath = "/proc/lt6911_info/height"
)

var (
	screen     *Screen
	screenOnce sync.Once
)

var StreamTypeMap = map[string]int{
	"mjpeg":       STREAM_TYPE_MJPEG,
	"h264-webrtc": STREAM_TYPE_H264_WEBRTC,
	"h264-direct": STREAM_TYPE_H264_DIRECT,
	"h265-webrtc": STREAM_TYPE_H265_WEBRTC,
	"h265-direct": STREAM_TYPE_H265_DIRECT,
}

func GetScreen() *Screen {
	screenOnce.Do(func() {
		screen = &Screen{
			Width:  readSize(WidthPath),
			Height: readSize(HeightPath),

			StreamType:      STREAM_TYPE_H264_WEBRTC,
			RateControlMode: RATE_CONTROL_VBR,
			BitRate:         8000,
			FPS:             0,
			GOP:             50,
			Quality:         80,

			RealFPS: 0,

			lastCheck: time.Now(),
		}
	})

	return screen
}

// ScreenParams is a consistent copy of the stream parameters. Settings
// handlers write Screen while capture loops read it, so readers take a
// snapshot under the lock instead of reading fields directly.
type ScreenParams struct {
	Width           uint16
	Height          uint16
	StreamType      int
	RateControlMode uint8
	BitRate         uint16
	FPS             uint8
	GOP             uint8
	Quality         uint16
	RealFPS         int
}

func (s *Screen) paramsLocked() ScreenParams {
	return ScreenParams{
		Width:           s.Width,
		Height:          s.Height,
		StreamType:      s.StreamType,
		RateControlMode: s.RateControlMode,
		BitRate:         s.BitRate,
		FPS:             s.FPS,
		GOP:             s.GOP,
		Quality:         s.Quality,
		RealFPS:         s.RealFPS,
	}
}

// Snapshot returns the current parameters without refreshing them.
func (s *Screen) Snapshot() ScreenParams {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	return s.paramsLocked()
}

// Update changes parameters under the lock.
func (s *Screen) Update(fn func(s *Screen)) {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	fn(s)
}

// Check refreshes the resolution (at most every 5 s), clamps invalid values
// and returns a snapshot to use for one frame read.
func (s *Screen) Check() ScreenParams {
	s.mutex.Lock()
	defer s.mutex.Unlock()

	if time.Since(s.lastCheck) >= 5*time.Second {
		w := readSize(WidthPath)
		h := readSize(HeightPath)
		if (w > 0 && h > 0) || (s.Width == 0 && s.Height == 0) {
			s.Width = w
			s.Height = h
		}
		s.lastCheck = time.Now()
	}

	if s.FPS < 0 || s.FPS > 120 {
		s.FPS = 0
	}

	if s.BitRate < 1000 || s.BitRate > 20000 {
		if s.RateControlMode == RATE_CONTROL_CBR {
			s.BitRate = 5000
		} else {
			s.BitRate = 8000
		}
	}

	if s.GOP < 1 || s.GOP > 200 {
		s.GOP = 50
	}

	if s.Quality < 1 || s.Quality > 100 {
		s.Quality = 80
	}
	return s.paramsLocked()
}

func readSize(filePath string) uint16 {
	data, err := os.ReadFile(filePath)
	if err != nil {
		return 0
	}

	width, err := strconv.ParseUint(strings.TrimSpace(string(data)), 10, 16)
	if err != nil {
		return 0
	}

	return uint16(width)
}
