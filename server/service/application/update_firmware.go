package application

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"syscall"
)

var firmwareRebootScheduler = scheduleFirmwareReboot

// installFirmwarePackage intentionally delegates writing to the existing
// kvmcomm updater. The service has already validated the same staged archive;
// the script remains the sole component allowed to select boot media and write
// its partitions.
func installFirmwarePackage(packagePath string) error {
	info, err := os.Stat(packagePath)
	if err != nil {
		return fmt.Errorf("stat staged firmware package: %w", err)
	}
	if !info.Mode().IsRegular() {
		return errors.New("staged firmware package is not a regular file")
	}
	if _, err := os.Stat(FirmwareUpdateScript); err != nil {
		return fmt.Errorf("firmware updater is unavailable: %w", err)
	}

	output := &limitedCommandOutput{limit: 8 << 10}
	cmd := exec.Command(FirmwareUpdateScript, "update", packagePath)
	cmd.Stdout = output
	cmd.Stderr = output
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("firmware update failed: %s", output.String())
	}
	return nil
}

// firmwareRebootCommand is the detached helper that performs the reboot. The
// short delay lets in-flight HTTP status polling observe reboot_scheduled
// before services stop; `reboot -f` is the fallback if systemd refuses.
//
// Boot-slot selection is owned by firmware_update.sh (and kvmcomm.sh on every
// boot); this service must not touch the slot registers or U-Boot env.
var firmwareRebootCommand = []string{
	"/bin/sh", "-c", "sleep 1.5; sync; systemctl reboot || reboot -f",
}

func scheduleFirmwareReboot(string) error {
	cmd := exec.Command(firmwareRebootCommand[0], firmwareRebootCommand[1:]...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("automatic reboot failed: %w", err)
	}
	// Reap the helper; its exit status is irrelevant once the reboot begins.
	go func() { _ = cmd.Wait() }()
	return nil
}

// limitedCommandOutput bounds logs returned to the API while still consuming
// the child process output so the updater cannot block on a full pipe.
type limitedCommandOutput struct {
	buffer bytes.Buffer
	limit  int
}

func (w *limitedCommandOutput) Write(data []byte) (int, error) {
	if w.buffer.Len() < w.limit {
		remaining := w.limit - w.buffer.Len()
		if len(data) > remaining {
			_, _ = w.buffer.Write(data[:remaining])
		} else {
			_, _ = w.buffer.Write(data)
		}
	}
	return len(data), nil
}

func (w *limitedCommandOutput) String() string {
	if w.buffer.Len() == 0 {
		return "command returned no output"
	}
	return w.buffer.String()
}
