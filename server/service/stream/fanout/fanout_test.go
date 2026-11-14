package fanout

import "testing"

func frame(key bool, b byte) *Msg {
	m := NewMsg(1, key)
	m.Data[0] = b
	return m
}

func recv(c *Client) []byte {
	var out []byte
	for {
		select {
		case m := <-c.C():
			out = append(out, m.Data[0])
			m.Release()
		default:
			return out
		}
	}
}

// A dependent-stream client waits for a keyframe, and after its mailbox
// overflows it drops frames until the next keyframe instead of receiving a
// broken reference chain.
func TestDependentClientResyncsOnKeyframe(t *testing.T) {
	h := NewHub(true)
	c, _ := h.Add()

	h.Broadcast(frame(false, 0)) // before the first keyframe: dropped
	h.Broadcast(frame(true, 1))
	for i := 2; i < 2+DependentQueue; i++ { // fills and overflows the mailbox
		h.Broadcast(frame(false, byte(i)))
	}
	h.Broadcast(frame(false, 50)) // still waiting for a keyframe: dropped

	got := recv(c)
	if len(got) != DependentQueue || got[0] != 1 {
		t.Fatalf("queued = %v, want keyframe 1 then %d frames", got, DependentQueue-1)
	}

	h.Broadcast(frame(false, 60)) // dropped: overflow requires a keyframe
	h.Broadcast(frame(true, 61))
	h.Broadcast(frame(false, 62))
	if got := recv(c); len(got) != 2 || got[0] != 61 || got[1] != 62 {
		t.Fatalf("after overflow got %v, want [61 62]", got)
	}
}

// An independent-stream client only ever holds the newest frame.
func TestIndependentClientKeepsNewest(t *testing.T) {
	h := NewHub(false)
	c, _ := h.Add()
	for i := 0; i < 5; i++ {
		h.Broadcast(frame(true, byte(i)))
	}
	if got := recv(c); len(got) != 1 || got[0] != 4 {
		t.Fatalf("got %v, want [4]", got)
	}
}

// A client that never reads does not stop others from receiving.
func TestSlowClientDoesNotBlockOthers(t *testing.T) {
	h := NewHub(true)
	slow, _ := h.Add()
	fast, _ := h.Add()
	_ = slow

	h.Broadcast(frame(true, 0))
	for i := 1; i < 100; i++ {
		h.Broadcast(frame(i%10 == 0, byte(i)))
		recv(fast)
	}
	if n := h.Remove(slow); n != 1 {
		t.Fatalf("remaining = %d, want 1", n)
	}
	select {
	case <-slow.Done():
	default:
		t.Fatal("Done not closed after Remove")
	}
	slow.Drain()
}
