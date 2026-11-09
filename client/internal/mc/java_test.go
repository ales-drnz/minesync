package mc

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestRequiredMajor(t *testing.T) {
	cases := map[string]int{
		"1.7.10": 8,
		"1.12.2": 8,
		"1.16.5": 8,
		// Mojang per la 1.17 chiedeva Java 16, ma è EOL e non ce l'ha
		// praticamente nessuno: consigliare il 17, che la esegue senza
		// problemi, evita di mandare tutti sul java del PATH
		"1.17":    17,
		"1.17.1":  17,
		"1.18.2":  17,
		"1.19.4":  17,
		"1.20":    17,
		"1.20.1":  17, // il caso dell'utente
		"1.20.4":  17,
		"1.20.5":  21,
		"1.20.6":  21,
		"1.21":    21,
		"1.21.4":  21,
		"":        0, // ignota
		"garbage": 0,
		"2.0":     0, // non 1.x
	}
	for v, want := range cases {
		if got := RequiredMajor(v); got != want {
			t.Errorf("RequiredMajor(%q) = %d, atteso %d", v, got, want)
		}
	}
}

func TestMajorOf(t *testing.T) {
	cases := map[string]int{
		"1.8.0_501":   8,
		"17.0.9":      17,
		"21":          21,
		"21.0.1+12":   21,
		"11.0.20.1":   11,
		"24-ea":       24, // early access: prima veniva scartato (R14)
		"25-ea+3":     25,
		"1.8.0-ea":    8,
		"17-internal": 17,
		"":            0,
		"garbage":     0,
	}
	for v, want := range cases {
		if got := majorOf(v); got != want {
			t.Errorf("majorOf(%q) = %d, atteso %d", v, got, want)
		}
	}
}

func TestIsInside(t *testing.T) {
	dir := t.TempDir()
	cases := map[string]bool{
		filepath.Join(dir, "jre", "bin", "java"): true,
		dir:                                      true,
		filepath.Join(dir, "..", "altro"):        false,
		filepath.Join(dir+"x", "java"):           false,
		"":                                       false,
	}
	for p, want := range cases {
		if got := IsInside(p, dir); got != want {
			t.Errorf("IsInside(%q) = %v, atteso %v", p, got, want)
		}
	}
}

// fakeJava scrive uno script "java" che lascia una traccia se viene eseguito.
func fakeJava(t *testing.T, path, marker string) {
	t.Helper()
	os.MkdirAll(filepath.Dir(path), 0o755)
	os.WriteFile(path, []byte("#!/bin/sh\ntouch "+marker+"\n"), 0o755)
}

// S7: un java dentro la cartella sincronizzata (scelto a mano o incluso nel
// pack) non va eseguito prima del Play.
func TestPreviewJavaDoesNotExecuteSyncedJava(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("script sh")
	}
	marker := filepath.Join(t.TempDir(), "eseguito")
	noDetect := func() []JavaInfo { t.Fatal("rilevamento di sistema inutile"); return nil }

	t.Run("scelto a mano", func(t *testing.T) {
		dir := t.TempDir()
		java := filepath.Join(dir, "tools", "bin", "java")
		fakeJava(t, java, marker)
		j, _ := PreviewJava(ServerInfo{Dir: dir}, java, noDetect)
		if !j.Found || !j.Unverified || j.Path != java {
			t.Fatalf("atteso java presente ma non verificato: %+v", j)
		}
	})
	t.Run("incluso nel pack", func(t *testing.T) {
		dir := t.TempDir()
		java := filepath.Join(dir, "jre", "bin", "java")
		fakeJava(t, java, marker)
		j, _ := PreviewJava(ServerInfo{Dir: dir}, "", noDetect)
		if !j.Found || !j.Unverified || j.Path != java {
			t.Fatalf("atteso il runtime del pack, non verificato: %+v", j)
		}
	})
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("un java della cartella sincronizzata è stato eseguito")
	}
}

func TestPreviewJavaUsesDetectedList(t *testing.T) {
	j17 := JavaInfo{Found: true, Path: "/x/java17", Version: "17.0.9", Major: 17, Bits: 64}
	j21 := JavaInfo{Found: true, Path: "/x/java21", Version: "21", Major: 21, Bits: 64}
	j, req := PreviewJava(ServerInfo{Dir: t.TempDir(), MCVersion: "1.20.1"}, "", func() []JavaInfo {
		return []JavaInfo{j21, j17}
	})
	if req != 17 || j != j17 {
		t.Fatalf("got %+v req %d", j, req)
	}
}

func TestDetectMCVersion(t *testing.T) {
	mklib := func(t *testing.T, rel string) string {
		dir := t.TempDir()
		full := filepath.Join(dir, filepath.FromSlash(rel))
		if err := os.MkdirAll(full, 0o755); err != nil {
			t.Fatal(err)
		}
		return dir
	}

	t.Run("forge", func(t *testing.T) {
		dir := mklib(t, "libraries/net/minecraftforge/forge/1.20.1-47.4.0")
		if got := detectMCVersion(listRoot(dir), "forge"); got != "1.20.1" {
			t.Errorf("forge: got %q, atteso 1.20.1", got)
		}
	})
	t.Run("neoforge", func(t *testing.T) {
		dir := mklib(t, "libraries/net/neoforged/neoforge/20.4.190")
		if got := detectMCVersion(listRoot(dir), "neoforge"); got != "1.20.4" {
			t.Errorf("neoforge: got %q, atteso 1.20.4", got)
		}
	})
	t.Run("fabric", func(t *testing.T) {
		dir := mklib(t, "libraries/net/fabricmc/intermediary/1.21.1")
		if got := detectMCVersion(listRoot(dir), "fabric"); got != "1.21.1" {
			t.Errorf("fabric: got %q, atteso 1.21.1", got)
		}
	})
	t.Run("ignota", func(t *testing.T) {
		if got := detectMCVersion(listRoot(t.TempDir()), "forge"); got != "" {
			t.Errorf("senza librerie: got %q, atteso vuoto", got)
		}
	})
}
