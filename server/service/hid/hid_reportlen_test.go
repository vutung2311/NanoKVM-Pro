package hid

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDetectLegacyReportLengths(t *testing.T) {
	dir := t.TempDir()
	saved := gadgetFunctionsDir
	gadgetFunctionsDir = dir
	defer func() { gadgetFunctionsDir = saved }()

	write := func(fn, v string) {
		if err := os.MkdirAll(filepath.Join(dir, fn), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, fn, "report_length"), []byte(v), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	write("hid.GS1", "4\n")
	write("hid.GS2", "6\n")
	h := &Hid{}
	h.detectLegacyReportLengths()
	if !h.legacyHid1 || !h.legacyHid2 {
		t.Fatalf("legacy gadget not detected: hid1=%v hid2=%v", h.legacyHid1, h.legacyHid2)
	}

	write("hid.GS1", "5\n")
	write("hid.GS2", "7\n")
	h = &Hid{}
	h.detectLegacyReportLengths()
	if h.legacyHid1 || h.legacyHid2 {
		t.Fatalf("current gadget flagged as legacy: hid1=%v hid2=%v", h.legacyHid1, h.legacyHid2)
	}

	gadgetFunctionsDir = filepath.Join(dir, "missing")
	h = &Hid{}
	h.detectLegacyReportLengths()
	if h.legacyHid1 || h.legacyHid2 {
		t.Fatal("missing configfs must not set legacy flags")
	}
}
