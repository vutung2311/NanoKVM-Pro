//go:build !arm64 || !cgo

package common

import (
	"runtime"
	"sync"

	log "github.com/sirupsen/logrus"
)

var (
	kvmVision     *KvmVision
	kvmVisionOnce sync.Once
)

func GetKvmVision() *KvmVision {
	kvmVisionOnce.Do(func() {
		if runtime.GOARCH == "arm64" {
			// On the device this means the binary was built with
			// CGO_ENABLED=0: it runs, but every video read fails.
			log.Error("built without cgo: video capture is disabled (rebuild with CGO_ENABLED=1)")
		}
		kvmVision = &KvmVision{
			StreamType: STREAM_TYPE_H264_WEBRTC,
		}
	})

	return kvmVision
}

func (k *KvmVision) SetStreamType(streamType uint8) {
	k.StreamType = streamType
}

func (k *KvmVision) SetRateControl(mode uint8) int {
	return 0
}

func (k *KvmVision) ReadMjpegInto(width uint16, height uint16, quality uint16, outBuf *[]byte) (data []byte, result int) {
	return nil, -1
}

func (k *KvmVision) ReadMjpeg(width uint16, height uint16, quality uint16) (data []byte, result int) {
	return nil, -1
}

func (k *KvmVision) ReadH264Into(width uint16, height uint16, bitRate uint16, outBuf *[]byte) (data []byte, result int) {
	return nil, -1
}

func (k *KvmVision) ReadH264(width uint16, height uint16, bitRate uint16) (data []byte, result int) {
	return nil, -1
}

func (k *KvmVision) ReadH265Into(width uint16, height uint16, bitRate uint16, outBuf *[]byte) (data []byte, result int) {
	return nil, -1
}

func (k *KvmVision) ReadH265(width uint16, height uint16, bitRate uint16) (data []byte, result int) {
	return nil, -1
}

func (k *KvmVision) ReadAudioInto(outBuf *[]byte) (data []byte, result int) {
	return nil, -1
}

func (k *KvmVision) ReadAudio() (data []byte, result int) {
	return nil, -1
}

func (k *KvmVision) SetFps(fps uint8) int {
	return 0
}

func (k *KvmVision) GetFps() int {
	return 0
}

func (k *KvmVision) SetHDMI(enable bool) int {
	return 0
}

func (k *KvmVision) SetGop(gop uint8) int {
	return 0
}

func (k *KvmVision) Close() {
}

func (k *KvmVision) ReadMjpegTo(width, height, quality uint16, alloc func(n int) []byte) (int, int) {
	return 0, -1
}

func (k *KvmVision) ReadH264To(width, height, bitRate uint16, alloc func(n int) []byte) (int, int) {
	return 0, -1
}

func (k *KvmVision) ReadH265To(width, height, bitRate uint16, alloc func(n int) []byte) (int, int) {
	return 0, -1
}
