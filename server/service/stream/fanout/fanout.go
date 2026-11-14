// Package fanout delivers encoded video frames to many clients without letting
// a slow client delay the capture loop or the other clients.
//
// The capture loop builds one immutable, reference-counted Msg per frame and
// hands it to Hub.Broadcast, which never blocks. Each client drains its own
// bounded mailbox from its own goroutine (or its HTTP handler).
//
// When a client's mailbox is full:
//   - Dependent streams (H.264/H.265) drop frames until the next keyframe, so
//     the decoder resyncs instead of seeing a corrupt reference chain.
//   - Independent streams (MJPEG) keep only the newest frame.
package fanout

import (
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	log "github.com/sirupsen/logrus"
)

// Mailbox depth per client. A few frames absorb normal network jitter; more
// would only add latency for a client that is genuinely too slow.
const (
	DependentQueue   = 8
	IndependentQueue = 1
)

var msgPool = sync.Pool{
	New: func() any { return new(Msg) },
}

// Msg is one frame, shared read-only by every client it was sent to.
type Msg struct {
	Data []byte
	Key  bool
	refs atomic.Int32
}

// NewMsg returns a message whose Data has length n. The caller fills Data
// and then passes the message to Broadcast, which takes over the caller's
// reference.
func NewMsg(n int, key bool) *Msg {
	m := msgPool.Get().(*Msg)
	if cap(m.Data) < n {
		m.Data = make([]byte, n)
	}
	m.Data = m.Data[:n]
	m.Key = key
	m.refs.Store(1)
	return m
}

func (m *Msg) retain() { m.refs.Add(1) }

// Release drops one reference; the last one returns the message to the pool.
func (m *Msg) Release() {
	if m.refs.Add(-1) == 0 {
		// Do not keep unusually large frames (e.g. 4K I-frames) pooled forever.
		if cap(m.Data) > 4<<20 {
			m.Data = nil
		}
		msgPool.Put(m)
	}
}

// Client is one viewer's mailbox.
type Client struct {
	ch        chan *Msg
	dependent bool
	needKey   bool // producer-only: dropping until the next keyframe
	done      chan struct{}
	closeOnce sync.Once
}

// C returns the channel the client's writer drains. Every received message
// must be Released after it is written (or skipped).
func (c *Client) C() <-chan *Msg { return c.ch }

// Done is closed once the client has been removed from its hub.
func (c *Client) Done() <-chan struct{} { return c.done }

// Drain releases anything still queued. Call it after the writer has stopped.
func (c *Client) Drain() {
	for {
		select {
		case m := <-c.ch:
			m.Release()
		default:
			return
		}
	}
}

func (c *Client) offer(m *Msg) {
	if c.dependent {
		if c.needKey {
			if !m.Key {
				return
			}
		}
		m.retain()
		select {
		case c.ch <- m:
			c.needKey = false
		default:
			m.Release()
			c.needKey = true
		}
		return
	}

	// Independent frames: replace whatever is queued with the newest frame.
	m.retain()
	for {
		select {
		case c.ch <- m:
			return
		default:
		}
		select {
		case old := <-c.ch:
			old.Release()
		default:
		}
	}
}

// Hub is the set of clients of one stream.
type Hub struct {
	mu        sync.Mutex
	clients   map[*Client]struct{}
	snapshot  atomic.Pointer[[]*Client]
	dependent bool
}

// NewHub creates a hub. dependent is true for streams whose frames reference
// earlier frames (H.264/H.265).
func NewHub(dependent bool) *Hub {
	h := &Hub{clients: make(map[*Client]struct{}), dependent: dependent}
	h.storeSnapshotLocked()
	return h
}

// Add registers a new client. A dependent-stream client starts by waiting for
// a keyframe, since it cannot decode anything before one.
func (h *Hub) Add() (*Client, int) {
	size := IndependentQueue
	if h.dependent {
		size = DependentQueue
	}
	c := &Client{
		ch:        make(chan *Msg, size),
		dependent: h.dependent,
		needKey:   h.dependent,
		done:      make(chan struct{}),
	}
	h.mu.Lock()
	h.clients[c] = struct{}{}
	n := h.storeSnapshotLocked()
	h.mu.Unlock()
	return c, n
}

// Remove unregisters c and closes its Done channel. It is safe to call more
// than once. It returns the remaining client count.
func (h *Hub) Remove(c *Client) int {
	h.mu.Lock()
	delete(h.clients, c)
	n := h.storeSnapshotLocked()
	h.mu.Unlock()
	c.closeOnce.Do(func() { close(c.done) })
	return n
}

// Len returns the current number of clients.
func (h *Hub) Len() int {
	p := h.snapshot.Load()
	if p == nil {
		return 0
	}
	return len(*p)
}

// Broadcast offers m to every client and releases the caller's reference.
// It never blocks.
func (h *Hub) Broadcast(m *Msg) {
	if p := h.snapshot.Load(); p != nil {
		for _, c := range *p {
			c.offer(m)
		}
	}
	m.Release()
}

func (h *Hub) storeSnapshotLocked() int {
	s := make([]*Client, 0, len(h.clients))
	for c := range h.clients {
		s = append(s, c)
	}
	h.snapshot.Store(&s)
	return len(s)
}

// WebsocketWriteTimeout bounds one frame write. A client stuck longer than
// this on a single write is disconnected; shorter stalls only cost it frames.
const WebsocketWriteTimeout = 5 * time.Second

// ServeWebsocket writes c's frames to ws as binary messages until c is
// removed or a write fails, in which case ws is closed so the handler's read
// loop returns. It drains c before returning. gorilla/websocket allows one
// concurrent writer, so nothing else may write to ws meanwhile.
func ServeWebsocket(ws *websocket.Conn, c *Client) {
	defer c.Drain()
	for {
		select {
		case <-c.Done():
			return
		case m := <-c.C():
			_ = ws.SetWriteDeadline(time.Now().Add(WebsocketWriteTimeout))
			err := ws.WriteMessage(websocket.BinaryMessage, m.Data)
			m.Release()
			if err != nil {
				log.Debugf("stream write to %s failed: %s", ws.RemoteAddr(), err)
				_ = ws.Close()
				return
			}
		}
	}
}
