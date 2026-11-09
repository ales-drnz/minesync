package tui

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"minesync/client/internal/mc"
	"minesync/client/internal/session"
	"minesync/client/internal/syncx"
)

// fakePlay costruisce una schermata di gioco senza avviare una sessione vera.
func fakePlay(app *App, cancel context.CancelFunc) *playScreen {
	done := make(chan struct{})
	close(done)
	return &playScreen{app: app, sp: fakeSpaces()[0], local: "/tmp/x",
		cancel: cancel, sessDone: done, follow: true}
}

// R8: esc a sessione finita passa dall'unico percorso di pop del root, che
// chiude la schermata (cancel) e spegne il flag di gioco.
func TestPopClosesPlay(t *testing.T) {
	app := testApp()
	cancelled := false
	p := fakePlay(app, func() { cancelled = true })
	p.done = true
	app.live = p
	app.stack = []screen{newHome(app), p}
	app.updatePlayActive()
	if !app.playActive.Load() {
		t.Fatal("playActive deve essere vero con la sessione nello stack")
	}

	_, cmd := app.Update(tea.KeyMsg{Type: tea.KeyEsc})
	if cmd == nil {
		t.Fatal("esc deve produrre un pop")
	}
	if _, ok := cmd().(navPopMsg); !ok {
		t.Fatal("il root deve emettere navPopMsg, non toccare lo stack direttamente")
	}
	app.Update(navPopMsg{})
	if len(app.stack) != 1 || !cancelled || app.playActive.Load() || app.live != nil {
		t.Fatalf("pop incompleto: stack=%d cancel=%v playActive=%v live=%v",
			len(app.stack), cancelled, app.playActive.Load(), app.live != nil)
	}
}

// Sessione viva: esc e q non escono (i tasti globali sono bloccati).
func TestPlayBlocksGlobalWhileRunning(t *testing.T) {
	app := testApp()
	p := fakePlay(app, func() {})
	app.stack = []screen{newHome(app), p}
	app.Update(tea.KeyMsg{Type: tea.KeyEsc})
	if _, handled := app.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("q")}); handled {
		t.Fatal("q durante la sessione è testo per la console")
	}
	if len(app.stack) != 2 {
		t.Fatal("la sessione non deve uscire dallo stack")
	}
}

// R11: un errore di whoami non è un ping e non avvia un secondo loop.
func TestWhoamiErrorNoPingLoop(t *testing.T) {
	app := testApp()
	app.connected = true
	_, cmd := app.Update(whoamiErrMsg{client: app.client, err: fmt.Errorf("x")})
	if cmd == nil {
		t.Fatal("atteso un nuovo tentativo di whoami")
	}
	if !app.connected {
		t.Fatal("lo stato di connessione lo decide solo il ping")
	}
	// risposta di un hub vecchio: ignorata
	if _, cmd := app.Update(whoamiErrMsg{client: nil, err: fmt.Errorf("x")}); cmd != nil {
		t.Fatal("errore di un client superato: nessun retry")
	}
}

// C7: un pull rifiutato per modifiche locali divergenti apre la conferma.
func TestDivergedDirtyShowsConfirm(t *testing.T) {
	app := testApp()
	p := fakePlay(app, func() {})
	dirty := &syncx.DirtyLocalError{BaseGen: 40, HubHead: 42, Changed: []string{"a", "b"}, Removed: []string{"c"}}
	cmd := p.handleBatch(sessBatchMsg{evs: []session.Event{{Kind: session.EvDone, Err: fmt.Errorf("pull: %w", dirty)}}})
	if cmd == nil || !p.done {
		t.Fatal("atteso il passaggio alla conferma")
	}

	c := newDiscardConfirm(app, "miomondo", "/srv/mc/miomondo", dirty)
	renderAt(t, c, 120, 40, "cambiati", "eliminati", "#40", "#42",
		".minesync-backup", "Scarta le modifiche locali", "Annulla")
	m, ok := c.onOK().(replayMsg)
	if !ok || !m.discardLocal || m.space != "miomondo" {
		t.Fatalf("conferma: atteso replay con DiscardLocal, got %#v", c.onOK())
	}

	// non divergente (fast-forward): niente conferma, lo gestisce la sessione
	p2 := fakePlay(app, func() {})
	same := &syncx.DirtyLocalError{BaseGen: 42, HubHead: 42}
	cmd = p2.handleBatch(sessBatchMsg{evs: []session.Event{{Kind: session.EvDone, Err: same}}, closed: true})
	if cmd != nil {
		t.Fatal("DirtyLocalError non divergente non deve aprire la conferma")
	}
}

// R13: la spia "in affanno" si spegne quando gli avvisi escono dalla finestra.
func TestPruneLag(t *testing.T) {
	p := &playScreen{}
	now := time.Now()
	p.lagTimes = []time.Time{now.Add(-5 * time.Minute), now.Add(-3 * time.Minute), now.Add(-time.Minute)}
	p.pruneLag(now)
	if len(p.lagTimes) != 1 {
		t.Fatalf("restano %d avvisi, atteso 1", len(p.lagTimes))
	}
	p.pruneLag(now.Add(10 * time.Minute))
	if len(p.lagTimes) != 0 {
		t.Fatal("la spia deve spegnersi")
	}
}

// La dashboard legge il runtime dalla cache (niente java -version nella View)
// e avvisa solo se Java è più VECCHIO del richiesto.
func TestSpaceJavaFromCache(t *testing.T) {
	app := testApp()
	s := newSpaceScreen(app, "miomondo")
	s.loaded = true
	s.sp = fakeSpaces()[0]
	s.local = "C:/x"
	s.info = mc.ServerInfo{Dir: "C:/x", MCVersion: "1.20.1"}
	renderAt(t, s, 120, 35, "rilevo java")

	key := app.javaKeyFor("miomondo", s.info)
	app.javaCache[key] = javaRes{java: mc.JavaInfo{Found: true, Version: "21.0.1", Major: 21}, req: 17}
	if out := s.view(120, 35); strings.Contains(out, "serve 17") || !strings.Contains(out, "java 21.0.1") {
		t.Error("Java più nuovo del richiesto: nessun avviso")
	}
	app.javaCache[key] = javaRes{java: mc.JavaInfo{Found: true, Version: "1.8.0", Major: 8}, req: 17}
	renderAt(t, s, 120, 35, "serve 17")
	app.javaCache[key] = javaRes{java: mc.JavaInfo{Found: true, Path: "C:/x/jre/bin/java", Unverified: true}, req: 17}
	renderAt(t, s, 120, 35, "verificato al Play")
}

// requestJava non ripete una risoluzione in corso o già in cache.
func TestRequestJavaDedup(t *testing.T) {
	app := testApp()
	info := mc.ServerInfo{Dir: "/nonesiste", MCVersion: ""}
	if app.requestJava("miomondo", info) == nil {
		t.Fatal("prima richiesta: atteso un Cmd")
	}
	if app.requestJava("miomondo", info) != nil {
		t.Fatal("richiesta già in corso: niente doppioni")
	}
	key := app.javaKeyFor("miomondo", info)
	app.handleJava(javaResolvedMsg{key: key, res: javaRes{req: 0}})
	if app.requestJava("miomondo", info) != nil {
		t.Fatal("in cache: niente nuova richiesta")
	}
	app.handleJava(javasDetectedMsg{javas: []mc.JavaInfo{{Found: true, Major: 21}}})
	if !app.javasOK || len(app.javaCache) != 0 {
		t.Fatal("un rilevamento esplicito deve aggiornare la lista e svuotare la cache")
	}
}

// Il force-release di un lock attivo è offerto solo agli admin.
func TestForceReleaseOnlyStaleOrAdmin(t *testing.T) {
	app := testApp()
	s := newSpaceScreen(app, "miomondo")
	s.sp = fakeSpaces()[0] // lock attivo di steve
	if !s.canForceRelease() {
		t.Fatal("admin: force consentito")
	}
	app.who.Admin = false
	if s.canForceRelease() {
		t.Fatal("non admin su lock attivo: force non consentito")
	}
	s.sp.LockStale = true
	if !s.canForceRelease() {
		t.Fatal("lock stale: force consentito a tutti")
	}
	// lock occupato all'avvio del gioco, non admin: errore, niente confirm
	s.sp.LockStale = false
	cmd := s.onLockBusy(lockBusyMsg{holder: s.sp.Lock})
	if _, ok := cmd().(errMsg); !ok {
		t.Fatal("non admin: atteso errore che spiega chi gioca")
	}
}
