package vm

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"NanoKVM-Server/proto"

	"github.com/gin-gonic/gin"
)

func TestGetInfo_DeviceNumber(t *testing.T) {
	gin.SetMode(gin.TestMode)
	s := NewService()

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	req, _ := http.NewRequest(http.MethodGet, "/api/vm/info", nil)
	c.Request = req

	s.GetInfo(c)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}

	var resp struct {
		Code int              `json:"code"`
		Msg  string           `json:"msg"`
		Data proto.GetInfoRsp `json:"data"`
	}

	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	if resp.Data.DeviceNumber == "" || resp.Data.DeviceNumber == "unknown" {
		t.Fatalf("expected valid non-empty device number, got %q", resp.Data.DeviceNumber)
	}

	if resp.Data.DeviceNumber != "NebE20020" {
		t.Logf("DeviceNumber reported: %q", resp.Data.DeviceNumber)
	}
}
