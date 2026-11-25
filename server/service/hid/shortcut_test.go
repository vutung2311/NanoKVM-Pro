package hid

import (
	"path/filepath"
	"testing"

	"NanoKVM-Server/proto"
)

func TestShortcutTagPersistence(t *testing.T) {
	origFile := shortcutFile
	shortcutFile = filepath.Join(t.TempDir(), "shortcuts.json")
	defer func() {
		shortcutFile = origFile
	}()

	keys := []proto.ShortcutKey{
		{Code: "ControlLeft", Label: "Ctrl"},
		{Code: "ShiftLeft", Label: "Shift"},
		{Code: "KeyV", Label: "V"},
	}

	created, err := addShortcut(keys, "paste")
	if err != nil {
		t.Fatalf("addShortcut failed: %v", err)
	}
	if created.Tag != "paste" {
		t.Fatalf("expected tag 'paste', got %q", created.Tag)
	}

	shortcuts, err := listShortcuts()
	if err != nil {
		t.Fatalf("listShortcuts failed: %v", err)
	}
	if len(shortcuts) != 1 {
		t.Fatalf("expected 1 shortcut, got %d", len(shortcuts))
	}
	if shortcuts[0].Tag != "paste" {
		t.Fatalf("expected loaded shortcut tag 'paste', got %q", shortcuts[0].Tag)
	}
	if len(shortcuts[0].Keys) != 3 {
		t.Fatalf("expected 3 keys, got %d", len(shortcuts[0].Keys))
	}

	if err := deleteShortcut(created.ID); err != nil {
		t.Fatalf("deleteShortcut failed: %v", err)
	}

	shortcuts, err = listShortcuts()
	if err != nil {
		t.Fatalf("listShortcuts after delete failed: %v", err)
	}
	if len(shortcuts) != 0 {
		t.Fatalf("expected 0 shortcuts after delete, got %d", len(shortcuts))
	}
}
