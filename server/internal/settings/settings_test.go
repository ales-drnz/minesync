package settings

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"minesync/server/internal/store"
)

const goodToken = "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawQ"

func TestSalvaERilegge(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if tg, ok := s.Telegram(); ok || tg.Enabled || !tg.Notify.Open || !tg.Notify.Status {
		t.Fatalf("default: %+v ok=%v", tg, ok)
	}
	ch := s.Subscribe()
	if _, err := s.UpdateTelegram(func(tg *Telegram) error {
		tg.Enabled, tg.Token, tg.ChatID, tg.Lang = true, goodToken, "-1001234567890", "en"
		tg.Notify.Alerts = false
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-ch:
	default:
		t.Fatal("nessun segnale agli iscritti")
	}
	fi, err := os.Stat(filepath.Join(dir, FileName))
	if err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" && fi.Mode().Perm() != 0o600 {
		t.Errorf("permessi %v: il file contiene il token, deve essere 0600", fi.Mode().Perm())
	}
	s2, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	tg, ok := s2.Telegram()
	if !ok || !tg.Enabled || tg.Token != goodToken || tg.ChatID != "-1001234567890" || tg.Lang != "en" ||
		tg.Notify.Alerts || !tg.Notify.Open {
		t.Fatalf("riletto: %+v", tg)
	}
}

// Un file scritto da una versione con meno flag: quelli mancanti valgono il default.
func TestCampiMancantiAlDefault(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, FileName), []byte(`{"telegram":{"enabled":false,"notify":{"open":false}}}`), 0o600)
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	tg, _ := s.Telegram()
	if tg.Notify.Open || !tg.Notify.Close || !tg.Notify.Alerts || !tg.Notify.Status {
		t.Fatalf("flag: %+v", tg.Notify)
	}
}

func TestValidazione(t *testing.T) {
	s, _ := Open(t.TempDir())
	for _, c := range []struct {
		name string
		fn   func(*Telegram)
	}{
		{"attivo senza token", func(tg *Telegram) { tg.Enabled, tg.ChatID = true, "-100" }},
		{"attivo senza chat", func(tg *Telegram) { tg.Enabled, tg.Token = true, goodToken }},
		{"token malformato", func(tg *Telegram) { tg.Token = "abc" }},
		{"chat malformata", func(tg *Telegram) { tg.ChatID = "gruppo amici" }},
		{"lingua", func(tg *Telegram) { tg.Lang = "de" }},
	} {
		_, err := s.UpdateTelegram(func(tg *Telegram) error { c.fn(tg); return nil })
		if !errors.Is(err, store.ErrBadRequest) {
			t.Errorf("%s: err = %v", c.name, err)
		}
	}
	if _, ok := s.Telegram(); ok {
		t.Error("una modifica rifiutata non deve creare la sezione")
	}
	for _, id := range []string{"-1001234567890", "12345", "@miocanale"} {
		if !ValidChatID(id) {
			t.Errorf("chat id %q rifiutato", id)
		}
	}
}

func TestMigrazioneEnv(t *testing.T) {
	dir := t.TempDir()
	s, _ := Open(dir)
	if ok, _ := s.MigrateTelegramEnv(goodToken, ""); ok {
		t.Fatal("senza chat non si importa")
	}
	if ok, err := s.MigrateTelegramEnv(goodToken, "-100999"); !ok || err != nil {
		t.Fatalf("import: %v %v", ok, err)
	}
	tg, _ := s.Telegram()
	if !tg.Enabled || tg.Token != goodToken || tg.ChatID != "-100999" || !tg.Notify.Close {
		t.Fatalf("importato: %+v", tg)
	}
	// una volta sola: dopo, le env non contano più
	s.UpdateTelegram(func(tg *Telegram) error { tg.Enabled = false; return nil })
	s2, _ := Open(dir)
	if ok, _ := s2.MigrateTelegramEnv(goodToken, "-100777"); ok {
		t.Fatal("seconda importazione")
	}
	if tg, _ := s2.Telegram(); tg.Enabled || tg.ChatID != "-100999" {
		t.Fatalf("sovrascritto dalle env: %+v", tg)
	}
}
