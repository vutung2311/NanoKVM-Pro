package ws

import (
	"encoding/json"
	"time"

	"NanoKVM-Server/service/hid"
	"NanoKVM-Server/service/vm/jiggler"

	"github.com/gorilla/websocket"
	log "github.com/sirupsen/logrus"
)

const (
	Heartbeat = iota
	KeyboardEvent
	MouseEvent
)

func NewClient(ws *websocket.Conn) *Client {
	client := &Client{
		ws:            ws,
		hid:           hid.GetHid(),
		lastHeartbeat: time.Time{},
	}

	client.hid.Open()

	return client
}

func (c *Client) Start() {
	defer c.Close()

	_ = c.Read()
}

func (c *Client) Read() error {
	var zeroTime time.Time
	_ = c.ws.SetReadDeadline(zeroTime)

	for {
		messageType, data, err := c.ws.ReadMessage()
		if err != nil {
			return err
		}

		log.Debugf("received message %d: %v", messageType, data)
		if len(data) == 0 {
			log.Debug("ignore empty websocket message")
			continue
		}

		switch data[0] {
		case Heartbeat:
			c.UpdateHeartbeat()
		case KeyboardEvent:
			c.hid.SubmitKeyboard(data[1:])
			jiggler.GetJiggler().Update()
		case MouseEvent:
			c.hid.SubmitMouse(data[1:])
			jiggler.GetJiggler().Update()
		}
	}
}

func (c *Client) Write(event string, data string) error {
	message := &Message{
		Type: event,
		Data: data,
	}

	messageByte, err := json.Marshal(message)
	if err != nil {
		log.Errorf("failed to marshal message: %s", err)
		return err
	}

	c.mutex.Lock()
	defer c.mutex.Unlock()

	_ = c.ws.SetWriteDeadline(time.Now().Add(10 * time.Second))
	return c.ws.WriteMessage(websocket.TextMessage, messageByte)
}

func (c *Client) UpdateHeartbeat() {
	c.mutex.Lock()
	defer c.mutex.Unlock()
	c.lastHeartbeat = time.Now()
}

func (c *Client) Close() {
	c.closeOnce.Do(func() {
		_ = c.ws.Close()

		// The browser may have vanished mid-press (network drop, crash): make
		// sure nothing stays held on the host.
		c.hid.ReleaseAll()

		log.Debug("websocket disconnected")
	})
}
