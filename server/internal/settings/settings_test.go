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

func TestParseTopic(t *testing.T) {
	const chat = "-1001234567890"
	for _, c := range []struct {
		in, chat string
		want     int64
		err      string // "" ok, "invalid", "chat"
	}{
		{"", chat, 0, ""},
		{"  ", chat, 0, ""},
		{"5", chat, 5, ""},
		{" 42 ", "", 42, ""},
		{"1", chat, 0, ""}, // Generale: nessun thread id
		{"https://t.me/c/1234567890/5", chat, 5, ""},
		{"https://t.me/c/1234567890/5/120", chat, 5, ""}, // link di un messaggio nel topic
		{"t.me/c/1234567890/77/", chat, 77, ""},
		{"http://telegram.me/c/1234567890/8?single", chat, 8, ""},
		{"https://t.me/c/1234567890/1", chat, 0, ""},
		{"https://t.me/c/1234567890/5", "@amici", 5, ""}, // chat in altra forma: non confrontabile
		{"https://t.me/c/1234567890/5", "", 5, ""},
		{"https://t.me/c/999/5", chat, 0, "chat"},
		{"https://t.me/AmiciMC/12", "@amicimc", 12, ""},
		{"https://t.me/AmiciMC/12/345", chat, 12, ""},
		{"https://t.me/altrogruppo/12", "@amicimc", 0, "chat"},
		{"0", chat, 0, "invalid"},
		{"-3", chat, 0, "invalid"},
		{"5.5", chat, 0, "invalid"},
		{"abc", chat, 0, "invalid"},
		{"https://example.com/c/1234567890/5", chat, 0, "invalid"},
		{"https://t.me/c/1234567890", chat, 0, "invalid"},
		{"https://t.me/AmiciMC", chat, 0, "invalid"},
		{"https://t.me/c/1234567890/0", chat, 0, "invalid"},
		{"99999999999999999999", chat, 0, "invalid"}, // oltre int64
	} {
		got, err := ParseTopic(c.in, c.chat)
		var ce *TopicChatError
		switch {
		case c.err == "" && err != nil:
			t.Errorf("ParseTopic(%q, %q): errore %v", c.in, c.chat, err)
		case c.err == "invalid" && !errors.Is(err, ErrTopicInvalid):
			t.Errorf("ParseTopic(%q, %q): atteso ErrTopicInvalid, %v", c.in, c.chat, err)
		case c.err == "chat" && !errors.As(err, &ce):
			t.Errorf("ParseTopic(%q, %q): atteso TopicChatError, %v", c.in, c.chat, err)
		case got != c.want:
			t.Errorf("ParseTopic(%q, %q) = %d, atteso %d", c.in, c.chat, got, c.want)
		}
	}
	_, err := ParseTopic("https://t.me/c/999/5", chat)
	if ce := (*TopicChatError)(nil); !errors.As(err, &ce) || ce.Chat != "-100999" {
		t.Errorf("chat del link: %v", err)
	}
}

// La mappa dei topic restituita è una copia: modificarla non tocca lo store.
func TestTopicsCopia(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.UpdateTelegram(func(tg *Telegram) error {
		tg.Topics = map[string]int64{"a": 5}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	tg, _ := s.Telegram()
	tg.Topics["a"] = 9
	if _, err := s.UpdateTelegram(func(tg *Telegram) error {
		tg.Topics["a"] = 1 // rifiutato dalla validazione: niente deve cambiare
		return nil
	}); err == nil || !errors.Is(err, store.ErrBadRequest) {
		t.Fatalf("topic 1: %v", err)
	}
	if tg, _ := s.Telegram(); tg.Topics["a"] != 5 {
		t.Fatalf("topics = %v", tg.Topics)
	}
	s2, err := Open(filepath.Dir(s.path))
	if err != nil {
		t.Fatal(err)
	}
	if tg, _ := s2.Telegram(); tg.Topics["a"] != 5 {
		t.Fatalf("riletti: %v", tg.Topics)
	}
}
