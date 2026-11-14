package middleware

import (
	"compress/gzip"
	"io"
	"net/http"
	"strings"
	"sync"

	"github.com/gin-gonic/gin"
)

var gzipPool = sync.Pool{
	New: func() any {
		w, _ := gzip.NewWriterLevel(io.Discard, gzip.BestSpeed)
		return w
	},
}

type gzipWriter struct {
	gin.ResponseWriter
	writer    *gzip.Writer
	wroteHead bool
	compress  bool // decided once, when the header is written
}

func (g *gzipWriter) shouldGzip() bool {
	return g.compress
}

// compressible reports whether a response with this status and these headers
// should be gzipped. Partial content (its Content-Range describes the
// uncompressed bytes), responses that already carry an encoding, and formats
// that are already compressed are passed through unchanged.
func compressible(code int, h http.Header) bool {
	if code == http.StatusNotModified || code == http.StatusNoContent ||
		code == http.StatusPartialContent || (code >= 100 && code < 200) {
		return false
	}
	if h.Get("Content-Encoding") != "" || h.Get("Content-Range") != "" {
		return false
	}
	ct := strings.ToLower(h.Get("Content-Type"))
	if i := strings.IndexByte(ct, ';'); i >= 0 {
		ct = strings.TrimSpace(ct[:i])
	}
	switch {
	case ct == "image/svg+xml":
		return true
	case strings.HasPrefix(ct, "image/"), strings.HasPrefix(ct, "video/"),
		strings.HasPrefix(ct, "audio/"), strings.HasPrefix(ct, "font/woff"):
		return false
	}
	switch ct {
	case "application/zip", "application/gzip", "application/x-gzip",
		"application/x-xz", "application/x-bzip2", "application/zstd",
		"application/octet-stream", "application/wasm", "application/font-woff":
		return false
	}
	return true
}

// addVary appends value to the Vary header unless it is already listed.
func addVary(h http.Header, value string) {
	for _, v := range h.Values("Vary") {
		for _, part := range strings.Split(v, ",") {
			if strings.EqualFold(strings.TrimSpace(part), value) {
				return
			}
		}
	}
	h.Add("Vary", value)
}

func (g *gzipWriter) WriteString(s string) (int, error) {
	return g.Write([]byte(s))
}

func (g *gzipWriter) Flush() {
	// Headers must go out before any gzip bytes do; otherwise the client gets
	// a gzip stream without Content-Encoding.
	g.startBody()
	if g.shouldGzip() {
		_ = g.writer.Flush()
	}
	g.ResponseWriter.Flush()
}

func (g *gzipWriter) WriteHeaderNow() {
	g.startBody()
}

func (g *gzipWriter) Write(data []byte) (int, error) {
	g.startBody()
	if g.shouldGzip() {
		return g.writer.Write(data)
	}
	return g.ResponseWriter.Write(data)
}

// WriteHeader only records the status, like gin's own writer: handlers such
// as c.Data set Content-Type after it, so whether to compress is decided when
// the body starts.
func (g *gzipWriter) WriteHeader(code int) {
	if g.wroteHead {
		return
	}
	g.ResponseWriter.WriteHeader(code)
}

// startBody decides on compression from the final status and headers and
// sends the header, once.
func (g *gzipWriter) startBody() {
	if g.wroteHead {
		return
	}
	g.wroteHead = true

	h := g.Header()
	addVary(h, "Accept-Encoding")
	if compressible(g.Status(), h) {
		g.compress = true
		h.Del("Content-Length")
		h.Set("Content-Encoding", "gzip")
	}
	g.ResponseWriter.WriteHeaderNow()
}

func Gzip() gin.HandlerFunc {
	return func(c *gin.Context) {
		if c.Request.Method == "HEAD" ||
			c.GetHeader("Range") != "" ||
			!strings.Contains(c.GetHeader("Accept-Encoding"), "gzip") ||
			strings.Contains(strings.ToLower(c.GetHeader("Connection")), "upgrade") ||
			strings.EqualFold(c.GetHeader("Upgrade"), "websocket") ||
			strings.HasPrefix(c.Request.URL.Path, "/api/stream") ||
			strings.HasPrefix(c.Request.URL.Path, "/api/ws") ||
			strings.HasPrefix(c.Request.URL.Path, "/api/speed") ||
			strings.HasPrefix(c.Request.URL.Path, "/api/vm/terminal") {
			c.Next()
			return
		}

		gz := gzipPool.Get().(*gzip.Writer)
		gz.Reset(c.Writer)

		gw := &gzipWriter{ResponseWriter: c.Writer, writer: gz}
		c.Writer = gw

		defer func() {
			if gw.wroteHead && gw.shouldGzip() {
				_ = gz.Close()
			}
			gz.Reset(io.Discard)
			gzipPool.Put(gz)
		}()

		c.Next()
	}
}
