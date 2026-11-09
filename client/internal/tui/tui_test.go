package tui

import (
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"minesync/client/internal/api"
	"minesync/client/internal/config"
)

// Smoke test di rendering: le viste non devono panicare e devono
// contenere gli elementi chiave, a varie dimensioni di terminale.

func testApp() *App {
	app := newApp(&config.Config{Spaces: map[string]config.SpaceConfig{"miomondo": {LocalPath: "C:/x"}}})
	app.client = api.New("http://test.invalid")
	app.who = api.Whoami{Name: "alex", Admin: true}
	app.connected = true
	app.latency = 12 * time.Millisecond
	app.width, app.height = 120, 35
	return app
}

func fakeSpaces() []api.Space {
	return []api.Space{
		{ID: "miomondo", Name: "MioMondo", Profile: "minecraft", Head: 42,
			Lock: &api.LockInfo{Owner: "steve", Since: time.Now().Add(-time.Hour), LastBeat: time.Now()}},
		{ID: "archivio", Name: "Archivio", Profile: "generic", Head: 3},
	}
}

func fakeGens() []api.GenSummary {
	return []api.GenSummary{
		{N: 42, Author: "steve", Message: "autosave", TS: time.Now(),
			Stats: api.Stats{Files: 1200, Bytes: 1_300_000_000, Changed: 12}},
		{N: 41, Author: "alex", Message: "stop di alex", TS: time.Now().Add(-2 * time.Hour),
			Stats: api.Stats{Files: 1199, Bytes: 1_299_000_000, Added: 3, Removed: 1}},
		{N: 40, Author: "alex", Restore: 12, TS: time.Now().Add(-3 * time.Hour)},
	}
}

func renderAt(t *testing.T, s screen, w, h int, want ...string) {
	t.Helper()
	out := s.view(w, h)
	for _, sub := range want {
		if !strings.Contains(out, sub) {
			t.Errorf("vista %T (%dx%d): manca %q", s, w, h, sub)
		}
	}
}

func TestHomeView(t *testing.T) {
	app := testApp()
	h := newHome(app)
	h.loaded = true
	h.spaces = fakeSpaces()
	h.events = []api.Event{{TS: time.Now(), Type: "push", Space: "miomondo", Msg: "steve ha pushato la generazione 42"}}
	for _, wh := range [][2]int{{120, 35}, {80, 24}, {200, 50}} {
		renderAt(t, h, wh[0], wh[1], "MioMondo", "steve", "SERVER", "ATTIVITÀ")
	}
}

func TestSpaceView(t *testing.T) {
	app := testApp()
	s := newSpaceScreen(app, "miomondo")
	s.loaded = true
	s.sp = fakeSpaces()[0]
	s.local = "C:/x"
	s.gens = fakeGens()
	renderAt(t, s, 120, 35, "STATO HUB", "COPIA LOCALE", "in gioco: steve", "#42", "STORIA RECENTE")
	// vista sync in corso
	s.syncing = true
	s.syncKind = "pull"
	renderAt(t, s, 120, 35, "TRASFERIMENTO", "pull in corso")
}

func TestHistoryView(t *testing.T) {
	app := testApp()
	hs := newHistory(app, "miomondo")
	hs.loaded = true
	hs.gens = fakeGens()
	hs.head = 42
	renderAt(t, hs, 120, 35, "#42", "HEAD", "autosave", "⟲")
	renderAt(t, hs, 80, 24, "#42")
}

func TestConfirmView(t *testing.T) {
	app := testApp()
	c := newConfirm(app, "Forzare?", "steve sta giocando: perderà i progressi.", "Forza", true, 2, nil)
	renderAt(t, c, 100, 30, "Forzare?", "steve", "Annulla", "Forza")
}

func TestEventMsgCleansPush(t *testing.T) {
	push := api.Event{Type: "push", Msg: "steve-pc ha pushato la generazione 124 — stop di steve-pc (+0 ~78 −2)"}
	if got := eventMsg(push); got != "steve-pc ha pushato la generazione 124" {
		t.Fatalf("coda del salvataggio non rimossa: %q", got)
	}
	// gli altri tipi di evento restano intatti
	unlock := api.Event{Type: "unlock", Msg: "steve-pc ha rilasciato il lock"}
	if got := eventMsg(unlock); got != unlock.Msg {
		t.Fatalf("evento non-push alterato: %q", got)
	}
}

func TestHomeFeedStripsTail(t *testing.T) {
	app := testApp()
	h := newHome(app)
	h.loaded = true
	h.spaces = fakeSpaces()
	h.events = []api.Event{
		{TS: time.Now(), Type: "push", Msg: "steve ha pushato la generazione 124 — stop di steve (+0 ~78 −2)"},
		{TS: time.Now(), Type: "unlock", Msg: "steve ha rilasciato il lock"},
	}
	out := h.view(160, 35)
	if strings.Contains(out, "(+0 ~78") {
		t.Error("il feed non deve mostrare la coda con le statistiche del salvataggio")
	}
	if !strings.Contains(out, "stop") {
		t.Error("manca il badge 'stop' per l'evento unlock")
	}
}

func TestRestartPromptLabels(t *testing.T) {
	app := testApp()
	c := newRestartPrompt(app, "1.5.0")
	renderAt(t, c, 100, 30, "Riavvia", "Non ora", "1.5.0")
}

// Il popup dell'aggiornamento parte su «Riavvia»: invio = riavvio. Gli altri
// confirm devono restare su «Annulla» (force, restore, elimina).
func TestRestartPromptDefaultRiavvia(t *testing.T) {
	app := testApp()
	c := newRestartPrompt(app, "1.6.0")
	if c.choice != 1 {
		t.Errorf("choice = %d: il popup deve partire su «Riavvia»", c.choice)
	}
	if _, ok := c.onOK().(restartMsg); !ok {
		t.Error("la conferma non produce un restartMsg")
	}
	// una freccia porta su «Non ora», senza riavviare
	c.update(tea.KeyMsg{Type: tea.KeyLeft})
	if c.choice != 0 {
		t.Errorf("←: choice = %d, atteso 0 (Non ora)", c.choice)
	}

	if d := newConfirm(app, "t", "b", "Elimina", true, 1, nil); d.choice != 0 {
		t.Errorf("i confirm distruttivi devono partire su Annulla, choice = %d", d.choice)
	}
}

// Con la scelta su «Non ora» l'invio chiude il popup senza eseguire l'azione.
func TestConfirmSceltaAnnullaNonEsegue(t *testing.T) {
	eseguito := false
	c := newConfirm(testApp(), "t", "b", "Ok", false, 1,
		func() tea.Msg { eseguito = true; return nil })
	c.choice = 0
	if _, cmd := c.update(tea.KeyMsg{Type: tea.KeyEnter}); cmd != nil {
		cmd() // il pop non deve toccare onOK
	}
	if eseguito {
		t.Error("«Annulla» ha eseguito l'azione")
	}
}

// L'overlay di aiuto ('?') mostra i comandi del contesto e non panica.
func TestHelpOverlay(t *testing.T) {
	app := testApp()
	h := newHome(app)
	h.loaded = true
	h.spaces = fakeSpaces()
	app.stack = []screen{h}
	app.showHelp = true
	out := app.View()
	for _, sub := range []string{"Comandi", "naviga", "aiuto", "chiudere"} {
		if !strings.Contains(out, sub) {
			t.Errorf("overlay aiuto: manca %q", sub)
		}
	}
}

func TestSetupView(t *testing.T) {
	app := testApp()
	s := newSetup(app)
	// il campo è precompilato con l'hub già configurato (o col default di build)
	renderAt(t, s, 100, 30, "M I N E S Y N C", "CONNESSIONE", "INDIRIZZO HUB")
	// nessun hub predefinito (DefaultServer vuoto): il segnaposto spiega il formato
	s.addr.SetValue("")
	renderAt(t, s, 100, 30, "ip-hub")
}

func TestAppFrame(t *testing.T) {
	app := testApp()
	h := newHome(app)
	h.loaded = true
	h.spaces = fakeSpaces()
	app.stack = []screen{h}
	out := app.View()
	for _, sub := range []string{"MineSync", "alex", "12ms", "server"} {
		if !strings.Contains(out, sub) {
			t.Errorf("frame: manca %q", sub)
		}
	}
	// terminale piccolo → messaggio, niente panico
	app.width, app.height = 50, 10
	if !strings.Contains(app.View(), "Allarga") {
		t.Error("manca il guard per terminale piccolo")
	}
}
