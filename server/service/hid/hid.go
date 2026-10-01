package hid

import (
	"errors"
	"os"
	"sync"
	"time"

	log "github.com/sirupsen/logrus"
)

type Hid struct {
	g0         *os.File
	g1         *os.File
	g2         *os.File
	kbMutex    sync.Mutex
	mouseMutex sync.Mutex
}

const (
	HID0 = "/dev/hidg0" // Keyboard
	HID1 = "/dev/hidg1" // Mouse (Relative Mode)
	HID2 = "/dev/hidg2" // Touchpad (Absolute Mode)
)

var (
	hid     *Hid
	hidOnce sync.Once
)

func GetHid() *Hid {
	hidOnce.Do(func() {
		hid = &Hid{}
	})
	return hid
}

func (h *Hid) Lock() {
	h.kbMutex.Lock()
	h.mouseMutex.Lock()
}

func (h *Hid) Unlock() {
	h.kbMutex.Unlock()
	h.mouseMutex.Unlock()
}

func (h *Hid) OpenNoLock() {
	var err error
	h.CloseNoLock()

	h.g0, err = os.OpenFile(HID0, os.O_WRONLY, 0o666)
	if err != nil {
		log.Warnf("open %s failed: %s", HID0, err)
		h.g0 = nil
	}

	h.g1, err = os.OpenFile(HID1, os.O_WRONLY, 0o666)
	if err != nil {
		log.Warnf("open %s failed: %s", HID1, err)
		h.g1 = nil
	}

	h.g2, err = os.OpenFile(HID2, os.O_WRONLY, 0o666)
	if err != nil {
		// HID2 is optional (touchpad/absolute pointer)
		log.Debugf("open %s failed (optional): %s", HID2, err)
		h.g2 = nil
	}
}

func (h *Hid) CloseNoLock() {
	if h.g0 != nil {
		_ = h.g0.Sync()
		_ = h.g0.Close()
		h.g0 = nil
	}
	if h.g1 != nil {
		_ = h.g1.Sync()
		_ = h.g1.Close()
		h.g1 = nil
	}
	if h.g2 != nil {
		_ = h.g2.Sync()
		_ = h.g2.Close()
		h.g2 = nil
	}
}

func (h *Hid) Open() {
	h.kbMutex.Lock()
	defer h.kbMutex.Unlock()
	h.mouseMutex.Lock()
	defer h.mouseMutex.Unlock()

	h.CloseNoLock()
	h.OpenNoLock()
}

func (h *Hid) Close() {
	h.kbMutex.Lock()
	defer h.kbMutex.Unlock()
	h.mouseMutex.Lock()
	defer h.mouseMutex.Unlock()

	h.CloseNoLock()
}

func (h *Hid) recoverFile(filePtr **os.File, path string, data []byte, deadline time.Duration) {
	if *filePtr != nil {
		_ = (*filePtr).Close()
		*filePtr = nil
	}
	f, err := os.OpenFile(path, os.O_WRONLY, 0o666)
	if err != nil {
		log.Debugf("reopen %s failed: %s", path, err)
		return
	}
	*filePtr = f
	if len(data) > 0 {
		_ = f.SetWriteDeadline(time.Now().Add(deadline))
		_, _ = f.Write(data)
	}
}

func (h *Hid) WriteHid0(data []byte) {
	h.kbMutex.Lock()
	defer h.kbMutex.Unlock()

	if h.g0 == nil {
		var err error
		h.g0, err = os.OpenFile(HID0, os.O_WRONLY, 0o666)
		if err != nil {
			log.Debugf("reopen %s failed: %s", HID0, err)
			return
		}
	}

	deadline := time.Now().Add(20 * time.Millisecond)
	_ = h.g0.SetWriteDeadline(deadline)
	_, err := h.g0.Write(data)

	if err != nil {
		if errors.Is(err, os.ErrDeadlineExceeded) {
			log.Debugf("write to %s timeout (host not polling)", HID0)
			return
		}
		log.Warnf("write to %s failed (%s), recovering", HID0, err)
		h.recoverFile(&h.g0, HID0, data, 20*time.Millisecond)
		return
	}

	log.Debugf("write to %s: %v", HID0, data)
}

func (h *Hid) WriteHid1(data []byte) {
	h.mouseMutex.Lock()
	defer h.mouseMutex.Unlock()

	if h.g1 == nil {
		var err error
		h.g1, err = os.OpenFile(HID1, os.O_WRONLY, 0o666)
		if err != nil {
			log.Debugf("reopen %s failed: %s", HID1, err)
			return
		}
	}

	deadline := time.Now().Add(15 * time.Millisecond)
	_ = h.g1.SetWriteDeadline(deadline)
	_, err := h.g1.Write(data)

	if err != nil {
		if errors.Is(err, os.ErrDeadlineExceeded) {
			log.Debugf("write to %s timeout (host not polling)", HID1)
			return
		}
		log.Warnf("write to %s failed (%s), recovering", HID1, err)
		h.recoverFile(&h.g1, HID1, data, 15*time.Millisecond)
		return
	}

	log.Debugf("write to %s: %v", HID1, data)
}

func (h *Hid) WriteHid2(data []byte) {
	h.mouseMutex.Lock()
	defer h.mouseMutex.Unlock()

	if h.g2 == nil {
		var err error
		h.g2, err = os.OpenFile(HID2, os.O_WRONLY, 0o666)
		if err != nil {
			// HID2 is optional; if not present, drop silently
			return
		}
	}

	deadline := time.Now().Add(15 * time.Millisecond)
	_ = h.g2.SetWriteDeadline(deadline)
	_, err := h.g2.Write(data)

	if err != nil {
		if errors.Is(err, os.ErrDeadlineExceeded) {
			log.Debugf("write to %s timeout (host not polling)", HID2)
			return
		}
		log.Warnf("write to %s failed (%s), recovering", HID2, err)
		h.recoverFile(&h.g2, HID2, data, 15*time.Millisecond)
		return
	}

	log.Debugf("write to %s: %v", HID2, data)
}
