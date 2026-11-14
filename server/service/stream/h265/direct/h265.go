package direct

import (
	"NanoKVM-Server/service/stream/fanout"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
	log "github.com/sirupsen/logrus"
)

var (
	streamer = newStreamer()
	upgrader = websocket.Upgrader{
		CheckOrigin: func(r *http.Request) bool {
			return true
		},
	}
)

func Connect(c *gin.Context) {
	ws, err := upgrader.Upgrade(c.Writer, c.Request, nil)
	if err != nil {
		log.Errorf("failed to upgrade to websocket: %s", err)
		return
	}
	defer func() {
		_ = ws.Close()
		log.Debugf("h265 websocket disconnected: %s", ws.RemoteAddr())
	}()
	log.Debugf("h265 websocket connected: %s", ws.RemoteAddr())

	_ = ws.SetReadDeadline(time.Time{})

	client := streamer.addClient()
	defer streamer.removeClient(client)
	go fanout.ServeWebsocket(ws, client)

	for {
		if _, _, err := ws.ReadMessage(); err != nil {
			log.Debugf("failed to read message (client disconnected): %s", err)
			return
		}
	}
}
