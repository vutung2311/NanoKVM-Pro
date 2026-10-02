package middleware

import (
	"bytes"
	"compress/gzip"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

func init() {
	gin.SetMode(gin.TestMode)
}

func setupTestRouter() *gin.Engine {
	r := gin.New()
	r.Use(Gzip())

	r.GET("/test-json", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"message": "hello world from nanokvm gzip middleware"})
	})

	r.GET("/test-string", func(c *gin.Context) {
		c.String(http.StatusOK, "uncompressed test payload")
	})

	r.GET("/test-304", func(c *gin.Context) {
		c.Status(http.StatusNotModified)
	})

	r.GET("/test-204", func(c *gin.Context) {
		c.Status(http.StatusNoContent)
	})

	r.GET("/api/stream/test", func(c *gin.Context) {
		c.String(http.StatusOK, "stream raw frame data")
	})

	r.GET("/api/speed/test", func(c *gin.Context) {
		c.String(http.StatusOK, "speed benchmark data")
	})

	r.GET("/api/ws", func(c *gin.Context) {
		c.String(http.StatusOK, "ws endpoint data")
	})

	r.GET("/api/vm/terminal/test", func(c *gin.Context) {
		c.String(http.StatusOK, "terminal raw bytes")
	})

	r.GET("/test-flush", func(c *gin.Context) {
		c.Writer.WriteHeader(http.StatusOK)
		_, _ = c.Writer.Write([]byte("chunk1"))
		c.Writer.Flush()
		_, _ = c.Writer.Write([]byte("chunk2"))
	})

	return r
}

func TestGzipNormal(t *testing.T) {
	r := setupTestRouter()

	req := httptest.NewRequest("GET", "/test-json", nil)
	req.Header.Set("Accept-Encoding", "gzip, deflate, br")
	w := httptest.NewRecorder()

	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", w.Code)
	}

	encoding := w.Header().Get("Content-Encoding")
	if encoding != "gzip" {
		t.Fatalf("expected Content-Encoding 'gzip', got '%s'", encoding)
	}

	vary := w.Header().Get("Vary")
	if vary != "Accept-Encoding" {
		t.Errorf("expected Vary 'Accept-Encoding', got '%s'", vary)
	}

	// Decompress and verify
	gzReader, err := gzip.NewReader(w.Body)
	if err != nil {
		t.Fatalf("failed to create gzip reader: %v", err)
	}
	defer gzReader.Close()

	decompressed, err := io.ReadAll(gzReader)
	if err != nil {
		t.Fatalf("failed to read decompressed data: %v", err)
	}

	expectedSubstring := "hello world from nanokvm gzip middleware"
	if !bytes.Contains(decompressed, []byte(expectedSubstring)) {
		t.Errorf("expected decompressed content to contain '%s', got '%s'", expectedSubstring, string(decompressed))
	}
}

func TestGzipNoAcceptEncoding(t *testing.T) {
	r := setupTestRouter()

	req := httptest.NewRequest("GET", "/test-string", nil)
	// Do not set Accept-Encoding: gzip
	w := httptest.NewRecorder()

	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", w.Code)
	}

	encoding := w.Header().Get("Content-Encoding")
	if encoding != "" {
		t.Errorf("expected empty Content-Encoding, got '%s'", encoding)
	}

	if w.Body.String() != "uncompressed test payload" {
		t.Errorf("expected 'uncompressed test payload', got '%s'", w.Body.String())
	}
}

func TestGzipExcludedPaths(t *testing.T) {
	r := setupTestRouter()

	excludedPaths := []string{
		"/api/stream/test",
		"/api/speed/test",
		"/api/ws",
		"/api/vm/terminal/test",
	}

	for _, path := range excludedPaths {
		req := httptest.NewRequest("GET", path, nil)
		req.Header.Set("Accept-Encoding", "gzip")
		w := httptest.NewRecorder()

		r.ServeHTTP(w, req)

		if w.Code != http.StatusOK {
			t.Errorf("path %s: expected status 200, got %d", path, w.Code)
		}

		encoding := w.Header().Get("Content-Encoding")
		if encoding != "" {
			t.Errorf("path %s: expected no gzip encoding, got '%s'", path, encoding)
		}
	}
}

func TestGzipStatus304(t *testing.T) {
	r := setupTestRouter()

	req := httptest.NewRequest("GET", "/test-304", nil)
	req.Header.Set("Accept-Encoding", "gzip")
	w := httptest.NewRecorder()

	r.ServeHTTP(w, req)

	if w.Code != http.StatusNotModified {
		t.Fatalf("expected status 304, got %d", w.Code)
	}

	encoding := w.Header().Get("Content-Encoding")
	if encoding != "" {
		t.Errorf("status 304 should not have Content-Encoding, got '%s'", encoding)
	}

	if w.Body.Len() != 0 {
		t.Errorf("status 304 should have empty body, got %d bytes", w.Body.Len())
	}
}

func TestGzipStatus204(t *testing.T) {
	r := setupTestRouter()

	req := httptest.NewRequest("GET", "/test-204", nil)
	req.Header.Set("Accept-Encoding", "gzip")
	w := httptest.NewRecorder()

	r.ServeHTTP(w, req)

	if w.Code != http.StatusNoContent {
		t.Fatalf("expected status 204, got %d", w.Code)
	}

	encoding := w.Header().Get("Content-Encoding")
	if encoding != "" {
		t.Errorf("status 204 should not have Content-Encoding, got '%s'", encoding)
	}
}

func TestGzipFlusher(t *testing.T) {
	r := setupTestRouter()

	req := httptest.NewRequest("GET", "/test-flush", nil)
	req.Header.Set("Accept-Encoding", "gzip")
	w := httptest.NewRecorder()

	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", w.Code)
	}

	gzReader, err := gzip.NewReader(w.Body)
	if err != nil {
		t.Fatalf("failed to create gzip reader: %v", err)
	}
	defer gzReader.Close()

	decompressed, err := io.ReadAll(gzReader)
	if err != nil {
		t.Fatalf("failed to read decompressed data: %v", err)
	}

	if string(decompressed) != "chunk1chunk2" {
		t.Errorf("expected 'chunk1chunk2', got '%s'", string(decompressed))
	}
}
