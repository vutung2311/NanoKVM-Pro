package utils

import (
	"errors"
	"github.com/coreos/go-systemd/v22/dbus"
	"sync"
	"testing"
)

func TestIsConnectionError(t *testing.T) {
	tests := []struct {
		err      error
		expected bool
	}{
		{nil, false},
		{errors.New("dbus: connection closed by user"), true},
		{errors.New("write: broken pipe"), true},
		{errors.New("unexpected EOF"), true},
		{errors.New("unit not found"), false},
		{errors.New("permission denied"), false},
	}

	for _, tt := range tests {
		got := isConnectionError(tt.err)
		if got != tt.expected {
			t.Errorf("isConnectionError(%v) = %v; want %v", tt.err, got, tt.expected)
		}
	}
}

func TestSystemctlClient_ConcurrentAccess(t *testing.T) {
	// Concurrent callers requesting the client should not race
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, _ = getSystemctlClient()
		}()
	}
	wg.Wait()

	client, _ := getSystemctlClient()
	resetSystemctlClient(client)
}

// A reset for a connection that has already been replaced must not close the
// current one.
func TestResetSystemctlClientIgnoresStaleConnection(t *testing.T) {
	systemctlClientMu.Lock()
	saved := systemctlClient
	current := &dbus.Conn{}
	systemctlClient = current
	systemctlClientMu.Unlock()
	defer func() {
		systemctlClientMu.Lock()
		systemctlClient = saved
		systemctlClientMu.Unlock()
	}()

	resetSystemctlClient(&dbus.Conn{}) // a different, stale connection
	systemctlClientMu.Lock()
	still := systemctlClient == current
	systemctlClientMu.Unlock()
	if !still {
		t.Fatal("reset of a stale connection replaced the current client")
	}
}
