package network

import (
	"NanoKVM-Server/proto"
	"NanoKVM-Server/utils"
	"bytes"
	"crypto/subtle"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"
	log "github.com/sirupsen/logrus"
)

const (
	WiFiScript = "/kvmcomm/scripts/wifi.sh"

	maxSSIDLen = 32 // bytes (IEEE 802.11)
	minPSKLen  = 8  // WPA passphrase, bytes
	maxPSKLen  = 63
	hexPSKLen  = 64 // raw PSK as hex
)

var (
	WiFiApPassFile  = "/tmp/ap.pass"
	HostapdConfFile = "/dev/shm/tmp/wifi/hostapd.conf"
	WiFiConfigFlag  = "/tmp/wifi_config"

	// wifiScriptPath is the script connect() runs; a var so tests can point it
	// at a stub.
	wifiScriptPath = WiFiScript

	// connectTimeout bounds "wifi.sh connect_start". The script's own worst
	// case (association wait + bounded DHCP probe + non-blocking rollback) is
	// ~26-32 s, see the budget comment above ASSOC_WAIT in wifi.sh; the slack
	// covers waiting for the script's lock. On timeout the process group gets
	// SIGTERM (the script then rolls back to the previous network itself) and
	// SIGKILL only after connectTermGrace.
	connectTimeout   = 45 * time.Second
	connectTermGrace = 5 * time.Second

	// Post-connect check; vars so tests can stub them.
	wifiConnectedFn    = isWifiConnected
	connectPollRetries = 5
	connectPollDelay   = 2 * time.Second

	errConnectTimeout = errors.New("connect wifi timeout")
)

// validateWifiCredentials rejects input that wpa_supplicant cannot accept
// (or that cannot round-trip through wpa_cli / wpa_supplicant.conf) before
// anything touches the current connection. An empty password means an open
// network.
func validateWifiCredentials(ssid, password string) error {
	if ssid == "" || len(ssid) > maxSSIDLen {
		return fmt.Errorf("ssid must be 1-%d bytes", maxSSIDLen)
	}
	if hasControlChars(ssid) {
		return errors.New("ssid contains control characters")
	}
	if password == "" {
		return nil
	}
	if len(password) == hexPSKLen && isHex(password) {
		return nil
	}
	if len(password) < minPSKLen || len(password) > maxPSKLen {
		return fmt.Errorf("password must be %d-%d characters or %d hex digits", minPSKLen, maxPSKLen, hexPSKLen)
	}
	if hasControlChars(password) {
		return errors.New("password contains control characters")
	}
	return nil
}

func hasControlChars(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < 0x20 || s[i] == 0x7f {
			return true
		}
	}
	return false
}

func isHex(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
			return false
		}
	}
	return true
}

func (s *Service) GetWifi(c *gin.Context) {
	var rsp proto.Response
	var data proto.GetWifiRsp

	interfaces, err := findWifiInterfaces()
	if err != nil || interfaces == nil || len(interfaces) == 0 {
		data.Supported = false
		rsp.OkRspWithData(c, &data)
		return
	}

	data.Supported = true
	data.APMode = isAPMode()

	details, err := utils.GetWifiDetails()
	if err != nil || details == nil || details.WPAState != "COMPLETED" {
		data.Connected = false
		rsp.OkRspWithData(c, &data)
		return
	}

	data.Connected = true

	data.Wifi = &proto.WiFi{
		SSID:      details.SSID,
		BSSID:     details.BSSID,
		Signal:    0,
		Frequency: 0,
		Security:  details.KeyMgmt,
	}

	rsp.OkRspWithData(c, &data)
	log.Debugf("get wifi successfully")
}

func (s *Service) ConnectWifiNoAuth(c *gin.Context) {
	var req proto.ConnectWifiReq
	var rsp proto.Response

	// Verify the AP password first: it only reads two small files, whereas
	// the mode check below spawns pgrep and wpa_cli.
	apKey := c.GetHeader("X-AP-Key")
	if !verifyApPassword(apKey) {
		time.Sleep(2 * time.Second)
		rsp.ErrRsp(c, -4, "unauthorized")
		return
	}

	// Check Wi-Fi configuration mode (flag file present, or actively in AP
	// mode). Same rule as before; only the order changed so the cheap stat
	// runs before isAPMode.
	if !isWifiConfigMode() {
		rsp.ErrRsp(c, -1, "invalid mode")
		return
	}

	if err := proto.ParseFormRequest(c, &req); err != nil {
		rsp.ErrRsp(c, -2, "invalid parameters")
		return
	}

	if err := validateWifiCredentials(req.Ssid, req.Password); err != nil {
		rsp.ErrRsp(c, -2, "invalid parameters: "+err.Error())
		return
	}

	if err := connect(req.Ssid, req.Password); err != nil {
		rsp.ErrRsp(c, -3, "set wifi failed")
		return
	}

	rsp.OkRsp(c)
	log.Debugf("connect wifi successfully")
}

func (s *Service) VerifyApLogin(c *gin.Context) {
	var rsp proto.Response

	apKey := c.GetHeader("X-AP-Key")
	if !verifyApPassword(apKey) {
		time.Sleep(2 * time.Second)
		rsp.ErrRsp(c, -4, "unauthorized")
		return
	}

	if !isAPMode() {
		time.Sleep(2 * time.Second)
		rsp.ErrRsp(c, -1, "invalid mode")
		return
	}

	rsp.OkRsp(c)
}

func (s *Service) ConnectWifi(c *gin.Context) {
	var req proto.ConnectWifiReq
	var rsp proto.Response

	if err := proto.ParseFormRequest(c, &req); err != nil {
		rsp.ErrRsp(c, -1, "invalid parameters")
		return
	}

	if err := validateWifiCredentials(req.Ssid, req.Password); err != nil {
		rsp.ErrRsp(c, -1, "invalid parameters: "+err.Error())
		return
	}

	if err := connect(req.Ssid, req.Password); err != nil {
		rsp.ErrRsp(c, -2, "set wifi failed")
		return
	}

	rsp.OkRsp(c)
	log.Debugf("connect wifi successfully")
}

func (s *Service) DisconnectWifi(c *gin.Context) {
	var rsp proto.Response

	_ = exec.Command(WiFiScript, "connect_stop").Run()

	for range 5 {
		time.Sleep(2 * time.Second)
		if !isWifiConnected() {
			rsp.OkRsp(c)
			return
		}
	}

	rsp.ErrRsp(c, -1, "wifi disconnect failed")
}

func connect(ssid string, password string) error {
	if err := validateWifiCredentials(ssid, password); err != nil {
		return err
	}

	// connect_start itself stops the AP and disconnects the current network
	// (recording it for rollback), so no separate connect_stop is needed.
	_ = exec.Command(wifiScriptPath, "ap_stop").Run()

	args := []string{"connect_start", ssid}
	if password != "" {
		args = append(args, password)
	}

	if err := runConnectScript(args, connectTimeout, connectTermGrace); err != nil {
		return err
	}

	for i := 0; i < connectPollRetries; i++ {
		if wifiConnectedFn() {
			return nil
		}
		time.Sleep(connectPollDelay)
	}

	return errConnectTimeout
}

// runConnectScript runs wifi.sh in its own process group. If it outlives
// timeout, the group gets SIGTERM, which makes the script roll back to the
// previous network before exiting, and SIGKILL only if it is still running
// after grace. Nothing else is run after a timeout: in particular not
// connect_stop, which would disable and save the network the rollback has
// just re-selected.
func runConnectScript(args []string, timeout, grace time.Duration) error {
	cmd := exec.Command(wifiScriptPath, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out

	if err := cmd.Start(); err != nil {
		log.Errorf("failed to start wifi connect command: %v", err)
		return err
	}

	done := make(chan error, 1)
	go func() {
		done <- cmd.Wait()
	}()

	timer := time.NewTimer(timeout)
	defer timer.Stop()

	select {
	case err := <-done:
		if err != nil {
			log.Errorf("connect wifi err: %v, out: %s", err, out.String())
			return err
		}
		return nil
	case <-timer.C:
	}

	pgid := cmd.Process.Pid
	log.Errorf("wifi connect timed out after %s, sending SIGTERM", timeout)
	if err := syscall.Kill(-pgid, syscall.SIGTERM); err != nil {
		log.Errorf("failed to SIGTERM process group: %v", err)
	}

	graceTimer := time.NewTimer(grace)
	defer graceTimer.Stop()

	select {
	case <-done:
		log.Errorf("wifi connect script exited after SIGTERM, out: %s", out.String())
	case <-graceTimer.C:
		log.Errorf("wifi connect script ignored SIGTERM for %s, sending SIGKILL", grace)
		if err := syscall.Kill(-pgid, syscall.SIGKILL); err != nil {
			log.Errorf("failed to SIGKILL process group: %v", err)
		}
		<-done
	}

	return errConnectTimeout
}

func isWifiConnected() bool {
	details, err := utils.GetWifiDetails()
	if err != nil {
		return false
	}

	return details.WPAState == "COMPLETED" && details.IPAddress != ""
}

func findWifiInterfaces() ([]string, error) {
	const netDir = "/sys/class/net"
	var interfaces []string

	files, err := os.ReadDir(netDir)
	if err != nil {
		return nil, fmt.Errorf("failed to read %s: %w", netDir, err)
	}

	for _, file := range files {
		if file.IsDir() || (file.Type()&os.ModeSymlink) != 0 {
			wirelessPath := filepath.Join(netDir, file.Name(), "wireless")
			if _, err := os.Stat(wirelessPath); err == nil {
				interfaces = append(interfaces, file.Name())
			}
		}
	}

	return interfaces, nil
}

func isAPMode() bool {
	if isWifiConnected() {
		return false
	}

	cmd := exec.Command("pgrep", "-x", "hostapd")
	if err := cmd.Run(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			log.Debugf("pgrep process not found with exit code: %v", exitErr)
			return false
		}

		return false
	}

	return true
}

func isWifiConfigMode() bool {
	if _, err := os.Stat(WiFiConfigFlag); err == nil {
		return true
	}
	return isAPMode()
}

// getExpectedApPassword returns the one AP password that is accepted. The
// running hostapd configuration is authoritative; /tmp/ap.pass (written
// together with it by wifi.sh ap_start) is used only when hostapd.conf has no
// passphrase, so a stale ap.pass can never act as a second valid password.
func getExpectedApPassword() string {
	if confByte, err := os.ReadFile(HostapdConfFile); err == nil {
		for _, line := range strings.Split(string(confByte), "\n") {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "wpa_passphrase=") {
				if pass := strings.TrimSpace(strings.TrimPrefix(line, "wpa_passphrase=")); pass != "" {
					return pass
				}
				break
			}
		}
	}

	if passByte, err := os.ReadFile(WiFiApPassFile); err == nil {
		return strings.TrimSpace(string(passByte))
	}

	return ""
}

func verifyApPassword(inputPass string) bool {
	inputPass = strings.TrimSpace(inputPass)
	if inputPass == "" {
		return false
	}

	expected := getExpectedApPassword()
	if expected == "" {
		return false
	}

	return subtle.ConstantTimeCompare([]byte(inputPass), []byte(expected)) == 1
}

func getApPassword() string {
	return getExpectedApPassword()
}
