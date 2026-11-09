package syncx

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"math/rand"
	"os"
	"path/filepath"
	"testing"
)

func TestMatcher(t *testing.T) {
	m := NewMatcher([]string{
		"logs/**", "crash-reports/**", "simplebackups/**",
		"session.lock", "*.lock", ".minesync*", "tui/**", "config/*.bak",
	})
	cases := []struct {
		path string
		want bool
	}{
		{"logs/latest.log", true},
		{"logs/sub/deep.log", true},
		{"world/level.dat", false},
		{"world/session.lock", true},
		{"session.lock", true},
		{"world/region/r.0.0.mca", false},
		{"qualcosa.lock", true},
		{"mods/create.jar", false},
		{".minesync-state", true},
		{"tui/bin/tool.exe", true},
		{"config/ars.toml", false},
		{"config/ars.bak", true},
		{"crash-reports/crash-2024.txt", true},
		{"logsx/file.txt", false}, // prefisso simile ma cartella diversa
	}
	for _, c := range cases {
		if got := m.Match(c.path); got != c.want {
			t.Errorf("Match(%q) = %v, atteso %v", c.path, got, c.want)
		}
	}
	if !m.MatchDir("logs") || m.MatchDir("world") {
		t.Error("MatchDir sbagliato per logs/world")
	}
}

// chunkBytes spezza un buffer come farebbe HashAndChunkFile (per i test).
func chunkBytes(t *testing.T, data []byte) (string, []int64, []string) {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "f")
	if err := os.WriteFile(p, data, 0o644); err != nil {
		t.Fatal(err)
	}
	whole, chunks, err := HashAndChunkFile(p, int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	var sizes []int64
	var hashes []string
	for _, c := range chunks {
		sizes = append(sizes, c.Size)
		hashes = append(hashes, c.Hash)
	}
	return whole, sizes, hashes
}

func TestChunkerDeterministicAndBounded(t *testing.T) {
	rnd := rand.New(rand.NewSource(42))
	data := make([]byte, 9<<20) // 9 MiB casuali
	rnd.Read(data)

	whole, sizes, hashes := chunkBytes(t, data)
	wh := sha256.Sum256(data)
	if whole != hex.EncodeToString(wh[:]) {
		t.Fatal("hash intero sbagliato")
	}
	if len(sizes) < 3 {
		t.Fatalf("9 MiB in %d chunk: taglio non avvenuto", len(sizes))
	}
	var sum int64
	for i, s := range sizes {
		sum += s
		last := i == len(sizes)-1
		if s > chunkMax || (!last && s < chunkMin) {
			t.Fatalf("chunk %d fuori dai limiti: %d", i, s)
		}
	}
	if sum != int64(len(data)) {
		t.Fatalf("i chunk non coprono il file: %d ≠ %d", sum, len(data))
	}
	// determinismo: stesso contenuto → stessi chunk
	_, sizes2, hashes2 := chunkBytes(t, data)
	if len(sizes2) != len(sizes) || hashes2[0] != hashes[0] {
		t.Fatal("chunking non deterministico")
	}
	// verifica per-chunk: ogni hash corrisponde alla sezione giusta
	off := int64(0)
	for i, s := range sizes {
		ch := sha256.Sum256(data[off : off+s])
		if hashes[i] != hex.EncodeToString(ch[:]) {
			t.Fatalf("hash del chunk %d non corrisponde alla sezione", i)
		}
		off += s
	}
}

// La proprietà chiave del CDC: una modifica locale invalida pochi chunk,
// il resto resta identico (ed è quello che il delta sync non ritrasferisce).
func TestChunkerLocalChangeLocalEffect(t *testing.T) {
	rnd := rand.New(rand.NewSource(7))
	data := make([]byte, 8<<20)
	rnd.Read(data)
	_, _, before := chunkBytes(t, data)

	changed := bytes.Clone(data)
	copy(changed[5<<20:], []byte("modifica nel mezzo del region file")) // ~5 MiB
	_, _, after := chunkBytes(t, changed)

	beforeSet := map[string]bool{}
	for _, h := range before {
		beforeSet[h] = true
	}
	reused := 0
	for _, h := range after {
		if beforeSet[h] {
			reused++
		}
	}
	if reused == 0 || len(after)-reused > 3 {
		t.Fatalf("modifica locale ha invalidato troppi chunk: %d/%d riusati", reused, len(after))
	}
}

func TestSmallFileNotChunked(t *testing.T) {
	data := bytes.Repeat([]byte("piccolo"), 1000) // ~7 kB
	_, sizes, _ := chunkBytes(t, data)
	if len(sizes) != 0 {
		t.Fatalf("file sotto soglia spezzato in %d chunk", len(sizes))
	}
}

func TestScanCacheReuse(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "world"), 0o755)
	os.WriteFile(filepath.Join(dir, "world", "level.dat"), []byte("dati"), 0o644)
	os.WriteFile(filepath.Join(dir, "server.properties"), []byte("porta"), 0o644)
	os.MkdirAll(filepath.Join(dir, "logs"), 0o755)
	os.WriteFile(filepath.Join(dir, "logs", "latest.log"), []byte("log"), 0o644)

	m := NewMatcher([]string{"logs/**"})
	man, cache, err := Scan(dir, m, Cache{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(man) != 2 {
		t.Fatalf("attesi 2 file, avuti %d: %v", len(man), man)
	}
	if _, ok := man["logs/latest.log"]; ok {
		t.Fatal("file escluso presente nel manifest")
	}

	// seconda scansione: nessun file deve essere ri-hashato
	hashed := 0
	man2, _, err := Scan(dir, m, cache, func(rel string, h bool) {
		if h {
			hashed++
		}
	})
	if err != nil {
		t.Fatal(err)
	}
	if hashed != 0 {
		t.Fatalf("cache ignorata: %d file ri-hashati", hashed)
	}
	if man2["world/level.dat"].Hash != man["world/level.dat"].Hash {
		t.Fatal("hash instabile tra scansioni")
	}
}
