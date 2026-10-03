package vm

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"NanoKVM-Server/proto"

	"github.com/gin-gonic/gin"
)

func setupTestPaths(t *testing.T) (string, func()) {
	t.Helper()
	tempDir := t.TempDir()

	oldLT6911Power := LT6911Power
	oldLT6911HdmiPower := LT6911HdmiPower
	oldLT6911LoopoutPower := LT6911LoopoutPower
	oldHdmiPassthroughConfigFile := HdmiPassthroughConfigFile

	procDir := filepath.Join(tempDir, "proc")
	etcDir := filepath.Join(tempDir, "etc")
	_ = os.MkdirAll(procDir, 0755)
	_ = os.MkdirAll(etcDir, 0755)

	LT6911Power = filepath.Join(procDir, "power")
	LT6911HdmiPower = filepath.Join(procDir, "hdmi_power")
	LT6911LoopoutPower = filepath.Join(procDir, "loopout_power")
	HdmiPassthroughConfigFile = filepath.Join(etcDir, "hdmi_passthrough")

	cleanup := func() {
		LT6911Power = oldLT6911Power
		LT6911HdmiPower = oldLT6911HdmiPower
		LT6911LoopoutPower = oldLT6911LoopoutPower
		HdmiPassthroughConfigFile = oldHdmiPassthroughConfigFile
	}

	return tempDir, cleanup
}

func TestIsHdmiEnabled(t *testing.T) {
	tempDir := t.TempDir()
	flagFile := filepath.Join(tempDir, "flag")

	tests := []struct {
		content string
		want    bool
	}{
		{"on", true},
		{"on\n", true},
		{" 1 ", true},
		{"1\n", true},
		{"off", false},
		{"0", false},
		{"", false},
		{"invalid", false},
	}

	for _, tt := range tests {
		if err := os.WriteFile(flagFile, []byte(tt.content), 0644); err != nil {
			t.Fatalf("failed to write test file: %v", err)
		}
		got, err := isHdmiEnabled(flagFile)
		if err != nil {
			t.Errorf("isHdmiEnabled(%q) unexpected error: %v", tt.content, err)
		}
		if got != tt.want {
			t.Errorf("isHdmiEnabled(%q) = %v; want %v", tt.content, got, tt.want)
		}
	}

	_, err := isHdmiEnabled(filepath.Join(tempDir, "non_existent"))
	if err == nil {
		t.Errorf("isHdmiEnabled on non-existent file expected error, got nil")
	}
}

func TestSaveHdmiPassthroughConfig(t *testing.T) {
	_, cleanup := setupTestPaths(t)
	defer cleanup()

	if err := saveHdmiPassthroughConfig("on"); err != nil {
		t.Fatalf("saveHdmiPassthroughConfig failed: %v", err)
	}

	content, err := os.ReadFile(HdmiPassthroughConfigFile)
	if err != nil {
		t.Fatalf("failed to read config file: %v", err)
	}

	if strings.TrimSpace(string(content)) != "on" {
		t.Errorf("expected 'on', got %q", string(content))
	}
}

func TestInitHdmiPassthrough(t *testing.T) {
	_, cleanup := setupTestPaths(t)
	defer cleanup()

	// 1. Loopout file does not exist -> Init does nothing
	InitHdmiPassthrough()
	if _, err := os.Stat(HdmiPassthroughConfigFile); !os.IsNotExist(err) {
		t.Errorf("expected config file not to exist when loopout power is absent")
	}

	// 2. Loopout file exists, config has "off"
	_ = os.WriteFile(LT6911LoopoutPower, []byte("on\n"), 0644)
	_ = os.WriteFile(LT6911HdmiPower, []byte("1\n"), 0644)
	_ = os.WriteFile(HdmiPassthroughConfigFile, []byte("off\n"), 0644)

	InitHdmiPassthrough()

	loopoutContent, _ := os.ReadFile(LT6911LoopoutPower)
	if strings.TrimSpace(string(loopoutContent)) != "0" {
		t.Errorf("expected loopout to be '0', got %q", string(loopoutContent))
	}

	// 3. Loopout file exists, config has "on"
	_ = os.WriteFile(HdmiPassthroughConfigFile, []byte("on\n"), 0644)
	InitHdmiPassthrough()

	loopoutContent, _ = os.ReadFile(LT6911LoopoutPower)
	if strings.TrimSpace(string(loopoutContent)) != "1" {
		t.Errorf("expected loopout to be '1', got %q", string(loopoutContent))
	}

	// 4. Config file does not exist, but hardware default is "on"
	_ = os.Remove(HdmiPassthroughConfigFile)
	_ = os.WriteFile(LT6911LoopoutPower, []byte("on\n"), 0644)
	InitHdmiPassthrough()

	cfgContent, err := os.ReadFile(HdmiPassthroughConfigFile)
	if err != nil || strings.TrimSpace(string(cfgContent)) != "on" {
		t.Errorf("expected config to be initialized to 'on', got %q, err=%v", string(cfgContent), err)
	}
}

func TestGetSetHdmiPassthroughAPI(t *testing.T) {
	gin.SetMode(gin.TestMode)
	_, cleanup := setupTestPaths(t)
	defer cleanup()

	_ = os.WriteFile(LT6911LoopoutPower, []byte("on\n"), 0644)
	_ = os.WriteFile(LT6911HdmiPower, []byte("1\n"), 0644)

	svc := &Service{}

	// Test GET when procfs has "on"
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodGet, "/api/vm/hdmi/passthrough", nil)

	svc.GetHdmiPassthrough(c)
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}

	var resp struct {
		Code int                          `json:"code"`
		Data proto.GetHdmiPassthroughRsp `json:"data"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}
	if !resp.Data.Enabled {
		t.Errorf("expected enabled=true, got %v", resp.Data.Enabled)
	}

	// Test SET to false (disable)
	setReqBody := proto.SetHdmiPassthroughReq{Enabled: false}
	bodyBytes, _ := json.Marshal(setReqBody)

	w = httptest.NewRecorder()
	c, _ = gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodPost, "/api/vm/hdmi/passthrough", bytes.NewReader(bodyBytes))
	c.Request.Header.Set("Content-Type", "application/json")

	svc.SetHdmiPassthrough(c)
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}

	// Verify file was persisted
	cfgContent, err := os.ReadFile(HdmiPassthroughConfigFile)
	if err != nil || strings.TrimSpace(string(cfgContent)) != "off" {
		t.Errorf("expected config to be 'off', got %q, err=%v", string(cfgContent), err)
	}

	// Test fallback in GET when procfs is deleted
	_ = os.Remove(LT6911LoopoutPower)
	w = httptest.NewRecorder()
	c, _ = gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodGet, "/api/vm/hdmi/passthrough", nil)

	svc.GetHdmiPassthrough(c)
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}
	resp.Data.Enabled = true
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if resp.Data.Enabled {
		t.Errorf("expected fallback enabled=false, got true")
	}
}
