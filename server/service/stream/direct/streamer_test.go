package direct

import (
	"encoding/binary"
	"testing"
)

func TestPackFrameLayout(t *testing.T) {
	m := packFrame(true, 1000, []byte{0x00, 0x00, 0x00, 0x01})
	defer m.Release()
	if len(m.Data) != 13 || m.Data[0] != 1 || !m.Key {
		t.Fatalf("bad header: %v key=%v", m.Data, m.Key)
	}
	if ts := binary.LittleEndian.Uint64(m.Data[1:9]); ts != 1000 {
		t.Fatalf("timestamp = %d, want 1000", ts)
	}
	if string(m.Data[9:]) != "\x00\x00\x00\x01" {
		t.Fatalf("payload = %v", m.Data[9:])
	}
}

func BenchmarkPackFrame(b *testing.B) {
	frameData := make([]byte, 64*1024) // 64KB mock H.264 frame
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		packFrame(i%30 == 0, int64(i*1000), frameData).Release()
	}
}
