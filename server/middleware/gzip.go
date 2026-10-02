package middleware

import (
	"compress/gzip"
	"io"
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
}

func (g *gzipWriter) shouldGzip() bool {
	status := g.Status()
	return status != 304 && status != 204 && (status < 100 || status >= 200)
}

func (g *gzipWriter) WriteString(s string) (int, error) {
	return g.Write([]byte(s))
}

func (g *gzipWriter) Flush() {
	if g.shouldGzip() {
		_ = g.writer.Flush()
	}
	g.ResponseWriter.Flush()
}

func (g *gzipWriter) WriteHeaderNow() {
	if !g.wroteHead {
		g.WriteHeader(g.Status())
	}
	g.ResponseWriter.WriteHeaderNow()
}

func (g *gzipWriter) Write(data []byte) (int, error) {
	if !g.wroteHead {
		g.WriteHeader(g.Status())
	}
	if g.shouldGzip() {
		return g.writer.Write(data)
	}
	return g.ResponseWriter.Write(data)
}

func (g *gzipWriter) WriteHeader(code int) {
	if g.wroteHead {
		return
	}
	g.wroteHead = true

	if code == 304 || code == 204 || (code >= 100 && code < 200) {
		g.ResponseWriter.WriteHeader(code)
		return
	}

	g.Header().Del("Content-Length")
	g.Header().Set("Content-Encoding", "gzip")
	g.Header().Set("Vary", "Accept-Encoding")
	g.ResponseWriter.WriteHeader(code)
}

func Gzip() gin.HandlerFunc {
	return func(c *gin.Context) {
		if c.Request.Method == "HEAD" ||
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
