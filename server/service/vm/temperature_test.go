package vm

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReadTemperature(t *testing.T) {
	tests := []struct {
		name    string
		content string
		want    float64
		wantErr bool
	}{
		{name: "sysfs value with newline", content: "48213\n", want: 48.2},
		{name: "rounds to nearest tenth", content: "48250", want: 48.3},
		{name: "below zero", content: "-5040\n", want: -5},
		{name: "empty", content: "", wantErr: true},
		{name: "not a number", content: "n/a\n", wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "temp")
			if err := os.WriteFile(path, []byte(tt.content), 0o644); err != nil {
				t.Fatal(err)
			}

			got, err := readTemperature(path)
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if !tt.wantErr && got != tt.want {
				t.Fatalf("got %v, want %v", got, tt.want)
			}
		})
	}
}

func TestReadTemperature_MissingSensor(t *testing.T) {
	if _, err := readTemperature(filepath.Join(t.TempDir(), "absent")); err == nil {
		t.Fatal("expected an error for a missing thermal zone")
	}
}
