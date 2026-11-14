package network

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestVerifyApPassword(t *testing.T) {
	tempDir := t.TempDir()
	origHostapd := HostapdConfFile
	origApPass := WiFiApPassFile
	defer func() {
		HostapdConfFile = origHostapd
		WiFiApPassFile = origApPass
	}()

	testHostapd := filepath.Join(tempDir, "hostapd.conf")
	testApPass := filepath.Join(tempDir, "ap.pass")

	HostapdConfFile = testHostapd
	WiFiApPassFile = testApPass

	// Case 1: Neither file exists
	if verifyApPassword("mypassword") {
		t.Fatalf("expected verification to fail when no config files exist")
	}

	// Case 2: Only hostapd.conf exists with standard wpa_passphrase
	hostapdContent := `interface=wlan0
driver=nl80211
ssid=NanoKVM-Test
wpa=2
wpa_passphrase=HostapdSecret123
wpa_key_mgmt=WPA-PSK
`
	if err := os.WriteFile(testHostapd, []byte(hostapdContent), 0644); err != nil {
		t.Fatalf("failed to write hostapd.conf: %v", err)
	}

	if !verifyApPassword("HostapdSecret123") {
		t.Fatalf("expected HostapdSecret123 to verify successfully")
	}
	// Case 2b: Whitespace handling in user input
	if !verifyApPassword("  HostapdSecret123 \n ") {
		t.Fatalf("expected trimmed HostapdSecret123 to verify successfully")
	}
	// Case 2c: Wrong password
	if verifyApPassword("WrongPassword") {
		t.Fatalf("expected wrong password to fail")
	}
	if verifyApPassword("") {
		t.Fatalf("expected empty password to fail")
	}

	// Case 3: hostapd.conf has CRLF / trailing spaces
	hostapdCrlf := "interface=wlan0\r\nssid=NanoKVM-Test\r\nwpa_passphrase=HostapdSecret123   \r\n"
	if err := os.WriteFile(testHostapd, []byte(hostapdCrlf), 0644); err != nil {
		t.Fatalf("failed to write hostapd.conf: %v", err)
	}
	if !verifyApPassword("HostapdSecret123") {
		t.Fatalf("expected HostapdSecret123 with CRLF in config to verify successfully")
	}

	// Case 4: Only /tmp/ap.pass exists (hostapd.conf missing) -> fallback
	_ = os.Remove(testHostapd)
	if err := os.WriteFile(testApPass, []byte("EchoPassword456\n"), 0644); err != nil {
		t.Fatalf("failed to write ap.pass: %v", err)
	}
	if !verifyApPassword("EchoPassword456") {
		t.Fatalf("expected EchoPassword456 to verify from ap.pass")
	}

	// Case 5: Both exist with different passwords: hostapd.conf is
	// authoritative and a stale ap.pass must NOT be accepted as a second key.
	if err := os.WriteFile(testHostapd, []byte("wpa_passphrase=HostapdPass\n"), 0644); err != nil {
		t.Fatalf("failed to write hostapd.conf: %v", err)
	}
	if !verifyApPassword("HostapdPass") {
		t.Fatalf("expected HostapdPass to verify")
	}
	if verifyApPassword("EchoPassword456") {
		t.Fatalf("stale ap.pass must not be accepted when hostapd.conf has a passphrase")
	}

	// Case 6: hostapd.conf without a passphrase falls back to ap.pass
	if err := os.WriteFile(testHostapd, []byte("ssid=x\nwpa_passphrase=\n"), 0644); err != nil {
		t.Fatalf("failed to write hostapd.conf: %v", err)
	}
	if !verifyApPassword("EchoPassword456") {
		t.Fatalf("expected ap.pass fallback when hostapd.conf has no passphrase")
	}

	// Case 7: getApPassword helper returns the authoritative password
	if err := os.WriteFile(testHostapd, []byte("wpa_passphrase=HostapdPass\n"), 0644); err != nil {
		t.Fatalf("failed to write hostapd.conf: %v", err)
	}
	if got := getApPassword(); got != "HostapdPass" {
		t.Fatalf("expected HostapdPass, got: %s", got)
	}
}

func TestValidateWifiCredentials(t *testing.T) {
	hex64 := strings.Repeat("0123456789abcdef", 4)
	tests := []struct {
		name     string
		ssid     string
		password string
		ok       bool
	}{
		{"open network", "Cafe", "", true},
		{"min passphrase", "Home", "12345678", true},
		{"max passphrase", "Home", strings.Repeat("a", 63), true},
		{"backslash and quote", "Home", `pa\ss"wo"rd\`, true},
		{"spaces and hash", "Home", " pass #word ", true},
		{"utf8 passphrase", "Home", "pässwörd", true},
		{"hex psk", "Home", hex64, true},
		{"hex psk uppercase", "Home", strings.ToUpper(hex64), true},
		{"ssid 32 bytes", strings.Repeat("s", 32), "12345678", true},
		{"utf8 ssid within 32 bytes", "Wi-Fi Café ☕", "12345678", true},
		{"ssid with quote", `My "Net"`, "12345678", true},

		{"empty ssid", "", "12345678", false},
		{"ssid 33 bytes", strings.Repeat("s", 33), "12345678", false},
		{"ssid 32 runes but >32 bytes", strings.Repeat("é", 17), "12345678", false},
		{"ssid with newline", "Home\nevil", "12345678", false},
		{"ssid with tab", "Home\tnet", "12345678", false},
		{"short passphrase", "Home", "1234567", false},
		{"long passphrase", "Home", strings.Repeat("x", 64), false},
		{"64 chars not hex", "Home", strings.Repeat("g", 64), false},
		{"65 hex", "Home", hex64 + "0", false},
		{"passphrase with newline", "Home", "password\nnetwork={", false},
		{"passphrase with CR", "Home", "password\r", false},
		{"passphrase with DEL", "Home", "password\x7f", false},
		{"passphrase with NUL", "Home", "pass\x00word", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateWifiCredentials(tt.ssid, tt.password)
			if tt.ok && err != nil {
				t.Fatalf("expected valid, got %v", err)
			}
			if !tt.ok && err == nil {
				t.Fatalf("expected error for ssid=%q password=%q", tt.ssid, tt.password)
			}
		})
	}
}

// stubScript installs a fake wifi.sh that appends each invocation (and any
// signal it receives) to a log file, and points connect() at it.
func stubScript(t *testing.T, connectStartBody string) (logPath string) {
	t.Helper()
	dir := t.TempDir()
	logPath = filepath.Join(dir, "calls.log")
	script := filepath.Join(dir, "wifi.sh")
	content := `#!/bin/bash
LOG="` + logPath + `"
echo "$*" >> "$LOG"
case "$1" in
connect_start)
` + connectStartBody + `
    ;;
esac
exit 0
`
	if err := os.WriteFile(script, []byte(content), 0755); err != nil {
		t.Fatalf("write stub: %v", err)
	}

	origScript := wifiScriptPath
	origTimeout, origGrace := connectTimeout, connectTermGrace
	origConnected, origRetries, origDelay := wifiConnectedFn, connectPollRetries, connectPollDelay
	t.Cleanup(func() {
		wifiScriptPath = origScript
		connectTimeout, connectTermGrace = origTimeout, origGrace
		wifiConnectedFn, connectPollRetries, connectPollDelay = origConnected, origRetries, origDelay
	})

	wifiScriptPath = script
	connectPollRetries = 2
	connectPollDelay = 10 * time.Millisecond
	return logPath
}

func readLog(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("read log: %v", err)
	}
	return string(b)
}

func TestConnectTimeoutSendsSigtermAndSkipsConnectStop(t *testing.T) {
	// The stub behaves like wifi.sh: on TERM it runs its rollback and exits.
	logPath := stubScript(t, `    trap 'echo TERM >> "$LOG"; echo rollback >> "$LOG"; exit 143' TERM
    sleep 30 &
    wait $!`)
	connectTimeout = 300 * time.Millisecond
	connectTermGrace = 3 * time.Second
	wifiConnectedFn = func() bool { t.Fatal("must not poll after a timeout"); return false }

	start := time.Now()
	err := connect("HomeNet", "secret123")
	elapsed := time.Since(start)

	if !errors.Is(err, errConnectTimeout) {
		t.Fatalf("expected timeout error, got %v", err)
	}
	if elapsed >= connectTermGrace {
		t.Fatalf("script handles SIGTERM, so connect should return before the SIGKILL grace; took %s", elapsed)
	}

	log := readLog(t, logPath)
	for _, want := range []string{"ap_stop", "connect_start HomeNet secret123", "TERM", "rollback"} {
		if !strings.Contains(log, want) {
			t.Fatalf("expected %q in calls, got:\n%s", want, log)
		}
	}
	if strings.Contains(log, "connect_stop") {
		t.Fatalf("connect_stop must not run (it would undo the rollback), got:\n%s", log)
	}
}

func TestConnectTimeoutKillsAfterGraceWhenTermIgnored(t *testing.T) {
	logPath := stubScript(t, `    trap 'echo TERM-ignored >> "$LOG"' TERM
    while :; do sleep 0.05; done`)
	connectTimeout = 200 * time.Millisecond
	connectTermGrace = 400 * time.Millisecond
	wifiConnectedFn = func() bool { return false }

	start := time.Now()
	err := connect("HomeNet", "secret123")
	elapsed := time.Since(start)

	if !errors.Is(err, errConnectTimeout) {
		t.Fatalf("expected timeout error, got %v", err)
	}
	if elapsed < connectTimeout+connectTermGrace {
		t.Fatalf("SIGKILL must wait for the grace period; returned after %s", elapsed)
	}
	if elapsed > connectTimeout+connectTermGrace+3*time.Second {
		t.Fatalf("SIGKILL did not stop the script promptly; took %s", elapsed)
	}

	log := readLog(t, logPath)
	if !strings.Contains(log, "TERM-ignored") {
		t.Fatalf("expected SIGTERM before SIGKILL, got:\n%s", log)
	}
	if strings.Contains(log, "connect_stop") {
		t.Fatalf("connect_stop must not run after a timeout kill, got:\n%s", log)
	}
}

func TestConnectSuccess(t *testing.T) {
	logPath := stubScript(t, `    exit 0`)
	connectTimeout = 5 * time.Second
	wifiConnectedFn = func() bool { return true }

	if err := connect("Cafe", ""); err != nil {
		t.Fatalf("expected success, got %v", err)
	}
	log := readLog(t, logPath)
	if !strings.Contains(log, "connect_start Cafe\n") {
		t.Fatalf("open network must be started without a password argument, got:\n%s", log)
	}
	if strings.Contains(log, "connect_stop") {
		t.Fatalf("unexpected connect_stop, got:\n%s", log)
	}
}

func TestConnectScriptFailureIsNotTimeout(t *testing.T) {
	stubScript(t, `    exit 1`)
	connectTimeout = 5 * time.Second
	wifiConnectedFn = func() bool { t.Fatal("must not poll after script failure"); return false }

	err := connect("HomeNet", "secret123")
	if err == nil || errors.Is(err, errConnectTimeout) {
		t.Fatalf("expected script failure error, got %v", err)
	}
}

func TestConnectRejectsInvalidInputWithoutRunningScript(t *testing.T) {
	logPath := stubScript(t, `    exit 0`)
	wifiConnectedFn = func() bool { return true }

	for _, c := range []struct{ ssid, pass string }{
		{"HomeNet", "short"},
		{"HomeNet", "pass\nword123"},
		{strings.Repeat("x", 33), "secret123"},
	} {
		if err := connect(c.ssid, c.pass); err == nil {
			t.Fatalf("expected validation error for %q/%q", c.ssid, c.pass)
		}
	}
	if log := readLog(t, logPath); log != "" {
		t.Fatalf("invalid input must not reach wifi.sh (not even ap_stop), got:\n%s", log)
	}
}
