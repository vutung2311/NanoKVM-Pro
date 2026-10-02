//go:build !arm64 || !cgo

package common

import (
	"sync"
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
	})

	return kvmVision
}

func (k *KvmVision) SetStreamType(streamType uint8) {
	k.StreamType = streamType
}

func (k *KvmVision) SetRateControl(mode uint8) int {
	return 0
}

func (k *KvmVision) ReadMjpeg(width uint16, height uint16, quality uint16) (data []byte, result int) {
	return nil, -1
}

func (k *KvmVision) ReadH264(width uint16, height uint16, bitRate uint16) (data []byte, result int) {
	return nil, -1
}

func (k *KvmVision) ReadH265(width uint16, height uint16, bitRate uint16) (data []byte, result int) {
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
