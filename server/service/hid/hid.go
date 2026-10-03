package hid

import (
	"errors"
	"os"
	"sync"
	"syscall"
	"time"

	log "github.com/sirupsen/logrus"
)

type Hid struct {
	g0         *os.File
	g1         *os.File
	g2         *os.File
	legacyHid1 bool
	legacyHid2 bool
	kbMutex    sync.Mutex
	mouseMutex sync.Mutex

	// One writer goroutine per device serializes every producer (all WS
	// clients, paste, jiggler). Started lazily; see writer.go.
	writersOnce sync.Once
	kbInbox     chan hidMsg
	mouseInbox  chan hidMsg
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
	h.legacyHid1 = false
	h.legacyHid2 = false
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

func (h *Hid) recoverFile(filePtr **os.File, path string, data []byte, deadline time.Duration) error {
	if *filePtr != nil {
		_ = (*filePtr).Close()
		*filePtr = nil
	}
	f, err := os.OpenFile(path, os.O_WRONLY, 0o666)
	if err != nil {
		log.Debugf("reopen %s failed: %s", path, err)
		return err
	}
	*filePtr = f
	if len(data) == 0 {
		return nil
	}
	_ = f.SetWriteDeadline(time.Now().Add(deadline))
	_, err = f.Write(data)
	return err
}

// WriteHid0 writes a keyboard report. It returns nil once the report was
// accepted by the gadget, or the error if it was not (e.g. host not polling).
func (h *Hid) WriteHid0(data []byte) error {
	h.kbMutex.Lock()
	defer h.kbMutex.Unlock()

	if h.g0 == nil {
		var err error
		h.g0, err = os.OpenFile(HID0, os.O_WRONLY, 0o666)
		if err != nil {
			log.Debugf("reopen %s failed: %s", HID0, err)
			return err
		}
	}

	deadline := time.Now().Add(20 * time.Millisecond)
	_ = h.g0.SetWriteDeadline(deadline)
	_, err := h.g0.Write(data)

	if err != nil {
		if errors.Is(err, os.ErrDeadlineExceeded) {
			log.Debugf("write to %s timeout (host not polling)", HID0)
			return err
		}
		log.Warnf("write to %s failed (%s), recovering", HID0, err)
		return h.recoverFile(&h.g0, HID0, data, 20*time.Millisecond)
	}

	log.Debugf("write to %s: %v", HID0, data)
	return nil
}

// WriteHid1 writes a relative mouse report. It returns nil once the report was
// accepted by the gadget, or the error if it was not (e.g. host not polling).
func (h *Hid) WriteHid1(data []byte) error {
	h.mouseMutex.Lock()
	defer h.mouseMutex.Unlock()

	var payload []byte
	var buf [5]byte
	if len(data) == 5 {
		copy(buf[:], data)
		payload = buf[:]
	} else if len(data) == 4 {
		copy(buf[:4], data)
		if h.legacyHid1 {
			payload = buf[:4]
		} else {
			payload = buf[:]
		}
	} else {
		payload = data
	}

	if h.legacyHid1 && len(payload) == 5 {
		payload = payload[:4]
	}

	if h.g1 == nil {
		var err error
		h.g1, err = os.OpenFile(HID1, os.O_WRONLY, 0o666)
		if err != nil {
			log.Debugf("reopen %s failed: %s", HID1, err)
			return err
		}
	}

	deadline := time.Now().Add(50 * time.Millisecond)
	_ = h.g1.SetWriteDeadline(deadline)
	_, err := h.g1.Write(payload)

	if err != nil {
		if errors.Is(err, os.ErrDeadlineExceeded) {
			log.Debugf("write to %s timeout (host not polling)", HID1)
			return err
		}
		recPayload := payload
		// If gadget report_length is 4 (pre-reboot/legacy kernel gadget), fall back gracefully
		if errors.Is(err, syscall.EINVAL) && len(payload) == 5 {
			h.legacyHid1 = true
			_ = h.g1.SetWriteDeadline(deadline)
			if _, err4 := h.g1.Write(payload[:4]); err4 == nil {
				log.Debugf("write to %s succeeded using legacy 4-byte fallback", HID1)
				return nil
			}
			recPayload = payload[:4]
		}
		log.Warnf("write to %s failed (%s), recovering", HID1, err)
		return h.recoverFile(&h.g1, HID1, recPayload, 50*time.Millisecond)
	}

	log.Debugf("write to %s: %v", HID1, payload)
	return nil
}

// WriteHid2 writes an absolute mouse report. It returns nil once the report was
// accepted by the gadget, or the error if it was not (e.g. host not polling).
func (h *Hid) WriteHid2(data []byte) error {
	h.mouseMutex.Lock()
	defer h.mouseMutex.Unlock()

	var payload []byte
	var buf [7]byte
	if len(data) == 7 {
		copy(buf[:], data)
		payload = buf[:]
	} else if len(data) == 6 {
		copy(buf[:6], data)
		if h.legacyHid2 {
			payload = buf[:6]
		} else {
			payload = buf[:]
		}
	} else {
		payload = data
	}

	if h.legacyHid2 && len(payload) == 7 {
		payload = payload[:6]
	}

	if h.g2 == nil {
		var err error
		h.g2, err = os.OpenFile(HID2, os.O_WRONLY, 0o666)
		if err != nil {
			// HID2 is optional (touchpad may be disabled via /boot/usb.no_touchpad)
			return err
		}
	}

	deadline := time.Now().Add(50 * time.Millisecond)
	_ = h.g2.SetWriteDeadline(deadline)
	_, err := h.g2.Write(payload)

	if err != nil {
		if errors.Is(err, os.ErrDeadlineExceeded) {
			log.Debugf("write to %s timeout (host not polling)", HID2)
			return err
		}
		recPayload := payload
		// If gadget report_length is 6 (pre-reboot/legacy kernel gadget), fall back gracefully
		if errors.Is(err, syscall.EINVAL) && len(payload) == 7 {
			h.legacyHid2 = true
			_ = h.g2.SetWriteDeadline(deadline)
			if _, err6 := h.g2.Write(payload[:6]); err6 == nil {
				log.Debugf("write to %s succeeded using legacy 6-byte fallback", HID2)
				return nil
			}
			recPayload = payload[:6]
		}
		log.Warnf("write to %s failed (%s), recovering", HID2, err)
		return h.recoverFile(&h.g2, HID2, recPayload, 50*time.Millisecond)
	}

	log.Debugf("write to %s: %v", HID2, payload)
	return nil
}
