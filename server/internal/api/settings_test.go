package api

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"minesync/server/internal/i18n"
	"minesync/server/internal/notify"
)

// fakeBot finge il bot: registra le prove e restituisce err.
type fakeBot struct {
	mu     sync.Mutex
	tests  []notify.Config
	spaces []string // server della prova ("" = prova generale)
	err    error
}

func (f *fakeBot) Test(_ context.Context, c notify.Config, space string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.tests = append(f.tests, c)
	f.spaces = append(f.spaces, space)
	return f.err
}

func (f *fakeBot) Status() notify.Status { return notify.Status{} }

const tgToken = "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawQ"

type tgView struct {
	Enabled   bool             `json:"enabled"`
	TokenSet  bool             `json:"tokenSet"`
	TokenHint string           `json:"tokenHint"`
	ChatID    string           `json:"chatId"`
	Lang      string           `json:"lang"`
	Notify    map[string]bool  `json:"notify"`
	State     string           `json:"state"`
	Topics    map[string]int64 `json:"topics"`
}

func (h *testHub) tgSettings(opts ...reqOpt) tgView {
	h.t.Helper()
	w := h.do("GET", "/api/v1/settings", nil, append([]reqOpt{from(ipAdmin)}, opts...)...)
	if w.Code != 200 {
		h.t.Fatalf("GET settings: %d %s", w.Code, w.Body.String())
	}
	if strings.Contains(w.Body.String(), "AAHdq") {
		h.t.Fatalf("token nella risposta: %s", w.Body.String())
	}
	return decodeJSON[map[string]tgView](h.t, w)["telegram"]
}

func TestSettingsSoloAdmin(t *testing.T) {
	h := newHub(t)
	for _, c := range []struct{ method, path string }{
		{"GET", "/api/v1/settings"},
		{"PUT", "/api/v1/settings/telegram"},
		{"POST", "/api/v1/settings/telegram/test"},
	} {
		if w := h.do(c.method, c.path, jsonBody(map[string]any{})); w.Code != 403 {
			t.Errorf("%s %s da membro: %d", c.method, c.path, w.Code)
		}
	}
	// mutazione senza X-MineSync: la guardia vale anche qui
	if w := h.do("PUT", "/api/v1/settings/telegram", jsonBody(map[string]any{}), from(ipAdmin), noMineSyncHeader()); w.Code != 403 {
		t.Errorf("PUT senza header: %d", w.Code)
	}
}

func TestSettingsTelegram(t *testing.T) {
	h := newHub(t)
	v := h.tgSettings()
	if v.Enabled || v.TokenSet || v.State != "disabled" || !v.Notify["open"] || !v.Notify["status"] {
		t.Fatalf("default: %+v", v)
	}

	put := func(body map[string]any, opts ...reqOpt) (int, string) {
		w := h.do("PUT", "/api/v1/settings/telegram", jsonBody(body), append([]reqOpt{from(ipAdmin)}, opts...)...)
		if strings.Contains(w.Body.String(), "AAHdq") {
			t.Fatalf("token nella risposta: %s", w.Body.String())
		}
		return w.Code, w.Body.String()
	}
	// attivare senza token: 400 localizzato
	if code, body := put(map[string]any{"enabled": true, "chatId": "-100999"}, header("Accept-Language", "en")); code != 400 ||
		!strings.Contains(body, "requires a token and a chat id") {
		t.Fatalf("enabled senza token: %d %s", code, body)
	}
	if code, body := put(map[string]any{"chatId": "amici"}); code != 400 || !strings.Contains(body, "chat id non valido") {
		t.Fatalf("chat non valida: %d %s", code, body)
	}
	if code, _ := put(map[string]any{"token": "nonvalido"}); code != 400 {
		t.Fatalf("token non valido: %d", code)
	}

	code, body := put(map[string]any{"enabled": true, "token": tgToken, "chatId": "-100999", "lang": "en",
		"notify": map[string]any{"alerts": false}})
	if code != 200 {
		t.Fatalf("PUT: %d %s", code, body)
	}
	v = h.tgSettings()
	if !v.Enabled || !v.TokenSet || v.TokenHint != "sawQ" || v.ChatID != "-100999" || v.Lang != "en" ||
		v.Notify["alerts"] || !v.Notify["open"] || v.State != "active" {
		t.Fatalf("dopo PUT: %+v", v)
	}
	// token vuoto = invariato; le altre chiavi assenti restano
	put(map[string]any{"token": "", "notify": map[string]any{"status": false}})
	v = h.tgSettings()
	if !v.TokenSet || v.Notify["alerts"] || v.Notify["status"] || !v.Enabled {
		t.Fatalf("modifica parziale: %+v", v)
	}
	// togliere il token a bot attivo è rifiutato; spento sì
	if code, _ := put(map[string]any{"clearToken": true}); code != 400 {
		t.Fatalf("clearToken a bot attivo: %d", code)
	}
	if code, _ := put(map[string]any{"clearToken": true, "enabled": false}); code != 200 {
		t.Fatalf("clearToken: %d", code)
	}
	if v = h.tgSettings(); v.TokenSet || v.Enabled {
		t.Fatalf("dopo clearToken: %+v", v)
	}

	// evento strutturato, senza token
	w := h.do("GET", "/api/v1/events?limit=10", nil, header("Accept-Language", "en"))
	if b := w.Body.String(); !strings.Contains(b, `"type":"settings"`) ||
		!strings.Contains(b, "alex changed the Telegram settings") || strings.Contains(b, "AAHdq") {
		t.Fatalf("eventi: %s", b)
	}
}

func TestSettingsProva(t *testing.T) {
	h := newHub(t)
	bot := h.srv.Telegram.(*fakeBot)
	test := func(body any) (int, string) {
		w := h.do("POST", "/api/v1/settings/telegram/test", jsonBody(body), from(ipAdmin))
		return w.Code, w.Body.String()
	}
	if code, body := test(nil); code != 400 || !strings.Contains(body, "servono token e chat id") {
		t.Fatalf("senza config: %d %s", code, body)
	}
	// config non salvata nel body: si prova senza salvarla
	if code, body := test(map[string]any{"token": tgToken, "chatId": "-100777", "lang": "en"}); code != 200 {
		t.Fatalf("prova: %d %s", code, body)
	}
	if len(bot.tests) != 1 || bot.tests[0].ChatID != "-100777" || bot.tests[0].Lang != i18n.EN {
		t.Fatalf("prova inviata con %+v", bot.tests)
	}
	if v := h.tgSettings(); v.TokenSet {
		t.Fatal("la prova ha salvato il token")
	}
	// rate limit
	if code, _ := test(map[string]any{"token": tgToken, "chatId": "-100777"}); code != 429 {
		t.Fatalf("seconda prova immediata: %d", code)
	}
	// errore di Telegram → 502 col testo dell'errore
	h.srv.lastTest = time.Time{}
	bot.err = i18n.Errorf("telegram ha risposto %s", "401 Unauthorized (Unauthorized)")
	code, body := test(map[string]any{"token": tgToken, "chatId": "-100777"})
	if code != 502 || !strings.Contains(body, "invio non riuscito: telegram ha risposto 401 Unauthorized") {
		t.Fatalf("errore Telegram: %d %s", code, body)
	}
}

func TestSettingsTopics(t *testing.T) {
	h := newHub(t)
	for _, n := range []string{"Mondo A", "Mondo B"} {
		if _, err := h.srv.Store.CreateSpace(n, "minecraft", nil); err != nil {
			t.Fatal(err)
		}
	}
	put := func(body map[string]any, opts ...reqOpt) (int, string) {
		w := h.do("PUT", "/api/v1/settings/telegram", jsonBody(body), append([]reqOpt{from(ipAdmin)}, opts...)...)
		return w.Code, w.Body.String()
	}
	if v := h.tgSettings(); v.Topics == nil || len(v.Topics) != 0 {
		t.Fatalf("topics di default: %#v", v.Topics)
	}
	// numero, link, Generale (1 / vuoto) e server inesistente (ignorato)
	code, body := put(map[string]any{"chatId": "-1001234567890", "topics": map[string]any{
		"mondo-a": "https://t.me/c/1234567890/7", "mondo-b": 9, "fantasma": 3,
	}})
	if code != 200 {
		t.Fatalf("PUT topics: %d %s", code, body)
	}
	if v := h.tgSettings(); len(v.Topics) != 2 || v.Topics["mondo-a"] != 7 || v.Topics["mondo-b"] != 9 {
		t.Fatalf("topics: %v", v.Topics)
	}
	// le altre modifiche non toccano i topic
	put(map[string]any{"lang": "en"})
	if v := h.tgSettings(); len(v.Topics) != 2 {
		t.Fatalf("topics persi: %v", v.Topics)
	}
	// sostituzione completa: mondo-b torna al Generale
	put(map[string]any{"topics": map[string]any{"mondo-a": "7", "mondo-b": ""}})
	if v := h.tgSettings(); len(v.Topics) != 1 || v.Topics["mondo-a"] != 7 {
		t.Fatalf("dopo la sostituzione: %v", v.Topics)
	}
	put(map[string]any{"topics": map[string]any{"mondo-a": 7, "mondo-b": 1}})
	if v := h.tgSettings(); len(v.Topics) != 1 {
		t.Fatalf("1 = Generale: %v", v.Topics)
	}

	// errori localizzati, niente salvato
	if code, body := put(map[string]any{"topics": map[string]any{"mondo-a": "ciao"}}, header("Accept-Language", "en")); code != 400 ||
		!strings.Contains(body, "invalid topic for Mondo A") {
		t.Fatalf("topic non valido: %d %s", code, body)
	}
	if code, body := put(map[string]any{"topics": map[string]any{"mondo-a": -4}}); code != 400 ||
		!strings.Contains(body, "topic di Mondo A non valido") {
		t.Fatalf("topic negativo: %d %s", code, body)
	}
	if code, body := put(map[string]any{"topics": map[string]any{"mondo-b": "https://t.me/c/555/4"}}); code != 400 ||
		!strings.Contains(body, "è di un'altra chat (-100555)") || !strings.Contains(body, "-1001234567890") {
		t.Fatalf("chat diversa: %d %s", code, body)
	}
	// chat e link cambiati insieme: si confronta con la chat nuova
	if code, body := put(map[string]any{"chatId": "-100555", "topics": map[string]any{"mondo-b": "https://t.me/c/555/4"}}); code != 200 {
		t.Fatalf("chat e link nuovi: %d %s", code, body)
	}

	// server eliminato: sparisce dalla GET e dal file al salvataggio successivo
	if err := h.srv.Store.DeleteSpace("mondo-b"); err != nil {
		t.Fatal(err)
	}
	if v := h.tgSettings(); len(v.Topics) != 0 {
		t.Fatalf("topic di un server eliminato: %v", v.Topics)
	}
	put(map[string]any{"lang": "it"})
	if tg, _ := h.srv.Settings.Telegram(); len(tg.Topics) != 0 {
		t.Fatalf("voce non rimossa: %v", tg.Topics)
	}
}

func TestSettingsProvaTopic(t *testing.T) {
	h := newHub(t)
	bot := h.srv.Telegram.(*fakeBot)
	if _, err := h.srv.Store.CreateSpace("Mondo A", "minecraft", nil); err != nil {
		t.Fatal(err)
	}
	h.do("PUT", "/api/v1/settings/telegram", jsonBody(map[string]any{
		"token": tgToken, "chatId": "-1001234567890", "topics": map[string]any{"mondo-a": 7}}), from(ipAdmin))
	test := func(body any) (int, string) {
		h.srv.lastTest = time.Time{}
		w := h.do("POST", "/api/v1/settings/telegram/test", jsonBody(body), from(ipAdmin))
		return w.Code, w.Body.String()
	}
	// topic salvato
	if code, body := test(map[string]any{"spaceId": "mondo-a"}); code != 200 {
		t.Fatalf("prova: %d %s", code, body)
	}
	if last := bot.tests[len(bot.tests)-1]; bot.spaces[len(bot.spaces)-1] != "mondo-a" || last.Topics["mondo-a"] != 7 {
		t.Fatalf("prova con %+v", last)
	}
	// topic del modulo, non salvato
	if code, body := test(map[string]any{"spaceId": "mondo-a", "topic": "https://t.me/c/1234567890/12"}); code != 200 {
		t.Fatalf("prova: %d %s", code, body)
	}
	if last := bot.tests[len(bot.tests)-1]; last.Topics["mondo-a"] != 12 {
		t.Fatalf("prova con %+v", last)
	}
	if tg, _ := h.srv.Settings.Telegram(); tg.Topics["mondo-a"] != 7 {
		t.Fatal("la prova ha salvato il topic")
	}
	if code, _ := test(map[string]any{"spaceId": "mondo-a", "topic": "https://t.me/c/1/12"}); code != 400 {
		t.Fatalf("link di un'altra chat: %d", code)
	}
	if code, _ := test(map[string]any{"spaceId": "nessuno"}); code != 404 {
		t.Fatalf("server inesistente: %d", code)
	}
}
