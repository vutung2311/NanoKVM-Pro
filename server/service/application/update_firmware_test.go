package application

import (
	"path/filepath"
	"testing"
)

func TestScheduleFirmwareRebootReportsStartFailure(t *testing.T) {
	previous := firmwareRebootCommand
	defer func() { firmwareRebootCommand = previous }()

	firmwareRebootCommand = []string{filepath.Join(t.TempDir(), "missing-reboot-helper")}
	if err := scheduleFirmwareReboot("job"); err == nil {
		t.Fatal("scheduleFirmwareReboot() succeeded with a missing helper; the manual-reboot path would be unreachable")
	}
}

func TestScheduleFirmwareRebootStartsHelper(t *testing.T) {
	previous := firmwareRebootCommand
	defer func() { firmwareRebootCommand = previous }()

	firmwareRebootCommand = []string{"/bin/sh", "-c", "exit 0"}
	if err := scheduleFirmwareReboot("job"); err != nil {
		t.Fatalf("scheduleFirmwareReboot() error = %v", err)
	}
}
