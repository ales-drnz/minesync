package mc

import (
	"os"
	"path/filepath"
	"testing"
)

// Una cartella appena collegata e mai scaricata è vuota: la UI deve dirlo
// invece di segnalare script e Java "mancanti".
func TestInspectCartellaVuota(t *testing.T) {
	dir := t.TempDir()
	if info := Inspect(dir); !info.Empty || info.LaunchLabel() != "?" {
		t.Fatalf("cartella vuota: Empty=%v label=%q", info.Empty, info.LaunchLabel())
	}
	if err := os.WriteFile(filepath.Join(dir, "start.sh"), []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	info := Inspect(dir)
	if info.Empty || info.LaunchLabel() != "start.sh" {
		t.Fatalf("con start.sh: Empty=%v label=%q", info.Empty, info.LaunchLabel())
	}
}
