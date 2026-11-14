package mjpeg

import (
	"fmt"
	"net/http"
	"strconv"
	"sync/atomic"
	"time"

	"NanoKVM-Server/common"
	"NanoKVM-Server/service/stream"
	"NanoKVM-Server/service/stream/fanout"

	"github.com/gin-gonic/gin"
	log "github.com/sirupsen/logrus"
)

// writeTimeout bounds one frame write. MJPEG frames are independent, so a
// slow client simply gets fewer (always the newest) frames.
const writeTimeout = 5 * time.Second

type Streamer struct {
	hub     *fanout.Hub
	running int32
}

func NewStreamer() *Streamer {
	return &Streamer{hub: fanout.NewHub(false)}
}

// AddClient registers a viewer and starts the capture loop if needed.
func (s *Streamer) AddClient() *fanout.Client {
	c, _ := s.hub.Add()

	common.GetKvmVision().SetStreamType(common.STREAM_TYPE_MJPEG)

	if atomic.CompareAndSwapInt32(&s.running, 0, 1) {
		go s.run()
		log.Debug("mjpeg stream started")
	}
	return c
}

func (s *Streamer) RemoveClient(c *fanout.Client) {
	count := s.hub.Remove(c)
	log.Debugf("mjpeg connection removed, remaining clients: %d", count)
}

func (s *Streamer) getClientCount() int {
	return s.hub.Len()
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

	vision := common.GetKvmVision()
	screen := common.GetScreen()

	ticker := stream.NewPollTicker()
	defer ticker.Stop()

	for range ticker.C() {
		ticker.Refresh()
		if s.getClientCount() == 0 {
			log.Debug("mjpeg stream stopped due to no clients")
			return
		}

		if vision.StreamType != common.STREAM_TYPE_MJPEG {
			continue
		}

		screen.Check()
		bufPtr := stream.FrameBufferPool.Get().(*[]byte)
		data, result := vision.ReadMjpegInto(screen.Width, screen.Height, screen.Quality, bufPtr)
		if result < 0 || len(data) == 0 {
			stream.PutFrameBuffer(bufPtr)
			continue
		}

		s.hub.Broadcast(packFrame(data))
		stream.PutFrameBuffer(bufPtr)

		stream.GetFrameRateCounter().Update()
	}
}

// packFrame wraps a JPEG in one multipart/x-mixed-replace part.
func packFrame(data []byte) *fanout.Msg {
	header := "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: " + strconv.Itoa(len(data)) + "\r\n\r\n"
	m := fanout.NewMsg(len(header)+len(data)+2, true)
	n := copy(m.Data, header)
	n += copy(m.Data[n:], data)
	copy(m.Data[n:], "\r\n")
	return m
}

// serve writes the client's frames from the request handler's own goroutine
// until the request ends or a write fails. Writing only here means nothing
// touches the gin.Context after the handler has returned (gin reuses it).
func serve(c *gin.Context, client *fanout.Client) {
	defer client.Drain()
	done := c.Request.Context().Done()
	rc := http.NewResponseController(c.Writer)
	for {
		select {
		case <-done:
			return
		case <-client.Done():
			return
		case m := <-client.C():
			err := writeClientFrame(c, rc, m.Data)
			m.Release()
			if err != nil {
				log.Debugf("failed to write mjpeg frame to %s: %s", c.Request.RemoteAddr, err)
				return
			}
		}
	}
}

func writeClientFrame(c *gin.Context, rc *http.ResponseController, frame []byte) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("panic writing mjpeg frame: %v", r)
		}
	}()
	_ = rc.SetWriteDeadline(time.Now().Add(writeTimeout))
	if _, err = c.Writer.Write(frame); err != nil {
		return err
	}
	return rc.Flush()
}
