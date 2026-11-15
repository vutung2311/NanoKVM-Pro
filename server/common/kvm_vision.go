//go:build arm64 && cgo

package common

/*
	#cgo CFLAGS: -I../include
	#cgo LDFLAGS: -L../dl_lib -lkvm
	#include <pthread.h>
	#include <signal.h>
	#include "kvm_vision.h"

	// libkvm starts its encoder threads (VencTask-0, H26xProcThread,
	// JencProcThread) from inside these calls, and they wait in the VENC
	// driver's interruptible sleep. A signal landing in that sleep (the Go
	// CPU profiler's SIGPROF reproduces it within seconds; any process-wide
	// signal can do it) leaves the encoder rejecting every frame until the
	// device reboots. Every call runs with signals blocked, so the threads it
	// creates inherit that mask and its own waits are not interrupted.
	// Faults stay unblocked so a crash in the library still reports.
	static void kvmv_block_signals(sigset_t *old)
	{
		sigset_t all;
		sigfillset(&all);
		sigdelset(&all, SIGSEGV);
		sigdelset(&all, SIGBUS);
		sigdelset(&all, SIGFPE);
		sigdelset(&all, SIGILL);
		sigdelset(&all, SIGTRAP);
		pthread_sigmask(SIG_BLOCK, &all, old);
	}

	#define KVMV_NOSIG(call) ({ \
		sigset_t _old; \
		kvmv_block_signals(&_old); \
		__typeof__(call) _r = (call); \
		pthread_sigmask(SIG_SETMASK, &_old, NULL); \
		_r; \
	})

	static void nosig_kvmv_init(uint8_t debug)
	{
		sigset_t old;
		kvmv_block_signals(&old);
		kvmv_init(debug);
		pthread_sigmask(SIG_SETMASK, &old, NULL);
	}

	static void nosig_kvmv_deinit(void)
	{
		sigset_t old;
		kvmv_block_signals(&old);
		kvmv_deinit();
		pthread_sigmask(SIG_SETMASK, &old, NULL);
	}

	static int nosig_kvmv_read_img(uint16_t w, uint16_t h, uint8_t type, uint16_t param,
		uint8_t **data, uint32_t *size)
	{
		return KVMV_NOSIG(kvmv_read_img(w, h, type, param, data, size));
	}
	static int nosig_kvmv_read_audio(uint8_t **data, uint32_t *size)
	{
		return KVMV_NOSIG(kvmv_read_audio(data, size));
	}
	static int nosig_kvmv_set_rate_control(uint8_t mode) { return KVMV_NOSIG(kvmv_set_rate_control(mode)); }
	static int nosig_kvmv_set_fps(uint8_t fps) { return KVMV_NOSIG(kvmv_set_fps(fps)); }
	static int nosig_kvmv_get_fps(void) { return KVMV_NOSIG(kvmv_get_fps()); }
	static int nosig_kvmv_set_gop(uint8_t gop) { return KVMV_NOSIG(kvmv_set_gop(gop)); }
	static int nosig_kvmv_hdmi_control(uint8_t en) { return KVMV_NOSIG(kvmv_hdmi_control(en)); }
*/
import "C"
import (
	"strings"
	"sync"
	"unsafe"

	"NanoKVM-Server/config"

	log "github.com/sirupsen/logrus"
)

var (
	kvmVision     *KvmVision
	kvmVisionOnce sync.Once
)

func GetKvmVision() *KvmVision {
	kvmVisionOnce.Do(func() {
		kvmVision = &KvmVision{
			StreamType: STREAM_TYPE_H264_WEBRTC,
		}

		conf := config.GetInstance()
		logLevel := strings.ToLower(conf.Logger.Level)

		logEnable := C.uint8_t(0)
		if logLevel == "debug" {
			logEnable = C.uint8_t(1)
		}

		C.nosig_kvmv_init(logEnable)
		log.Debugf("kvm vision initialized")
	})

	return kvmVision
}

func (k *KvmVision) SetStreamType(streamType uint8) {
	k.StreamType = streamType
}

func (k *KvmVision) SetRateControl(mode uint8) int {
	if mode != RATE_CONTROL_CBR && mode != RATE_CONTROL_VBR {
		log.Debugf("invalid rate control mode: %d", mode)
		return -1
	}

	result := int(C.nosig_kvmv_set_rate_control(
		C.uint8_t(mode),
	))
	if result < 0 {
		log.Debugf("failed to set rate control mode: %d", result)
		return result
	}

	return result
}

func (k *KvmVision) ReadMjpegInto(width uint16, height uint16, quality uint16, outBuf *[]byte) (data []byte, result int) {
	var (
		kvmData  *C.uint8_t
		dataSize C.uint32_t
	)

	result = int(C.nosig_kvmv_read_img(
		C.uint16_t(width),
		C.uint16_t(height),
		C.uint8_t(IMG_MJPEG_TYPE),
		C.uint16_t(quality),
		&kvmData,
		&dataSize,
	))
	if result < 0 {
		log.Errorf("failed to read MJPEG: %v", result)
		return nil, result
	}
	if kvmData == nil || dataSize == 0 {
		return nil, result
	}

	n := int(dataSize)
	if outBuf != nil {
		if cap(*outBuf) < n {
			*outBuf = make([]byte, n)
		}
		*outBuf = (*outBuf)[:n]
		copy(*outBuf, unsafe.Slice((*byte)(unsafe.Pointer(kvmData)), n))
		return *outBuf, result
	}

	return C.GoBytes(unsafe.Pointer(kvmData), C.int(dataSize)), result
}

func (k *KvmVision) ReadMjpeg(width uint16, height uint16, quality uint16) (data []byte, result int) {
	return k.ReadMjpegInto(width, height, quality, nil)
}

func (k *KvmVision) ReadH264Into(width uint16, height uint16, bitRate uint16, outBuf *[]byte) (data []byte, result int) {
	var (
		kvmData  *C.uint8_t
		dataSize C.uint32_t
	)

	result = int(C.nosig_kvmv_read_img(
		C.uint16_t(width),
		C.uint16_t(height),
		C.uint8_t(IMG_H264_TYPE_SPS),
		C.uint16_t(bitRate),
		&kvmData,
		&dataSize,
	))
	if result < 0 {
		log.Errorf("failed to read H.264: %d", result)
		return nil, result
	}
	if kvmData == nil || dataSize == 0 {
		return nil, result
	}

	n := int(dataSize)
	if outBuf != nil {
		if cap(*outBuf) < n {
			*outBuf = make([]byte, n)
		}
		*outBuf = (*outBuf)[:n]
		copy(*outBuf, unsafe.Slice((*byte)(unsafe.Pointer(kvmData)), n))
		return *outBuf, result
	}

	return C.GoBytes(unsafe.Pointer(kvmData), C.int(dataSize)), result
}

func (k *KvmVision) ReadH264(width uint16, height uint16, bitRate uint16) (data []byte, result int) {
	return k.ReadH264Into(width, height, bitRate, nil)
}

func (k *KvmVision) ReadH265Into(width uint16, height uint16, bitRate uint16, outBuf *[]byte) (data []byte, result int) {
	var (
		kvmData  *C.uint8_t
		dataSize C.uint32_t
	)

	result = int(C.nosig_kvmv_read_img(
		C.uint16_t(width),
		C.uint16_t(height),
		C.uint8_t(IMG_H265_TYPE_SPS),
		C.uint16_t(bitRate),
		&kvmData,
		&dataSize,
	))
	if result < 0 {
		log.Errorf("failed to read H.265: %d", result)
		return nil, result
	}
	if kvmData == nil || dataSize == 0 {
		return nil, result
	}

	n := int(dataSize)
	if outBuf != nil {
		if cap(*outBuf) < n {
			*outBuf = make([]byte, n)
		}
		*outBuf = (*outBuf)[:n]
		copy(*outBuf, unsafe.Slice((*byte)(unsafe.Pointer(kvmData)), n))
		return *outBuf, result
	}

	return C.GoBytes(unsafe.Pointer(kvmData), C.int(dataSize)), result
}

func (k *KvmVision) ReadH265(width uint16, height uint16, bitRate uint16) (data []byte, result int) {
	return k.ReadH265Into(width, height, bitRate, nil)
}

func (k *KvmVision) ReadAudioInto(outBuf *[]byte) (data []byte, result int) {
	var (
		kvmData  *C.uint8_t
		dataSize C.uint32_t
	)

	result = int(C.nosig_kvmv_read_audio(&kvmData, &dataSize))
	if result < 0 {
		log.Errorf("failed to read audio: %d", result)
		return nil, result
	}
	if kvmData == nil || dataSize == 0 {
		return nil, result
	}

	n := int(dataSize)
	if outBuf != nil {
		if cap(*outBuf) < n {
			*outBuf = make([]byte, n)
		}
		*outBuf = (*outBuf)[:n]
		copy(*outBuf, unsafe.Slice((*byte)(unsafe.Pointer(kvmData)), n))
		return *outBuf, result
	}

	return C.GoBytes(unsafe.Pointer(kvmData), C.int(dataSize)), result
}

func (k *KvmVision) ReadAudio() (data []byte, result int) {
	return k.ReadAudioInto(nil)
}

func (k *KvmVision) SetFps(fps uint8) int {
	_fps := C.uint8_t(fps)
	result := C.nosig_kvmv_set_fps(_fps)
	return int(result)
}

func (k *KvmVision) GetFps() int {
	return int(C.nosig_kvmv_get_fps())
}

func (k *KvmVision) SetHDMI(enable bool) int {
	hdmiEnable := C.uint8_t(0)
	if enable {
		hdmiEnable = C.uint8_t(1)
	}

	result := int(C.nosig_kvmv_hdmi_control(hdmiEnable))
	if result < 0 {
		log.Errorf("failed to set hdmi to %t", enable)
		return result
	}

	return result
}

func (k *KvmVision) SetGop(gop uint8) int {
	_gop := C.uint8_t(gop)
	result := C.nosig_kvmv_set_gop(_gop)
	return int(result)
}

func (k *KvmVision) Close() {
	C.nosig_kvmv_deinit()
	log.Debugf("stop kvm vision...")
}

// readFrameTo reads one encoded frame and copies it straight into the buffer
// alloc returns (sized n), so the caller's outgoing message is filled with a
// single copy. alloc is not called when there is no frame. It returns the
// frame size and the library's result code.
func (k *KvmVision) readFrameTo(width, height uint16, imgType uint8, param uint16, alloc func(n int) []byte) (n int, result int) {
	var (
		kvmData  *C.uint8_t
		dataSize C.uint32_t
	)

	result = int(C.nosig_kvmv_read_img(
		C.uint16_t(width),
		C.uint16_t(height),
		C.uint8_t(imgType),
		C.uint16_t(param),
		&kvmData,
		&dataSize,
	))
	if result < 0 {
		log.Errorf("failed to read frame (type %d): %d", imgType, result)
		return 0, result
	}
	if kvmData == nil || dataSize == 0 {
		return 0, result
	}

	n = int(dataSize)
	dst := alloc(n)
	copy(dst[:n], unsafe.Slice((*byte)(unsafe.Pointer(kvmData)), n))
	return n, result
}

// ReadMjpegTo is ReadMjpegInto with a single copy into alloc's buffer.
func (k *KvmVision) ReadMjpegTo(width, height, quality uint16, alloc func(n int) []byte) (int, int) {
	return k.readFrameTo(width, height, IMG_MJPEG_TYPE, quality, alloc)
}

// ReadH264To is ReadH264Into with a single copy into alloc's buffer.
func (k *KvmVision) ReadH264To(width, height, bitRate uint16, alloc func(n int) []byte) (int, int) {
	return k.readFrameTo(width, height, IMG_H264_TYPE_SPS, bitRate, alloc)
}

// ReadH265To is ReadH265Into with a single copy into alloc's buffer.
func (k *KvmVision) ReadH265To(width, height, bitRate uint16, alloc func(n int) []byte) (int, int) {
	return k.readFrameTo(width, height, IMG_H265_TYPE_SPS, bitRate, alloc)
}
