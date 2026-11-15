package webrtc

import (
	"NanoKVM-Server/config"
	"net/http"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
	"github.com/pion/dtls/v3"
	"github.com/pion/webrtc/v4"
	log "github.com/sirupsen/logrus"
)

var (
	upgrader = websocket.Upgrader{
		CheckOrigin: func(r *http.Request) bool {
			return true
		},
	}
	globalManager *WebRTCManager
	managerOnce   sync.Once
)

func getManager() *WebRTCManager {
	managerOnce.Do(func() {
		globalManager = NewWebRTCManager()
	})
	return globalManager
}

func Connect(c *gin.Context) {
	// create WebSocket connection
	wsConn, err := upgrader.Upgrade(c.Writer, c.Request, nil)
	if err != nil {
		log.Errorf("failed to create h264 websocket: %s", err)
		return
	}
	defer func() {
		_ = wsConn.Close()
		log.Debugf("h264 websocket disconnected: %s", c.ClientIP())
	}()
	log.Debugf("h264 websocket connected: %s", c.ClientIP())

	var zeroTime time.Time
	_ = wsConn.SetReadDeadline(zeroTime)

	// create video connection
	iceServers := createICEServers()

	mediaEngine, err := createMediaEngine()
	if err != nil {
		log.Errorf("failed to create h264 media engine: %s", err)
		return
	}

	videoConn, err := createPeerConnection(iceServers, mediaEngine)
	if err != nil {
		log.Errorf("failed to create h264 video peer connection: %s", err)
		return
	}
	defer func() {
		_ = videoConn.Close()
		log.Debugf("h264 video peer disconnected: %s", c.ClientIP())
	}()

	// create audio connection
	audioConn, err := createPeerConnection(iceServers, nil)
	if err != nil {
		log.Errorf("failed to create h264 audio peer connection: %s", err)
		return
	}
	defer func() {
		_ = audioConn.Close()
		log.Debugf("h264 audio peer disconnected: %s", c.ClientIP())
	}()

	// create client
	client := NewClient(wsConn, videoConn, audioConn)
	if err := client.AddTrack(); err != nil {
		log.Errorf("failed to add track: %s", err)
		return
	}

	manager := getManager()
	manager.AddClient(wsConn, client)
	defer manager.RemoveClient(wsConn)

	// handle signaling
	signalingHandler := NewSignalingHandler(client)
	signalingHandler.RegisterCallbacks()

	// read and wait
	for {
		message, err := client.ReadMessage()
		if err != nil {
			return
		}
		if message != nil {
			if err := signalingHandler.HandleMessage(message); err != nil {
				log.Errorf("failed to handle signaling message: %s", err)
			}
		}
	}
}

func createICEServers() []webrtc.ICEServer {
	var iceServers []webrtc.ICEServer

	conf := config.GetInstance()

	if conf.Stun != "" && conf.Stun != "disable" {
		iceServers = append(iceServers, webrtc.ICEServer{
			URLs: []string{"stun:" + conf.Stun},
		})
	}

	if conf.Turn.TurnAddr != "" && conf.Turn.TurnUser != "" && conf.Turn.TurnCred != "" {
		iceServers = append(iceServers, webrtc.ICEServer{
			URLs:       []string{"turn:" + conf.Turn.TurnAddr},
			Username:   conf.Turn.TurnUser,
			Credential: conf.Turn.TurnCred,
		})
	}

	return iceServers
}

func createMediaEngine() (*webrtc.MediaEngine, error) {
	mediaEngine := &webrtc.MediaEngine{}

	if err := mediaEngine.RegisterDefaultCodecs(); err != nil {
		log.Errorf("failed to register default codecs: %s", err)
		return nil, err
	}

	if err := mediaEngine.RegisterHeaderExtension(
		webrtc.RTPHeaderExtensionCapability{URI: "http://www.webrtc.org/experiments/rtp-hdrext/playout-delay"},
		webrtc.RTPCodecTypeVideo,
	); err != nil {
		log.Errorf("failed to register header extension: %s", err)
		return nil, err
	}

	return mediaEngine, nil
}

func createPeerConnection(iceServers []webrtc.ICEServer, mediaEngine *webrtc.MediaEngine) (*webrtc.PeerConnection, error) {
	settingEngine := webrtc.SettingEngine{}
	settingEngine.SetSRTPProtectionProfiles(
		dtls.SRTP_AEAD_AES_128_GCM,
		dtls.SRTP_AES128_CM_HMAC_SHA1_80,
	)
	// In DTLS-SRTP the DTLS server picks the profile. As the SDP answerer pion
	// defaults to the DTLS client, so the browser chose AES-CM+HMAC-SHA1, which
	// pion encrypts 16 bytes per call into BoringSSL: 154 us per 1200-byte
	// packet on this A53 against 61 us for AES-GCM. Taking the server role
	// (with pion/dtls >= 3.1, whose server prefers its own list) selects GCM,
	// and clients without it still fall back to AES-CM.
	if err := settingEngine.SetAnsweringDTLSRole(webrtc.DTLSRoleServer); err != nil {
		return nil, err
	}

	apiOptions := []func(api *webrtc.API){
		webrtc.WithSettingEngine(settingEngine),
	}
	if mediaEngine != nil {
		apiOptions = append(apiOptions, webrtc.WithMediaEngine(mediaEngine))
	}

	api := webrtc.NewAPI(apiOptions...)

	return api.NewPeerConnection(webrtc.Configuration{
		ICEServers:   iceServers,
		SDPSemantics: webrtc.SDPSemanticsUnifiedPlan,
	})
}
