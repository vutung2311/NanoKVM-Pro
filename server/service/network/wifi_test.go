package network

import (
	"os"
	"path/filepath"
	"testing"
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

	// Case 4: Only /tmp/ap.pass exists (e.g. hostapd.conf removed)
	_ = os.Remove(testHostapd)
	if err := os.WriteFile(testApPass, []byte("EchoPassword456\n"), 0644); err != nil {
		t.Fatalf("failed to write ap.pass: %v", err)
	}
	if !verifyApPassword("EchoPassword456") {
		t.Fatalf("expected EchoPassword456 to verify from ap.pass")
	}

	// Case 5: Both exist with different passwords (e.g. out of sync)
	if err := os.WriteFile(testHostapd, []byte("wpa_passphrase=HostapdPass\n"), 0644); err != nil {
		t.Fatalf("failed to write hostapd.conf: %v", err)
	}
	// Both candidates should be accepted so user is never locked out
	if !verifyApPassword("HostapdPass") {
		t.Fatalf("expected HostapdPass to verify")
	}
	if !verifyApPassword("EchoPassword456") {
		t.Fatalf("expected EchoPassword456 to verify as alternate candidate")
	}

	// Case 6: getApPassword helper returns preferred password
	firstPass := getApPassword()
	if firstPass != "HostapdPass" {
		t.Fatalf("expected first pass to be HostapdPass, got: %s", firstPass)
	}
}

