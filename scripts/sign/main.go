// Command sign gestisce la chiave ed25519 che firma gli aggiornamenti del
// client. Il client verifica SHA256SUMS.sig con la chiave pubblica
// incorporata a build time (-X minesync/client/internal/selfupdate.PublicKey).
//
//	sign keygen <file.key>          genera una chiave e stampa la pubblica
//	sign pubkey <file.key>          stampa la chiave pubblica (base64)
//	sign sums <dir>                 scrive <dir>/SHA256SUMS dei binari minesync-*
//	sign sign <file.key> <file>     scrive <file>.sig (firma base64)
//
// Il file .key contiene il seed privato (32 byte) in base64: tenerlo fuori
// dal repository (in CI va in un secret).
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "sign:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		return errors.New("uso: sign keygen|pubkey|sums|sign <argomenti>")
	}
	switch args[0] {
	case "keygen":
		if len(args) != 2 {
			return errors.New("uso: sign keygen <file.key>")
		}
		return keygen(args[1])
	case "pubkey":
		if len(args) != 2 {
			return errors.New("uso: sign pubkey <file.key>")
		}
		priv, err := loadKey(args[1])
		if err != nil {
			return err
		}
		fmt.Println(base64.StdEncoding.EncodeToString(priv.Public().(ed25519.PublicKey)))
		return nil
	case "sums":
		if len(args) != 2 {
			return errors.New("uso: sign sums <dir>")
		}
		return sums(args[1])
	case "sign":
		if len(args) != 3 {
			return errors.New("uso: sign sign <file.key> <file>")
		}
		return signFile(args[1], args[2])
	}
	return fmt.Errorf("comando sconosciuto: %s", args[0])
}

func keygen(path string) error {
	if _, err := os.Stat(path); err == nil {
		return fmt.Errorf("%s esiste già: non la sovrascrivo", path)
	}
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	seed := base64.StdEncoding.EncodeToString(priv.Seed())
	if err := os.WriteFile(path, []byte(seed+"\n"), 0o600); err != nil {
		return err
	}
	fmt.Println(base64.StdEncoding.EncodeToString(priv.Public().(ed25519.PublicKey)))
	return nil
}

func loadKey(path string) (ed25519.PrivateKey, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	seed, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(b)))
	if err != nil || len(seed) != ed25519.SeedSize {
		return nil, fmt.Errorf("%s: chiave non valida (atteso seed ed25519 in base64)", path)
	}
	return ed25519.NewKeyFromSeed(seed), nil
}

func sums(dir string) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	var names []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasPrefix(e.Name(), "minesync-") {
			names = append(names, e.Name())
		}
	}
	if len(names) == 0 {
		return fmt.Errorf("nessun binario minesync-* in %s", dir)
	}
	sort.Strings(names)
	var b strings.Builder
	for _, n := range names {
		h, err := hashFile(filepath.Join(dir, n))
		if err != nil {
			return err
		}
		fmt.Fprintf(&b, "%s  %s\n", h, n)
	}
	return os.WriteFile(filepath.Join(dir, "SHA256SUMS"), []byte(b.String()), 0o644)
}

func hashFile(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func signFile(keyPath, path string) error {
	priv, err := loadKey(keyPath)
	if err != nil {
		return err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	sig := base64.StdEncoding.EncodeToString(ed25519.Sign(priv, data))
	return os.WriteFile(path+".sig", []byte(sig+"\n"), 0o644)
}
