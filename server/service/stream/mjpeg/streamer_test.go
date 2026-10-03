package mjpeg

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

func init() {
	gin.SetMode(gin.TestMode)
}

func TestStreamer_ClientLifecycle(t *testing.T) {
	s := NewStreamer()

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request, _ = http.NewRequest(http.MethodGet, "/stream/mjpeg", nil)

	s.AddClient(c)
	if count := s.getClientCount(); count != 1 {
		t.Fatalf("expected 1 client after AddClient, got %d", count)
	}

	s.RemoveClient(c)
	if count := s.getClientCount(); count != 0 {
		t.Fatalf("expected 0 clients after RemoveClient, got %d", count)
	}

	// send with nil clients slice must not panic
	s.send(nil, []byte{0xFF, 0xD8, 0xFF})
}

func TestWriteClientFrame(t *testing.T) {
	data := []byte("--frame\r\ntest\r\n")

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request, _ = http.NewRequest(http.MethodGet, "/stream/mjpeg", nil)

	if err := writeClientFrame(c, data); err != nil {
		t.Fatalf("unexpected error for valid context: %v", err)
	}
	if w.Body.String() != string(data) {
		t.Fatalf("expected written body %q, got %q", string(data), w.Body.String())
	}
}

func BenchmarkMjpegStreamer_Send(b *testing.B) {
	s := NewStreamer()
	frameData := make([]byte, 64*1024) // 64KB mock JPEG frame

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request, _ = http.NewRequest(http.MethodGet, "/stream/mjpeg", nil)

	clients := []*gin.Context{c}

	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		w.Body.Reset()
		s.send(clients, frameData)
	}
}

func BenchmarkMjpegStreamer_GetClients(b *testing.B) {
	s := NewStreamer()
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	s.AddClient(c)

	b.ResetTimer()
	b.ReportAllocs()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			_ = s.getClients()
		}
	})
}
