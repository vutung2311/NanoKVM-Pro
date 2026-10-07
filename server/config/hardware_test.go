package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDeviceNumber(t *testing.T) {
	tmpDir := t.TempDir()

	// Backup original slice and restore
	origFiles := DeviceNumberFiles
	defer func() {
		DeviceNumberFiles = origFiles
	}()

	t.Run("returns canonical fallback when no files exist", func(t *testing.T) {
		DeviceNumberFiles = []string{filepath.Join(tmpDir, "nonexistent")}
		pn := DeviceNumber()
		if pn != DefaultDeskDeviceNumber {
			t.Fatalf("expected %q, got %q", DefaultDeskDeviceNumber, pn)
		}
	})

	t.Run("reads from override file when present", func(t *testing.T) {
		overrideFile := filepath.Join(tmpDir, "device_number")
		if err := os.WriteFile(overrideFile, []byte("NebE99999\n"), 0644); err != nil {
			t.Fatal(err)
		}
		DeviceNumberFiles = []string{overrideFile}

		pn := DeviceNumber()
		if pn != "NebE99999" {
			t.Fatalf("expected 'NebE99999', got %q", pn)
		}
	})

	t.Run("ignores unknown in override file and falls back", func(t *testing.T) {
		overrideFile := filepath.Join(tmpDir, "device_number_unknown")
		if err := os.WriteFile(overrideFile, []byte("unknown\n"), 0644); err != nil {
			t.Fatal(err)
		}
		DeviceNumberFiles = []string{overrideFile}

		pn := DeviceNumber()
		if pn != DefaultDeskDeviceNumber {
			t.Fatalf("expected %q, got %q", DefaultDeskDeviceNumber, pn)
		}
	})
}

func TestGetHwVersion(t *testing.T) {
	tmpDir := t.TempDir()

	origModelFiles := HWModelFiles
	defer func() {
		HWModelFiles = origModelFiles
	}()

	t.Run("defaults to Desk when no config exists", func(t *testing.T) {
		HWModelFiles = []string{filepath.Join(tmpDir, "nonexistent")}
		ver := GetHwVersion()
		if ver != HWVersionDesk {
			t.Fatalf("expected HWVersionDesk, got %v", ver)
		}
	})

	t.Run("detects ATX from model file", func(t *testing.T) {
		modelFile := filepath.Join(tmpDir, "model_atx")
		if err := os.WriteFile(modelFile, []byte("ATX\n"), 0644); err != nil {
			t.Fatal(err)
		}
		HWModelFiles = []string{modelFile}

		ver := GetHwVersion()
		if ver != HWVersionATX {
			t.Fatalf("expected HWVersionATX, got %v", ver)
		}
	})
}
