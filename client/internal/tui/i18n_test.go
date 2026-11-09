package tui

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"minesync/client/internal/i18n"
	"minesync/client/internal/mc"
	"minesync/client/internal/session"
)

// I test esistenti verificano i testi italiani: girano in italiano, quelli
// in inglese impostano la lingua da sé (withLang).
func TestMain(m *testing.M) {
	i18n.Set(i18n.IT)
	os.Exit(m.Run())
}

func withLang(t *testing.T, l i18n.Lang) {
	t.Helper()
	prev := i18n.Current()
	i18n.Set(l)
	t.Cleanup(func() { i18n.Set(prev) })
}

// allScreens costruisce una schermata per tipo, con dati finti.
func allScreens(app *App) []screen {
	h := newHome(app)
	h.loaded = true
	h.spaces = fakeSpaces()
	sp := newSpaceScreen(app, "miomondo")
	sp.loaded = true
	sp.sp = fakeSpaces()[0]
	sp.sp.Lock.Info = map[string]string{"host": "10.147.20.5", "port": "25565"}
	sp.local = "C:/x"
	sp.gens = fakeGens()
	sync := newSpaceScreen(app, "miomondo")
	sync.loaded, sync.sp, sync.local, sync.syncing, sync.syncKind = true, fakeSpaces()[0], "C:/x", true, "pull"
	hs := newHistory(app, "miomondo")
	hs.loaded, hs.gens, hs.head = true, fakeGens(), 42
	js := newJavaScreen(app, "miomondo", mc.ServerInfo{MCVersion: "1.20.1", Loader: "forge"})
	js.setJavas([]mc.JavaInfo{{Path: "/usr/bin/java", Version: "17.0.9", Major: 17, Found: true}})
	p := fakePlay(app, func() {})
	p.sess = session.New(session.Config{SpaceID: "miomondo"})
	p.state = session.StateRunning
	p.players = []string{"steve", "alex"}
	p.addNote("Server avviato (porta 25565)", true)
	return []screen{h, sp, sync, hs, js, p, newSetup(app), newCreateSpace(app),
		newConfirm(app, i18n.S("Forzare il rilascio?"),
			i18n.Sf("Il lock di %s è attivo: se sta giocando, perderà i progressi non salvati.", "steve"),
			i18n.S("Rilascia"), true, 2, nil),
		newRestartPrompt(app, "3.1.0")}
}

// TestLayoutBothLanguages: in entrambe le lingue e a varie dimensioni nessuna
// riga esce dal terminale e il frame completo ha esattamente l'altezza data.
func TestLayoutBothLanguages(t *testing.T) {
	for _, l := range []i18n.Lang{i18n.IT, i18n.EN} {
		withLang(t, l)
		for _, wh := range [][2]int{{70, 20}, {80, 24}, {120, 35}, {200, 50}} {
			app := testApp()
			app.width, app.height = wh[0], wh[1]
			for _, s := range allScreens(app) {
				app.stack = []screen{s}
				for _, help := range []bool{false, true} {
					app.showHelp = help
					out := app.View()
					lines := strings.Split(out, "\n")
					if len(lines) != wh[1] {
						t.Errorf("%s %T %dx%d help=%v: %d righe, attese %d", l, s, wh[0], wh[1], help, len(lines), wh[1])
					}
					for i, line := range lines {
						if w := lipgloss.Width(line); w > wh[0] {
							t.Errorf("%s %T %dx%d help=%v: riga %d larga %d", l, s, wh[0], wh[1], help, i, w)
						}
					}
				}
			}
		}
	}
}

// TestEnglishScreens: in inglese le schermate parlano inglese, e nessuna
// parola italiana del client sfugge alla traduzione.
func TestEnglishScreens(t *testing.T) {
	withLang(t, i18n.EN)
	app := testApp()
	scr := allScreens(app)
	want := map[int][]string{
		0: {"SERVERS (2)", "ACTIVITY", "in game · steve", "free"},
		1: {"HUB STATUS", "LOCAL COPY", "in game: steve", "RECENT HISTORY", "generation   #42", "JOIN THE GAME AT"},
		2: {"TRANSFER", "pull in progress — phase:", "transferred"},
		3: {"HISTORY OF MIOMONDO", "generations", "HEAD"},
		4: {"JAVA RUNTIME FOR MIOMONDO", "Automatic", "✓ recommended", "Recommended Java for this modpack"},
		5: {"SESSION", "in game", "PLAYERS (2)", "port      ", "folder    ", "ALERTS"},
		6: {"HUB ADDRESS", "CONNECTION", "the shared world"},
		7: {"SERVER NAME", "NEW SERVER"},
		8: {"Force the release?", "Cancel", "Release", "Confirmation 1 of 2."},
		9: {"Update ready", "Restart", "Not now"},
	}
	italian := []string{"carico", "generazione", "cartella", "libero", "storia", "giocatori", "sessione ",
		"Annulla", "Conferma", "connessione", "Nessun", "trasferiti", "in corso", "consigliato", "Riavvia"}
	for i, s := range scr {
		out := s.view(120, 35)
		for _, sub := range want[i] {
			if !strings.Contains(out, sub) {
				t.Errorf("%T: manca %q", s, sub)
			}
		}
		for _, it := range italian {
			if strings.Contains(out, it) {
				t.Errorf("%T: testo italiano in inglese: %q", s, it)
			}
		}
		app.stack = []screen{s}
		for _, h := range app.footerHints() {
			for _, it := range []string{"naviga", "indietro", "aiuto", "invio", "annulla", "esci"} {
				if h.label == it || h.key == it {
					t.Errorf("%T: tasto non tradotto %q", s, it)
				}
			}
		}
	}
}

// TestLanguageToggle: 'l' sulla home passa all'altra lingua e la salva in
// config; ctrl+l fa lo stesso nella schermata di connessione.
func TestLanguageToggle(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	withLang(t, i18n.IT)
	app := testApp()
	h := newHome(app)
	h.loaded = true
	app.stack = []screen{h}

	press := func(k tea.KeyMsg) {
		t.Helper()
		_, cmd := app.Update(k)
		if cmd == nil {
			t.Fatalf("%s: nessun comando", k)
		}
		msg := cmd()
		if _, ok := msg.(langToggleMsg); !ok {
			t.Fatalf("%s: atteso langToggleMsg, got %T", k, msg)
		}
		app.Update(msg)
	}
	press(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("l")})
	if i18n.Current() != i18n.EN || app.cfg.Lang != "en" {
		t.Fatalf("dopo 'l': lingua %s, config %q", i18n.Current(), app.cfg.Lang)
	}
	b, err := os.ReadFile(filepath.Join(home, ".minesync", "config.json"))
	if err != nil || !strings.Contains(string(b), `"lang": "en"`) {
		t.Fatalf("lingua non salvata in config: %s %v", b, err)
	}
	if !strings.Contains(app.View(), "language: English") {
		t.Error("manca la conferma del cambio lingua")
	}
	// il tasto è elencato nell'aiuto ('?'), non nel footer
	app.showHelp = true
	if !strings.Contains(app.View(), "language → Italiano") {
		t.Error("il cambio lingua deve comparire nell'aiuto")
	}
	app.showHelp = false

	app.stack = []screen{h, newSetup(app)}
	app.flash = "" // il flash occupa il footer finché non scade
	if !strings.Contains(app.View(), "language → Italiano") {
		t.Error("il cambio lingua deve essere visibile nella schermata di connessione")
	}
	press(tea.KeyMsg{Type: tea.KeyCtrlL})
	if i18n.Current() != i18n.IT || app.cfg.Lang != "it" {
		t.Fatalf("dopo ctrl+l: lingua %s, config %q", i18n.Current(), app.cfg.Lang)
	}
}
