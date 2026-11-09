package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestKeygenSumsSignRoundTrip(t *testing.T) {
	dir := t.TempDir()
	key := filepath.Join(dir, "k.key")
	if err := keygen(key); err != nil {
		t.Fatal(err)
	}
	if err := keygen(key); err == nil {
		t.Fatal("keygen deve rifiutarsi di sovrascrivere una chiave")
	}
	bin := filepath.Join(dir, "bin")
	os.Mkdir(bin, 0o755)
	os.WriteFile(filepath.Join(bin, "minesync-linux-amd64"), []byte("ciao"), 0o755)
	os.WriteFile(filepath.Join(bin, "altro"), []byte("x"), 0o644)
	if err := sums(bin); err != nil {
		t.Fatal(err)
	}
	s, _ := os.ReadFile(filepath.Join(bin, "SHA256SUMS"))
	want := "b133a0c0e9bee3be20163d2ad31d6248db292aa6dcb1ee087a2aa50e0fc75ae2  minesync-linux-amd64\n"
	if string(s) != want {
		t.Fatalf("SHA256SUMS = %q", s)
	}
	if err := signFile(key, filepath.Join(bin, "SHA256SUMS")); err != nil {
		t.Fatal(err)
	}
	sigB, _ := os.ReadFile(filepath.Join(bin, "SHA256SUMS.sig"))
	sig, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(sigB)))
	if err != nil {
		t.Fatal(err)
	}
	priv, _ := loadKey(key)
	if !ed25519.Verify(priv.Public().(ed25519.PublicKey), s, sig) {
		t.Fatal("firma non valida")
	}
}
