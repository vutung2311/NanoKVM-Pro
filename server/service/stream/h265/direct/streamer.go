package direct

import (
	"NanoKVM-Server/common"
	"NanoKVM-Server/service/stream"
	"NanoKVM-Server/service/stream/fanout"
	"encoding/binary"
	"sync/atomic"
	"time"

	log "github.com/sirupsen/logrus"
)

type Streamer struct {
	hub     *fanout.Hub
	running int32
}

func newStreamer() *Streamer {
	return &Streamer{hub: fanout.NewHub(true)}
}

// addClient registers a viewer and starts the capture loop if needed. The
// caller must drain the returned client (see writeLoop) and removeClient it.
func (s *Streamer) addClient() *fanout.Client {
	c, _ := s.hub.Add()

	common.GetKvmVision().SetStreamType(common.STREAM_TYPE_H265_DIRECT)

	if atomic.CompareAndSwapInt32(&s.running, 0, 1) {
		go s.run()
		log.Debug("h265 stream started")
	}
	return c
}

func (s *Streamer) removeClient(c *fanout.Client) {
	count := s.hub.Remove(c)
	log.Debugf("h265 websocket disconnected, remaining clients: %d", count)
}

func (s *Streamer) run() {
	defer func() {
		atomic.StoreInt32(&s.running, 0)
		// A client that joined while this loop was exiting found it still
		// marked running and did not start a new one.
		if s.hub.Len() > 0 && atomic.CompareAndSwapInt32(&s.running, 0, 1) {
			go s.run()
		}
	}()

	ticker := stream.NewPollTicker()
	defer ticker.Stop()

	screen := common.GetScreen()
	vision := common.GetKvmVision()
	startTime := time.Now()

	for range ticker.C() {
		ticker.Refresh()
		if s.hub.Len() == 0 {
			log.Debug("h265 stream stopped due to no clients")
			return
		}

		if vision.StreamType != common.STREAM_TYPE_H265_DIRECT {
			continue
		}

		screen.Check()
		bufPtr := stream.FrameBufferPool.Get().(*[]byte)
		data, result := vision.ReadH265Into(screen.Width, screen.Height, screen.BitRate, bufPtr)
		if result < 0 || len(data) == 0 {
			stream.PutFrameBuffer(bufPtr)
			continue
		}

		isKeyFrame := byte(0)
		if result == 7 {
			isKeyFrame = byte(1)
		}

		timestamp := time.Since(startTime).Microseconds()

		s.hub.Broadcast(packFrame(isKeyFrame == 1, timestamp, data))
		stream.PutFrameBuffer(bufPtr)

		stream.GetFrameRateCounter().Update()
	}
}

// packFrame builds the wire message: 1 byte keyframe flag, 8 bytes
// little-endian timestamp (µs), then the encoded frame.
func packFrame(key bool, timestamp int64, data []byte) *fanout.Msg {
	m := fanout.NewMsg(9+len(data), key)
	if key {
		m.Data[0] = 1
	} else {
		m.Data[0] = 0
	}
	binary.LittleEndian.PutUint64(m.Data[1:9], uint64(timestamp))
	copy(m.Data[9:], data)
	return m
}
