package router

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"NanoKVM-Server/middleware"

	"github.com/gin-gonic/contrib/static"
	"github.com/gin-gonic/gin"
	log "github.com/sirupsen/logrus"
)

func Init(r *gin.Engine) {
	r.Use(middleware.Gzip())
	web(r)
	server(r)
	log.Debugf("router init done")
}

func web(r *gin.Engine) {
	execPath, err := os.Executable()
	if err != nil {
		panic("invalid executable path")
	}

	execDir := filepath.Dir(execPath)
	webPath := fmt.Sprintf("%s/web", execDir)

	r.Use(func(c *gin.Context) {
		path := c.Request.URL.Path
		if strings.HasPrefix(path, "/assets/") {
			c.Header("Cache-Control", "public, max-age=31536000, immutable")
		} else if path == "/" || path == "/index.html" {
			c.Header("Cache-Control", "no-cache, no-store, must-revalidate")
		}
		c.Next()
	})

	r.Use(static.Serve("/", static.LocalFile(webPath, true)))

	r.GET("/kvm", func(c *gin.Context) {
		c.Redirect(302, "/")
	})
}

func server(r *gin.Engine) {
	routers := []func(c *gin.Engine){
		authRouter,
		applicationRouter,
		vmRouter,
		streamRouter,
		storageRouter,
		networkRouter,
		hidRouter,
		wsRouter,
		localRouter,
		extensionsRouter,
		speedtestRouter,
	}

	for _, fn := range routers {
		fn(r)
	}
}
