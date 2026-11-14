package mjpeg

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
)

func init() {
	gin.SetMode(gin.TestMode)
}

// lockedRecorder lets the test read the body while serve writes it.
type lockedRecorder struct {
	*httptest.ResponseRecorder
	mu sync.Mutex
}

func (r *lockedRecorder) Write(b []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.ResponseRecorder.Write(b)
}

func (r *lockedRecorder) contains(sub []byte) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return bytes.Contains(r.Body.Bytes(), sub)
}

func TestStreamer_ClientLifecycle(t *testing.T) {
	s := NewStreamer()

	c := s.AddClient()
	if count := s.getClientCount(); count != 1 {
		t.Fatalf("expected 1 client after AddClient, got %d", count)
	}

	s.RemoveClient(c)
	if count := s.getClientCount(); count != 0 {
		t.Fatalf("expected 0 clients after RemoveClient, got %d", count)
	}
}

func TestPackFrame(t *testing.T) {
	m := packFrame([]byte{0xFF, 0xD8, 0xFF})
	defer m.Release()
	want := "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: 3\r\n\r\n\xff\xd8\xff\r\n"
	if string(m.Data) != want {
		t.Fatalf("packFrame = %q, want %q", m.Data, want)
	}
}

// The handler goroutine writes broadcast frames and stops when the request
// ends, so nothing writes to the context after the handler returns.
func TestServeWritesUntilRequestEnds(t *testing.T) {
	s := NewStreamer()
	client := s.AddClient()
	defer s.RemoveClient(client)

	w := &lockedRecorder{ResponseRecorder: httptest.NewRecorder()}
	c, _ := gin.CreateTestContext(w)
	ctx, cancel := context.WithCancel(context.Background())
	c.Request, _ = http.NewRequestWithContext(ctx, http.MethodGet, "/stream/mjpeg", nil)

	served := make(chan struct{})
	go func() {
		serve(c, client)
		close(served)
	}()

	s.hub.Broadcast(packFrame([]byte("jpeg")))
	deadline := time.Now().Add(2 * time.Second)
	for !w.contains([]byte("jpeg")) {
		if time.Now().After(deadline) {
			t.Fatal("frame was not written")
		}
		time.Sleep(5 * time.Millisecond)
	}

	cancel()
	select {
	case <-served:
	case <-time.After(2 * time.Second):
		t.Fatal("serve did not return after the request ended")
	}
}
