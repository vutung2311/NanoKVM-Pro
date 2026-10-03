package direct

import (
	"testing"
)

func TestDirectStreamer_SendNilClients(t *testing.T) {
	s := newStreamer()

	// send with nil clients slice must not panic
	err := s.send(nil, 1, 1000, []byte{0x00, 0x00, 0x00, 0x01})
	if err != nil {
		t.Fatalf("expected no error sending to nil clients, got %v", err)
	}
}

func BenchmarkDirectStreamer_SendPackaging(b *testing.B) {
	s := newStreamer()
	frameData := make([]byte, 64*1024) // 64KB mock H.264 frame

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		// Send with empty clients slice to benchmark packaging and serialization
		_ = s.send(nil, 1, int64(i*1000), frameData)
	}
}
