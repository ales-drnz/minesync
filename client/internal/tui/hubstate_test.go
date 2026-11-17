package tui

import (
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/lipgloss"

	"minesync/client/internal/api"
	"minesync/client/internal/i18n"
	"minesync/client/internal/lockbeat"
	"minesync/client/internal/session"
	"minesync/client/internal/syncx"
)

// frameAt rende l'app intera con s in cima e controlla le misure del frame.
func frameAt(t *testing.T, app *App, s screen, w, h int) string {
	t.Helper()
	app.width, app.height = w, h
	app.stack = []screen{s}
	out := app.View()
	lines := strings.Split(out, "\n")
	if len(lines) != h {
		t.Errorf("%T %dx%d: %d righe, attese %d", s, w, h, len(lines), h)
	}
	for i, l := range lines {
		if lw := lipgloss.Width(l); lw > w {
			t.Errorf("%T %dx%d: riga %d larga %d", s, w, h, i, lw)
		}
	}
	return out
}

func runningPlay(app *App) *playScreen {
	p := fakePlay(app, func() {})
	p.sess = session.New(session.Config{SpaceID: "miomondo"})
	p.state = session.StateRunning
	return p
}

// Il pannello sessione mostra da quanto l'hub ha l'ultimo stato e, durante un
// caricamento in background, la percentuale; in entrambe le lingue e alle
// misure tipiche del terminale.
func TestPlayStatoSullHub(t *testing.T) {
	cases := []struct {
		lang            i18n.Lang
		saved, loading  string
		never, hubLabel string
	}{
		{i18n.IT, "sull'hub  7m fa", "in caricamento… 34%", "sull'hub  mai", "sull'hub"},
		{i18n.EN, "on hub    7m ago", "uploading… 34%", "on hub    never", "on hub"},
	}
	for _, c := range cases {
		withLang(t, c.lang)
		for _, wh := range [][2]int{{80, 24}, {120, 35}} {
			app := testApp()
			p := runningPlay(app)
			if out := frameAt(t, app, p, wh[0], wh[1]); !strings.Contains(out, c.never) {
				t.Errorf("%s %v: manca %q", c.lang, wh, c.never)
			}
			p.applyEvent(session.Event{Kind: session.EvSaved, Gen: 43, HubSavedAt: time.Now().Add(-7*time.Minute - 5*time.Second)})
			if out := frameAt(t, app, p, wh[0], wh[1]); !strings.Contains(out, c.saved) {
				t.Errorf("%s %v: manca %q", c.lang, wh, c.saved)
			}
			p.applyEvent(session.Event{Kind: session.EvUpload, Uploading: true,
				Progress: syncx.Progress{DoneBytes: 34, TotalBytes: 100}})
			out := frameAt(t, app, p, wh[0], wh[1])
			if !strings.Contains(out, c.loading) || strings.Contains(out, c.saved) {
				t.Errorf("%s %v: in caricamento atteso %q:\n%s", c.lang, wh, c.loading, out)
			}
			// caricamento finito: torna l'età, aggiornata dal nuovo istante
			p.applyEvent(session.Event{Kind: session.EvUpload, Uploading: false, HubSavedAt: time.Now()})
			if out := frameAt(t, app, p, wh[0], wh[1]); strings.Contains(out, c.loading) || !strings.Contains(out, c.hubLabel) {
				t.Errorf("%s %v: dopo il caricamento\n%s", c.lang, wh, out)
			}
		}
	}
}

// Lock perso, spazio sparito, hub pieno: avviso rosso in cima alla colonna,
// visibile anche nel terminale più piccolo, in entrambe le lingue.
func TestPlayAvvisiGravi(t *testing.T) {
	diskFull := &api.APIError{Status: 507, Code: "disk_full", Msg: "disco pieno"}
	cases := []struct {
		name string
		ev   session.Event
		want map[i18n.Lang]string
	}{
		{"lock perso (alert)", session.Event{Kind: session.EvNote, Warn: true, Alert: true,
			Note: "lock perso", Err: session.ErrLockLost},
			map[i18n.Lang]string{i18n.IT: "LOCK PERSO", i18n.EN: "LOCK LOST"}},
		{"lock perso (fine sessione)", session.Event{Kind: session.EvDone, Err: session.ErrLockLost},
			map[i18n.Lang]string{i18n.IT: "LOCK PERSO", i18n.EN: "LOCK LOST"}},
		{"alert generico", session.Event{Kind: session.EvNote, Warn: true, Alert: true, Note: "qualcosa di grave"},
			map[i18n.Lang]string{i18n.IT: "ATTENZIONE", i18n.EN: "WARNING"}},
		{"spazio sparito", session.Event{Kind: session.EvDone, Err: lockbeat.ErrSpaceGone},
			map[i18n.Lang]string{i18n.IT: "SPAZIO SPARITO", i18n.EN: "SPACE GONE"}},
		{"hub pieno", session.Event{Kind: session.EvNote, Warn: true, Note: "disco pieno", Err: diskFull},
			map[i18n.Lang]string{i18n.IT: "HUB PIENO", i18n.EN: "HUB FULL"}},
	}
	for _, l := range []i18n.Lang{i18n.IT, i18n.EN} {
		withLang(t, l)
		for _, c := range cases {
			for _, wh := range [][2]int{{80, 24}, {120, 35}} {
				app := testApp()
				p := runningPlay(app)
				p.applyEvent(c.ev)
				out := frameAt(t, app, p, wh[0], wh[1])
				if !strings.Contains(out, c.want[l]) {
					t.Errorf("%s %s %v: manca l'avviso %q:\n%s", l, c.name, wh, c.want[l], out)
				}
			}
		}
	}
	// un warning qualunque non è un avviso grave
	app := testApp()
	p := runningPlay(app)
	p.applyEvent(session.Event{Kind: session.EvNote, Warn: true, Note: "Hub irraggiungibile"})
	if p.alert != nil {
		t.Errorf("avviso grave per un warning normale: %+v", p.alert)
	}
}

// La dashboard avvisa quando l'hub ha meno del 10% di disco libero.
func TestHomeDiscoHubQuasiPieno(t *testing.T) {
	for _, l := range []i18n.Lang{i18n.IT, i18n.EN} {
		withLang(t, l)
		want := map[i18n.Lang]string{i18n.IT: "hub quasi pieno", i18n.EN: "hub almost full"}[l]
		for _, wh := range [][2]int{{80, 24}, {120, 35}} {
			app := testApp()
			h := newHome(app)
			h.loaded, h.spaces = true, fakeSpaces()
			app.stack = []screen{h}
			app.Update(pingMsg{latency: time.Millisecond, diskFree: 50e9, diskTotal: 1000e9})
			if out := frameAt(t, app, h, wh[0], wh[1]); !strings.Contains(out, want) {
				t.Errorf("%s %v: manca l'avviso disco", l, wh)
			}
			app.Update(pingMsg{latency: time.Millisecond, diskFree: 200e9, diskTotal: 1000e9})
			if out := frameAt(t, app, h, wh[0], wh[1]); strings.Contains(out, want) {
				t.Errorf("%s %v: avviso disco con il 20%% libero", l, wh)
			}
		}
	}
	// hub vecchio che non espone il disco: nessun avviso
	app := testApp()
	if w := app.hubDiskWarning(); w != "" {
		t.Errorf("avviso senza dati: %q", w)
	}
}
