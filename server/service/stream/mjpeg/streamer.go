package mjpeg

import (
	"bytes"
	"fmt"
	"net/http"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"NanoKVM-Server/common"
	"NanoKVM-Server/service/stream"

	"github.com/gin-gonic/gin"
	log "github.com/sirupsen/logrus"
)

type Streamer struct {
	mutex          sync.Mutex
	clients        map[*gin.Context]bool
	clientSnapshot atomic.Pointer[[]*gin.Context]
	running        int32
}

func NewStreamer() *Streamer {
	s := &Streamer{
		clients: make(map[*gin.Context]bool),
	}
	s.updateClientSnapshotLocked()
	return s
}

func (s *Streamer) AddClient(c *gin.Context) {
	s.mutex.Lock()
	s.clients[c] = true
	s.updateClientSnapshotLocked()
	s.mutex.Unlock()

	common.GetKvmVision().SetStreamType(common.STREAM_TYPE_MJPEG)

	if atomic.CompareAndSwapInt32(&s.running, 0, 1) {
		go s.run()
		log.Debug("mjpeg stream started")
	}
}

func (s *Streamer) RemoveClient(c *gin.Context) {
	s.mutex.Lock()
	delete(s.clients, c)
	count := s.updateClientSnapshotLocked()
	s.mutex.Unlock()

	log.Debugf("mjpeg connection removed, remaining clients: %d", count)
}

func (s *Streamer) updateClientSnapshotLocked() int {
	clients := make([]*gin.Context, 0, len(s.clients))
	for client := range s.clients {
		clients = append(clients, client)
	}
	s.clientSnapshot.Store(&clients)
	return len(clients)
}

func (s *Streamer) getClients() []*gin.Context {
	clients := s.clientSnapshot.Load()
	if clients == nil {
		return nil
	}
	return *clients
}

func (s *Streamer) getClientCount() int {
	return len(s.getClients())
}

func (s *Streamer) run() {
	defer atomic.StoreInt32(&s.running, 0)

	vision := common.GetKvmVision()
	screen := common.GetScreen()

	duration := stream.GetStreamTickerDuration()
	ticker := time.NewTicker(duration)
	defer ticker.Stop()

	for range ticker.C {
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

		clients := s.getClients()
		s.send(clients, data)
		stream.PutFrameBuffer(bufPtr)

		stream.GetFrameRateCounter().Update()
	}
}

func (s *Streamer) send(clients []*gin.Context, data []byte) {
	if len(clients) == 0 {
		return
	}

	buf := stream.BufferPool.Get().(*bytes.Buffer)
	defer stream.BufferPool.Put(buf)
	buf.Reset()

	buf.WriteString("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ")
	buf.WriteString(strconv.Itoa(len(data)))
	buf.WriteString("\r\n\r\n")
	buf.Write(data)
	buf.WriteString("\r\n")

	frameBytes := buf.Bytes()
	for _, client := range clients {
		if err := writeClientFrame(client, frameBytes); err != nil {
			addr := "unknown"
			if client.Request != nil {
				addr = client.Request.RemoteAddr
			}
			log.Errorf("failed to write mjpeg frame for client %s: %s", addr, err)
			s.RemoveClient(client)
		}
	}
}

func writeClientFrame(c *gin.Context, frameBytes []byte) (err error) {
	defer func() {
		if r := recover(); r != nil {
			if c.Request != nil && c.Request.Context() != nil {
				err = c.Request.Context().Err()
			}
			if err == nil {
				err = fmt.Errorf("panic recovered in writeClientFrame: %v", r)
			}
		}
	}()

	rc := http.NewResponseController(c.Writer)
	_ = rc.SetWriteDeadline(time.Now().Add(500 * time.Millisecond))

	if _, err = c.Writer.Write(frameBytes); err != nil {
		return err
	}

	c.Writer.Flush()
	return nil
}
