package notify

import (
	"strings"
	"testing"

	"minesync/server/internal/events"
	"minesync/server/internal/store"
)

// setupTopics: due server, "miomondo" col suo topic (7), "SkyFactory" senza
// (va nel Generale).
func setupTopics(t *testing.T) (*store.Store, *events.Bus, *Telegram, *fakeTG, Config) {
	t.Helper()
	st, bus, tg, f := setup(t)
	if _, err := st.CreateSpace("SkyFactory", "minecraft", nil); err != nil {
		t.Fatal(err)
	}
	c := fullCfg()
	c.Topics = map[string]int64{"miomondo": 7}
	tg.Apply(c)
	return st, bus, tg, f, c
}

func TestTopicPerServer(t *testing.T) {
	st, bus, tg, f, _ := setupTopics(t)
	runBot(t, tg)

	lk, _, err := st.AcquireLock("miomondo", "steve", playInfo(), 90)
	if err != nil {
		t.Fatal(err)
	}
	bus.Publish(events.Event{Type: "lock", Space: "miomondo", Actor: "steve"})
	f.wantTopic(t, 7, "🟢", "miomondo")

	if _, _, err := st.AcquireLock("skyfactory", "alex", playInfo(), 90); err != nil {
		t.Fatal(err)
	}
	bus.Publish(events.Event{Type: "lock", Space: "skyfactory", Actor: "alex"})
	f.wantTopic(t, 0, "🟢", "SkyFactory") // senza topic: Generale

	if _, err := st.ReleaseLock("miomondo", lk.Session, false); err != nil {
		t.Fatal(err)
	}
	bus.Publish(events.Event{Type: "unlock", Space: "miomondo", Actor: "steve"})
	f.wantTopic(t, 7, "🔴", "miomondo")
}

// /status nel topic di un server risponde solo per quel server, lì; nel
// Generale o in un topic di nessuno, per tutti e nello stesso thread.
func TestStatusNelTopic(t *testing.T) {
	_, _, tg, f, _ := setupTopics(t)
	runBot(t, tg)

	only := func(m sent, want, not string) {
		t.Helper()
		if !strings.Contains(m.text, want) || (not != "" && strings.Contains(m.text, not)) {
			t.Errorf("/status: atteso %q senza %q: %q", want, not, m.text)
		}
	}

	f.cmds <- tgCmd{chat: -100999, text: "/status", thread: 7}
	m := f.next(t, "-100999", "📊")
	if m.thread != 7 {
		t.Errorf("risposta nel thread %d, attesa nel 7", m.thread)
	}
	only(m, "miomondo", "SkyFactory")

	f.cmds <- tgCmd{chat: -100999, text: "/status"} // Generale
	m = f.next(t, "-100999", "📊")
	if m.thread != 0 {
		t.Errorf("risposta dal Generale nel thread %d", m.thread)
	}
	only(m, "miomondo", "")
	only(m, "SkyFactory", "")

	f.cmds <- tgCmd{chat: -100999, text: "/status", thread: 42} // topic di nessuno
	m = f.next(t, "-100999", "📊")
	if m.thread != 42 {
		t.Errorf("risposta nel thread %d, attesa nel 42", m.thread)
	}
	only(m, "miomondo", "")
	only(m, "SkyFactory", "")
}

// Topic eliminato dal gruppo: l'annuncio arriva lo stesso nel Generale e lo
// stato del bot dice quale topic manca.
func TestTopicEliminato(t *testing.T) {
	st, bus, tg, f, _ := setupTopics(t)
	f.deadTopic.Store(7)
	runBot(t, tg)

	if _, _, err := st.AcquireLock("miomondo", "steve", playInfo(), 90); err != nil {
		t.Fatal(err)
	}
	bus.Publish(events.Event{Type: "lock", Space: "miomondo", Actor: "steve"})
	f.wantTopic(t, 0, "🟢", "miomondo")
	f.wantSilence(t) // una volta sola

	s := tg.Status()
	if s.LastError == nil || !strings.Contains(s.LastError.Error(), "topic di miomondo non trovato") {
		t.Fatalf("lastError: %v", s.LastError)
	}

	// sistemata la mappa (topic tolto), l'errore sparisce
	c := fullCfg()
	tg.Apply(c)
	if s := tg.Status(); s.LastError != nil {
		t.Fatalf("errore rimasto dopo la modifica dei topic: %v", s.LastError)
	}
}

// Messaggio di prova per il topic di un server: nel suo thread, col suo
// nome; topic eliminato = errore chiaro, senza sporcare lo stato del bot.
func TestProvaTopic(t *testing.T) {
	_, _, tg, f, c := setupTopics(t)
	if err := tg.Test(t.Context(), c, "miomondo"); err != nil {
		t.Fatal(err)
	}
	f.wantTopic(t, 7, "messaggio di prova", "miomondo")

	if err := tg.Test(t.Context(), c, "skyfactory"); err != nil {
		t.Fatal(err)
	}
	f.wantTopic(t, 0, "SkyFactory")

	f.deadTopic.Store(7)
	err := tg.Test(t.Context(), c, "miomondo")
	if err == nil || !strings.Contains(err.Error(), "topic di miomondo non trovato") {
		t.Fatalf("errore: %v", err)
	}
	if s := tg.Status(); s.LastError != nil {
		t.Fatalf("la prova ha sporcato lo stato: %v", s.LastError)
	}
}
