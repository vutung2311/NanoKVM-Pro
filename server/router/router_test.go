package router

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

func init() {
	gin.SetMode(gin.TestMode)
}

func setupTestRouter() *gin.Engine {
	r := gin.New()
	Init(r)
	return r
}

func TestRouter_Endpoints(t *testing.T) {
	r := setupTestRouter()

	// 1. Test /kvm redirect
	w := httptest.NewRecorder()
	req, _ := http.NewRequest(http.MethodGet, "/kvm", nil)
	r.ServeHTTP(w, req)

	if w.Code != http.StatusFound {
		t.Fatalf("expected 302 for /kvm, got %d", w.Code)
	}

	// 2. Test an API endpoint (e.g. /api/auth/password)
	wAPI := httptest.NewRecorder()
	reqAPI, _ := http.NewRequest(http.MethodGet, "/api/auth/password", nil)
	r.ServeHTTP(wAPI, reqAPI)

	// Should not return 404 (route exists)
	if wAPI.Code == http.StatusNotFound {
		t.Fatalf("expected /api/auth/password to be routed, got 404")
	}

	// 3. Test /api/vm/info endpoint requires token (returns 401, route exists)
	wInfo := httptest.NewRecorder()
	reqInfo, _ := http.NewRequest(http.MethodGet, "/api/vm/info", nil)
	r.ServeHTTP(wInfo, reqInfo)

	if wInfo.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for unauthorized /api/vm/info, got %d", wInfo.Code)
	}
}

func BenchmarkRouter_API_Endpoint(b *testing.B) {
	r := setupTestRouter()
	req, _ := http.NewRequest(http.MethodGet, "/api/auth/password", nil)

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
	}
}

func BenchmarkRouter_KVM_Redirect(b *testing.B) {
	r := setupTestRouter()
	req, _ := http.NewRequest(http.MethodGet, "/kvm", nil)

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
	}
}
