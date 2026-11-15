package webrtc

import (
	"testing"
	"time"

	"github.com/pion/dtls/v3"
	"github.com/pion/webrtc/v4"
)

// A browser-like offerer (listing AES-CM first) must connect to the
// server's answerer, which takes the DTLS server role.
func TestAnswererDTLSServerConnects(t *testing.T) {
	me, err := createMediaEngine()
	if err != nil {
		t.Fatal(err)
	}
	answerer, err := createPeerConnection(nil, me)
	if err != nil {
		t.Fatal(err)
	}
	defer answerer.Close()

	se := webrtc.SettingEngine{}
	se.SetSRTPProtectionProfiles(dtls.SRTP_AES128_CM_HMAC_SHA1_80, dtls.SRTP_AEAD_AES_128_GCM)
	ome, err := createMediaEngine() // same codecs as the server
	if err != nil {
		t.Fatal(err)
	}
	offerer, err := webrtc.NewAPI(webrtc.WithSettingEngine(se), webrtc.WithMediaEngine(ome)).NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	defer offerer.Close()
	if _, err := offerer.AddTransceiverFromKind(webrtc.RTPCodecTypeVideo,
		webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionRecvonly}); err != nil {
		t.Fatal(err)
	}

	track, err := webrtc.NewTrackLocalStaticRTP(webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeH265, ClockRate: 90000}, "video", "kvm")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := answerer.AddTrack(track); err != nil {
		t.Fatal(err)
	}

	connected := make(chan struct{})
	answerer.OnConnectionStateChange(func(s webrtc.PeerConnectionState) {
		t.Logf("answerer state: %s", s)
		if s == webrtc.PeerConnectionStateConnected {
			close(connected)
		}
	})

	offer, err := offerer.CreateOffer(nil)
	if err != nil {
		t.Fatal(err)
	}
	gatherO := webrtc.GatheringCompletePromise(offerer)
	if err := offerer.SetLocalDescription(offer); err != nil {
		t.Fatal(err)
	}
	<-gatherO
	if err := answerer.SetRemoteDescription(*offerer.LocalDescription()); err != nil {
		t.Fatal(err)
	}
	answer, err := answerer.CreateAnswer(nil)
	if err != nil {
		t.Fatal(err)
	}
	gatherA := webrtc.GatheringCompletePromise(answerer)
	if err := answerer.SetLocalDescription(answer); err != nil {
		t.Fatal(err)
	}
	<-gatherA
	if err := offerer.SetRemoteDescription(*answerer.LocalDescription()); err != nil {
		t.Fatal(err)
	}

	select {
	case <-connected:
	case <-time.After(15 * time.Second):
		t.Fatalf("not connected after 15 s (DTLS role %v)", answerer.SCTP().Transport().State())
	}
}
