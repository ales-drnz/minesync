package notify

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"minesync/server/internal/events"
)

// runBot avvia Run e restituisce la funzione che lo ferma (e aspetta).
func runBot(t *testing.T, tg *Telegram) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { tg.Run(ctx); close(done) }()
	t.Cleanup(func() { cancel(); <-done })
	time.Sleep(50 * time.Millisecond) // lascia partire il Subscribe
}

// Bot spento: niente messaggi, ma la sessione si segue lo stesso. Riacceso
// con un'altra chat, la chiusura arriva lì.
func TestDisattivaERiattivaConAltraChat(t *testing.T) {
	st, bus, tg, f := setup(t)
	off := fullCfg()
	off.Enabled = false
	tg.Apply(off)
	runBot(t, tg)

	lk, _, err := st.AcquireLock("miomondo", "steve", nil, 90)
	if err != nil {
		t.Fatal(err)
	}
	bus.Publish(events.Event{Type: "lock", Space: "miomondo", Actor: "steve"})
	f.wantSilence(t)

	on := fullCfg()
	on.ChatID = "-100777"
	tg.Apply(on)
	if _, err := st.ReleaseLock("miomondo", lk.Session, false); err != nil {
		t.Fatal(err)
	}
	bus.Publish(events.Event{Type: "unlock", Space: "miomondo", Actor: "steve"})
	// arriva solo se la sessione aperta a bot spento è stata tracciata
	f.wantIn(t, "-100777", "🔴", "miomondo")
}

func TestFlagAperturaChiusura(t *testing.T) {
	st, bus, tg, f := setup(t)
	c := fullCfg()
	c.Open = false
	tg.Apply(c)
	runBot(t, tg)

	lk, _, _ := st.AcquireLock("miomondo", "steve", nil, 90)
	bus.Publish(events.Event{Type: "lock", Space: "miomondo", Actor: "steve"})
	f.wantSilence(t) // aperture spente

	c.Open, c.Close = true, false
	tg.Apply(c)
	st.ReleaseLock("miomondo", lk.Session, false)
	bus.Publish(events.Event{Type: "unlock", Space: "miomondo", Actor: "steve"})
	f.wantSilence(t) // chiusure spente

	lk, _, _ = st.AcquireLock("miomondo", "steve", nil, 90)
	bus.Publish(events.Event{Type: "lock", Space: "miomondo", Actor: "steve"})
	f.want(t, "🟢", "miomondo")
	_ = lk
}

// Avvisi spenti: nessun messaggio e la sessione non si marca, così
// riaccendendoli l'avviso arriva.
func TestFlagAvvisi(t *testing.T) {
	st, _, tg, f := setup(t)
	c := fullCfg()
	c.Alerts = false
	tg.Apply(c)
	if _, _, err := st.AcquireLock("miomondo", "steve", nil, 90); err != nil {
		t.Fatal(err)
	}
	tg.adopt()
	go tg.sender(t.Context())
	s := tg.open["miomondo"]
	s.lastPush = time.Now().Add(-pushWarnAfter - time.Minute)
	tg.open["miomondo"] = s

	tg.sweepPushWatchdog()
	f.wantSilence(t)
	c.Alerts = true
	tg.Apply(c)
	tg.sweepPushWatchdog()
	f.want(t, "⚠️", "non salva")
}

// /status spento: il poller non interroga nemmeno Telegram; acceso, risponde
// (solo nella chat configurata); rispento, smette di interrogare.
func TestStatusOnOff(t *testing.T) {
	_, _, tg, f := setup(t)
	c := fullCfg()
	c.Status = false
	tg.Apply(c)
	runBot(t, tg)

	time.Sleep(300 * time.Millisecond)
	if n := f.polls.Load(); n != 0 {
		t.Fatalf("getUpdates chiamato %d volte con /status spento", n)
	}

	c.Status = true
	tg.Apply(c)
	f.cmds <- tgCmd{chat: -100555, text: "/status"} // altra chat: ignorato
	f.cmds <- tgCmd{chat: -100999, text: "/status@minesyncbot"}
	f.want(t, "📊", "miomondo")
	f.wantSilence(t)

	c.Status = false
	tg.Apply(c)
	time.Sleep(100 * time.Millisecond) // il poller in corso si chiude
	n := f.polls.Load()
	time.Sleep(1500 * time.Millisecond)
	if m := f.polls.Load(); m != n {
		t.Fatalf("poller ancora attivo dopo lo spegnimento (%d → %d)", n, m)
	}
}

// Un annuncio accodato prima dello spegnimento non parte.
func TestCodaScartataAlloSpegnimento(t *testing.T) {
	_, _, tg, f := setup(t)
	if !tg.queue(kindOpen, "miomondo", "vecchio") {
		t.Fatal("non accodato")
	}
	off := fullCfg()
	off.Enabled = false
	tg.Apply(off)
	go tg.sender(t.Context())
	f.wantSilence(t)
	if tg.queue(kindOpen, "miomondo", "nuovo") {
		t.Fatal("accodato a bot spento")
	}
}

// Messaggio di prova: errore di Telegram leggibile, registrato nello stato;
// un errore di rete non deve mai contenere il token.
func TestProvaErrori(t *testing.T) {
	_, _, tg, f := setup(t)
	f.sendCode.Store(400)
	err := tg.Test(t.Context(), fullCfg(), "")
	if err == nil || !strings.Contains(err.Error(), "chat not found") {
		t.Fatalf("errore: %v", err)
	}
	if st := tg.Status(); st.LastError == nil || st.LastErrorAt.IsZero() {
		t.Fatalf("stato: %+v", st)
	}
	f.sendCode.Store(0)
	if err := tg.Test(t.Context(), fullCfg(), ""); err != nil {
		t.Fatal(err)
	}
	f.want(t, "messaggio di prova")
	if st := tg.Status(); st.LastError != nil || st.LastSentAt.IsZero() {
		t.Fatalf("stato dopo l'invio riuscito: %+v", st)
	}

	dead := httptest.NewServer(nil)
	dead.Close()
	tg.base = dead.URL
	secret := "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawQ"
	c := fullCfg()
	c.Token = secret
	err = tg.Test(t.Context(), c, "")
	if err == nil || strings.Contains(err.Error(), secret) {
		t.Fatalf("token nell'errore: %v", err)
	}
}
