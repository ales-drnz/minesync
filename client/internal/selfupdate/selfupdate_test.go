package selfupdate

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const testAsset = "minesync-linux-amd64"

// fakeELF genera un "binario" ELF poco più grande della soglia minima.
func fakeELF(tag string) []byte {
	b := make([]byte, minBinarySize+4096)
	copy(b, "\x7fELF")
	copy(b[16:], tag)
	return b
}

func sumsFor(name string, bin []byte) []byte {
	h := sha256.Sum256(bin)
	return []byte(hex.EncodeToString(h[:]) + "  " + name + "\n" +
		strings.Repeat("0", 64) + "  minesync-windows-amd64.exe\n")
}

// hubFiles serve i file indicati sotto /dl/ (404 per gli altri).
func hubFiles(t *testing.T, files map[string][]byte) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, ok := files[strings.TrimPrefix(r.URL.Path, "/dl/")]
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Write(b)
	}))
	t.Cleanup(srv.Close)
	return srv
}

type fixture struct {
	pub   string
	priv  ed25519.PrivateKey
	bin   []byte
	files map[string][]byte
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	bin := fakeELF("NUOVO")
	sums := sumsFor(testAsset, bin)
	sig := base64.StdEncoding.EncodeToString(ed25519.Sign(priv, sums)) + "\n"
	return &fixture{
		pub: base64.StdEncoding.EncodeToString(pub), priv: priv, bin: bin,
		files: map[string][]byte{testAsset: bin, "SHA256SUMS": sums, "SHA256SUMS.sig": []byte(sig)},
	}
}

func (f *fixture) run(t *testing.T, mutate func(u *updater)) (exe string, err error) {
	t.Helper()
	srv := hubFiles(t, f.files)
	exe = filepath.Join(t.TempDir(), "minesync")
	if werr := os.WriteFile(exe, []byte("BINARIO VECCHIO"), 0o755); werr != nil {
		t.Fatal(werr)
	}
	u := updater{
		base: srv.URL + "/dl/", asset: testAsset, goos: "linux",
		pubKey: f.pub, current: "3.0.0", hub: "3.0.1", client: srv.Client(),
	}
	if mutate != nil {
		mutate(&u)
	}
	return exe, u.applyTo(context.Background(), exe)
}

func assertUntouched(t *testing.T, exe string) {
	t.Helper()
	got, _ := os.ReadFile(exe)
	if string(got) != "BINARIO VECCHIO" {
		t.Fatalf("exe modificato nonostante l'errore")
	}
	if _, err := os.Stat(exe + ".new"); err == nil {
		t.Fatal("residuo .new non rimosso")
	}
}

func TestApplyGoodSignature(t *testing.T) {
	f := newFixture(t)
	exe, err := f.run(t, nil)
	if err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(exe)
	if !bytes.Equal(got, f.bin) {
		t.Fatal("exe non sostituito")
	}
	if old, err := os.ReadFile(exe + ".old"); err != nil || string(old) != "BINARIO VECCHIO" {
		t.Fatalf("backup .old mancante o sbagliato: %v", err)
	}
	// .old resta finché la nuova versione non ha dimostrato di funzionare
	cleanupOld(exe)
	if _, err := os.Stat(exe + ".old"); !os.IsNotExist(err) {
		t.Fatal("CleanupOld non ha rimosso .old")
	}
}

func TestApplyWithoutKeyNeedsNoSignature(t *testing.T) {
	f := newFixture(t)
	delete(f.files, "SHA256SUMS.sig")
	if _, err := f.run(t, func(u *updater) { u.pubKey = "" }); err != nil {
		t.Fatal(err)
	}
}

func TestApplyBadSignature(t *testing.T) {
	f := newFixture(t)
	other := sumsFor(testAsset, fakeELF("ALTRO"))
	f.files["SHA256SUMS.sig"] = []byte(base64.StdEncoding.EncodeToString(ed25519.Sign(f.priv, other)))
	exe, err := f.run(t, nil)
	if err == nil || !strings.Contains(err.Error(), "firma") {
		t.Fatalf("atteso errore di firma, got %v", err)
	}
	assertUntouched(t, exe)
}

func TestApplyMissingSignatureWithKey(t *testing.T) {
	f := newFixture(t)
	delete(f.files, "SHA256SUMS.sig")
	exe, err := f.run(t, nil)
	if err == nil || !strings.Contains(err.Error(), "firma") {
		t.Fatalf("atteso errore di firma mancante, got %v", err)
	}
	assertUntouched(t, exe)
}

func TestApplyHashMismatch(t *testing.T) {
	f := newFixture(t)
	f.files[testAsset] = fakeELF("MANOMESSO") // stessa forma, contenuto diverso
	exe, err := f.run(t, nil)
	if err == nil || !strings.Contains(err.Error(), "SHA-256") {
		t.Fatalf("atteso errore di hash, got %v", err)
	}
	assertUntouched(t, exe)
}

// resign rigenera SHA256SUMS e firma per il binario corrente del fixture.
func (f *fixture) resign() {
	sums := sumsFor(testAsset, f.files[testAsset])
	f.files["SHA256SUMS"] = sums
	f.files["SHA256SUMS.sig"] = []byte(base64.StdEncoding.EncodeToString(ed25519.Sign(f.priv, sums)))
}

func TestApplyWrongMagic(t *testing.T) {
	f := newFixture(t)
	bin := fakeELF("x")
	copy(bin, "MZ\x00\x00") // un exe Windows servito a Linux
	f.files[testAsset] = bin
	f.resign()
	exe, err := f.run(t, nil)
	if err == nil || !strings.Contains(err.Error(), "eseguibile") {
		t.Fatalf("atteso errore di magic, got %v", err)
	}
	assertUntouched(t, exe)
}

func TestApplyTooSmall(t *testing.T) {
	f := newFixture(t)
	f.files[testAsset] = []byte("\x7fELF piccolo")
	f.resign()
	exe, err := f.run(t, nil)
	if err == nil || !strings.Contains(err.Error(), "piccolo") {
		t.Fatalf("atteso errore di dimensione, got %v", err)
	}
	assertUntouched(t, exe)
}

func TestApplyRefusesDowngradeAndDev(t *testing.T) {
	f := newFixture(t)
	for _, c := range []struct{ cur, hub string }{
		{"3.0.0", "2.9.9"}, // downgrade
		{"3.0.0", "3.0.0"}, // stessa versione
		{"dev", "9.9.9"},   // build locale: mai auto-update
		{"3.0.0", "dev"},   // hub di sviluppo
	} {
		exe, err := f.run(t, func(u *updater) { u.current, u.hub = c.cur, c.hub })
		if !errors.Is(err, ErrNotNewer) {
			t.Errorf("client %s / hub %s: atteso ErrNotNewer, got %v", c.cur, c.hub, err)
		}
		assertUntouched(t, exe)
	}
}

func TestApply404LeavesBinaryIntact(t *testing.T) {
	f := newFixture(t)
	delete(f.files, testAsset)
	exe, err := f.run(t, nil)
	if err == nil {
		t.Fatal("atteso errore su 404")
	}
	assertUntouched(t, exe)
}

// Caso Windows: il vecchio .old è ancora in esecuzione e non si può
// cancellare (qui simulato con una cartella non vuota): il backup prende un
// nome univoco e l'update va a buon fine lo stesso.
func TestApplyOldBusy(t *testing.T) {
	f := newFixture(t)
	srv := hubFiles(t, f.files)
	dir := t.TempDir()
	exe := filepath.Join(dir, "minesync")
	os.WriteFile(exe, []byte("BINARIO VECCHIO"), 0o755)
	os.MkdirAll(filepath.Join(exe+".old", "busy"), 0o755)
	u := updater{base: srv.URL + "/dl/", asset: testAsset, goos: "linux",
		pubKey: f.pub, current: "3.0.0", hub: "3.0.1", client: srv.Client()}
	if err := u.applyTo(context.Background(), exe); err != nil {
		t.Fatal(err)
	}
	matches, _ := filepath.Glob(exe + ".old-*")
	if len(matches) != 1 {
		t.Fatalf("atteso un backup .old-<ts>, trovati %v", matches)
	}
	cleanupOld(exe)
	if _, err := os.Stat(matches[0]); !os.IsNotExist(err) {
		t.Fatal("CleanupOld non ha rimosso .old-<ts>")
	}
}

func TestCheckMagic(t *testing.T) {
	dir := t.TempDir()
	cases := []struct {
		goos string
		head string
		ok   bool
	}{
		{"linux", "\x7fELF", true},
		{"linux", "MZ\x90\x00", false},
		{"windows", "MZ\x90\x00", true},
		{"windows", "\x7fELF", false},
		{"darwin", "\xcf\xfa\xed\xfe", true},
		{"darwin", "\xca\xfe\xba\xbe", true},
		{"darwin", "\x7fELF", false},
	}
	for i, c := range cases {
		p := filepath.Join(dir, "f"+string(rune('a'+i)))
		os.WriteFile(p, []byte(c.head+"resto"), 0o644)
		if err := checkMagic(p, c.goos); (err == nil) != c.ok {
			t.Errorf("%s %q: err=%v, atteso ok=%v", c.goos, c.head, err, c.ok)
		}
	}
}

func TestTargetExeStripsOld(t *testing.T) {
	for in, want := range map[string]string{
		"/a/minesync.old":         "/a/minesync",
		"/a/minesync.exe.old-123": "/a/minesync.exe",
		"/a/minesync":             "/a/minesync",
		"/a/minesync.older":       "/a/minesync.older",
	} {
		if got := oldSuffixRe.ReplaceAllString(in, ""); got != want {
			t.Errorf("%s → %s, atteso %s", in, got, want)
		}
	}
}
