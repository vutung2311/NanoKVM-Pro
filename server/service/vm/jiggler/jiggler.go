package jiggler

import (
	"NanoKVM-Server/service/hid"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	ConfigFile = "/etc/kvm/mouse-jiggler"
	Interval   = 15 * time.Second
)

var (
	jiggler Jiggler
	once    sync.Once
)

type Jiggler struct {
	mutex       sync.Mutex
	enabled     bool
	running     int32
	mode        string
	lastUpdated atomic.Int64
	stopChan    chan struct{}
}

func GetJiggler() *Jiggler {
	once.Do(func() {
		jiggler = Jiggler{
			mutex:   sync.Mutex{},
			enabled: false,
			mode:    "relative",
		}
		jiggler.lastUpdated.Store(time.Now().UnixNano())

		content, err := os.ReadFile(ConfigFile)
		if err != nil {
			return
		}

		mode := strings.ReplaceAll(string(content), "\n", "")
		if mode != "" {
			jiggler.mode = mode
		}

		jiggler.enabled = true
	})

	return &jiggler
}

func (j *Jiggler) Enable(mode string) error {
	err := os.WriteFile(ConfigFile, []byte(mode), 0644)
	if err != nil {
		return err
	}

	j.mutex.Lock()
	j.enabled = true
	j.mode = mode
	j.mutex.Unlock()

	j.Run()

	return nil
}

func (j *Jiggler) Disable() error {
	if err := os.Remove(ConfigFile); err != nil {
		return err
	}

	j.mutex.Lock()
	j.enabled = false
	j.mode = "relative"
	if j.stopChan != nil {
		close(j.stopChan)
		j.stopChan = nil
	}
	atomic.StoreInt32(&j.running, 0)
	j.mutex.Unlock()

	return nil
}

func (j *Jiggler) Run() {
	j.mutex.Lock()
	if !j.enabled || atomic.LoadInt32(&j.running) == 1 {
		j.mutex.Unlock()
		return
	}

	atomic.StoreInt32(&j.running, 1)
	stopChan := make(chan struct{})
	j.stopChan = stopChan
	mode := j.mode
	j.mutex.Unlock()

	j.Update()

	go func() {
		ticker := time.NewTicker(Interval)
		defer ticker.Stop()

		for {
			select {
			case <-stopChan:
				return
			case <-ticker.C:
				j.mutex.Lock()
				if !j.enabled {
					atomic.StoreInt32(&j.running, 0)
					j.mutex.Unlock()
					return
				}
				currentMode := j.mode
				if mode != currentMode {
					mode = currentMode
				}
				j.mutex.Unlock()

				last := time.Unix(0, j.lastUpdated.Load())
				if time.Since(last) > Interval {
					move(mode)
					j.Update()
				}
			}
		}
	}()
}

func (j *Jiggler) Update() {
	if atomic.LoadInt32(&j.running) == 1 {
		j.lastUpdated.Store(time.Now().UnixNano())
	}
}

func (j *Jiggler) IsEnabled() bool {
	j.mutex.Lock()
	defer j.mutex.Unlock()
	return j.enabled
}

func (j *Jiggler) GetMode() string {
	j.mutex.Lock()
	defer j.mutex.Unlock()
	return j.mode
}

func move(mode string) {
	h := hid.GetHid()

	if mode == "absolute" {
		h.WriteHid2([]byte{0x00, 0x00, 0x3f, 0x00, 0x3f, 0x00})
		time.Sleep(100 * time.Millisecond)
		h.WriteHid2([]byte{0x00, 0xff, 0x3f, 0xff, 0x3f, 0x00})
	} else {
		h.WriteHid1([]byte{0x00, 0xa, 0xa, 0x00})
		time.Sleep(100 * time.Millisecond)
		h.WriteHid1([]byte{0x00, 0xf6, 0xf6, 0x00})
	}
}
