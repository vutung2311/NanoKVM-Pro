package utils

import (
	"errors"
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

	resetSystemctlClient()
}
