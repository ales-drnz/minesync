package notify

import (
	"context"
	"strings"
	"testing"
	"time"

	"minesync/server/internal/events"
	"minesync/server/internal/i18n"
)

// startSender fa partire solo l'invio (i test chiamano handle e gli sweep a mano).
func startSender(t *testing.T, tg *Telegram) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go tg.sender(ctx)
}

// C2: un push manuale tiene il lock ma non apre il server: niente annunci.
func TestPushLockNotAnnounced(t *testing.T) {
	st, _, tg, f := setup(t)
	startSender(t, tg)
	lk, _, err := st.AcquireLock("miomondo", "steve", map[string]string{"action": "push"}, 90)
	if err != nil {
		t.Fatal(err)
	}
	tg.handle(events.Event{Type: "lock", Space: "miomondo"})
	tg.sweepStale()
	f.wantSilence(t)
	if _, err := st.ReleaseLock("miomondo", lk.Session, false); err != nil {
		t.Fatal(err)
	}
	tg.handle(events.Event{Type: "unlock", Space: "miomondo"})
	f.wantSilence(t)
	// action "push" vince anche se c'è un host
	if _, _, err := st.AcquireLock("miomondo", "steve", map[string]string{"action": "push", "host": "10.0.0.1"}, 90); err != nil {
		t.Fatal(err)
	}
	tg.handle(events.Event{Type: "lock", Space: "miomondo"})
	f.wantSilence(t)
	if msg := tg.statusMsg(nil); !strings.Contains(msg, "⚪") {
		t.Errorf("/status mostra aperto un push manuale: %q", msg)
	}
}

// Telegram dice quanto aspettare (429 retry_after): si aspetta quello, non
// il backoff di default.
func TestRetryAfterHonoured(t *testing.T) {
	_, _, tg, f := setup(t)
	tg.backoff = 30 * time.Second // se lo usasse, il messaggio non arriverebbe in tempo
	f.retryAfter.Store(1)
	f.throttle.Store(1)
	startSender(t, tg)
	start := time.Now()
	tg.queue(kindAlert, "miomondo", "prova 429")
	f.want(t, "prova 429")
	if el := time.Since(start); el < 900*time.Millisecond {
		t.Errorf("riprovato dopo %v: retry_after (1s) ignorato", el)
	}
}

// Il tempo totale dei tentativi è limitato: un retry_after enorme fa
// rinunciare subito, con l'errore registrato.
func TestRetryBudgetBounded(t *testing.T) {
	_, _, tg, f := setup(t)
	tg.retryBudget = 2 * time.Second
	f.retryAfter.Store(600)
	f.throttle.Store(10)
	startSender(t, tg)
	tg.queue(kindAlert, "miomondo", "mai")
	deadline := time.Now().Add(2 * time.Second)
	for tg.Status().LastError == nil && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if tg.Status().LastError == nil {
		t.Fatal("con retry_after oltre il tetto il bot è rimasto ad aspettare")
	}
	if n := f.sends.Load(); n != 1 {
		t.Errorf("tentativi %d, atteso 1", n)
	}
	f.wantSilence(t)
}

// Chiuso e riaperto subito dallo stesso host: nessun messaggio, e la
// chiusura vera più tardi riporta la durata dall'apertura originale.
func TestCoalesceCloseOpenSameOwner(t *testing.T) {
	st, _, tg, f := setup(t)
	tg.coalesce = time.Minute
	startSender(t, tg)
	lk, _, _ := st.AcquireLock("miomondo", "steve", playInfo(), 90)
	tg.handle(events.Event{Type: "lock", Space: "miomondo"})
	f.want(t, "🟢", "steve")
	first := tg.open["miomondo"].start

	st.ReleaseLock("miomondo", lk.Session, false)
	tg.handle(events.Event{Type: "unlock", Space: "miomondo"})
	tg.flushPending(time.Now())
	f.wantSilence(t) // in attesa: magari riapre

	lk, _, _ = st.AcquireLock("miomondo", "steve", playInfo(), 90)
	tg.handle(events.Event{Type: "lock", Space: "miomondo"})
	tg.sweepStale()
	tg.flushPending(time.Now().Add(time.Hour))
	f.wantSilence(t) // riavvio del server: per il gruppo non è mai stato chiuso
	if s := tg.open["miomondo"]; !s.start.Equal(first) {
		t.Errorf("inizio sessione %v, atteso quello originale %v", s.start, first)
	}

	st.ReleaseLock("miomondo", lk.Session, false)
	tg.handle(events.Event{Type: "unlock", Space: "miomondo"})
	tg.flushPending(time.Now().Add(time.Hour))
	f.want(t, "🔴", "miomondo")
	tg.flushPending(time.Now().Add(2 * time.Hour))
	f.wantSilence(t)
}

// Chiuso da uno e riaperto da un altro: la chiusura parte subito, prima
// dell'apertura.
func TestCoalesceDifferentOwner(t *testing.T) {
	st, _, tg, f := setup(t)
	tg.coalesce = time.Minute
	startSender(t, tg)
	lk, _, _ := st.AcquireLock("miomondo", "steve", playInfo(), 90)
	tg.handle(events.Event{Type: "lock", Space: "miomondo"})
	f.want(t, "🟢", "steve")
	st.ReleaseLock("miomondo", lk.Session, false)
	tg.handle(events.Event{Type: "unlock", Space: "miomondo"})
	st.AcquireLock("miomondo", "alex", playInfo(), 90)
	tg.handle(events.Event{Type: "lock", Space: "miomondo"})
	f.want(t, "🔴", "miomondo")
	f.want(t, "🟢", "alex")
}

// Un lock dato per morto (stale, chiusura annunciata) torna vivo con un
// heartbeat: si riannuncia l'apertura, e il rilascio successivo si annuncia.
func TestStaleRevivedThenReleased(t *testing.T) {
	st, _, tg, f := setup(t)
	startSender(t, tg)
	lk, _, err := st.AcquireLock("miomondo", "steve", playInfo(), 1)
	if err != nil {
		t.Fatal(err)
	}
	tg.handle(events.Event{Type: "lock", Space: "miomondo"})
	f.want(t, "🟢", "steve")
	time.Sleep(1100 * time.Millisecond)
	tg.sweepStale()
	f.want(t, "🔴", "non risponde")

	if _, err := st.HeartbeatLock("miomondo", lk.Session, "steve", nil, true); err != nil {
		t.Fatal(err)
	}
	tg.sweepStale()
	f.want(t, "🟢", "steve")
	tg.sweepStale()
	f.wantSilence(t) // una volta sola

	st.ReleaseLock("miomondo", lk.Session, false)
	tg.handle(events.Event{Type: "unlock", Space: "miomondo"})
	f.want(t, "🔴", "miomondo")
}

// Con il raggruppamento attivo, un lock stale che torna vivo prima che la
// chiusura parta non produce messaggi.
func TestStaleRevivedWithinCoalesce(t *testing.T) {
	st, _, tg, f := setup(t)
	tg.coalesce = time.Minute
	startSender(t, tg)
	lk, _, _ := st.AcquireLock("miomondo", "steve", playInfo(), 1)
	tg.handle(events.Event{Type: "lock", Space: "miomondo"})
	f.want(t, "🟢")
	time.Sleep(1100 * time.Millisecond)
	tg.sweepStale()
	if _, err := st.HeartbeatLock("miomondo", lk.Session, "", nil, true); err != nil {
		t.Fatal(err)
	}
	tg.sweepStale()
	tg.flushPending(time.Now().Add(time.Hour))
	f.wantSilence(t)
	if _, ok := tg.open["miomondo"]; !ok {
		t.Fatal("sessione resuscitata non più seguita")
	}
}

// Uno spazio eliminato: la sessione aperta si dimentica, senza messaggi.
func TestDeletedSpaceForgotten(t *testing.T) {
	st, _, tg, f := setup(t)
	startSender(t, tg)
	st.AcquireLock("miomondo", "steve", playInfo(), 1)
	tg.handle(events.Event{Type: "lock", Space: "miomondo"})
	f.want(t, "🟢")
	time.Sleep(1100 * time.Millisecond) // stale: ora si può eliminare
	if err := st.DeleteSpace("miomondo"); err != nil {
		t.Fatal(err)
	}
	tg.handle(events.Event{Type: "space", Space: "miomondo", Data: map[string]any{"deleted": true}})
	if len(tg.open) != 0 {
		t.Fatal("sessione di uno spazio eliminato ancora aperta")
	}
	tg.sweepStale()
	f.wantSilence(t)

	// anche senza l'evento: lo sweep dimentica gli spazi spariti
	st.CreateSpace("altro", "minecraft", nil)
	st.AcquireLock("altro", "alex", playInfo(), 1)
	tg.handle(events.Event{Type: "lock", Space: "altro"})
	f.want(t, "🟢")
	time.Sleep(1100 * time.Millisecond)
	st.DeleteSpace("altro")
	tg.sweepStale()
	if len(tg.open) != 0 {
		t.Fatal("sweep: sessione di uno spazio eliminato ancora aperta")
	}
}

// C4: l'evento di disco pieno arriva come avviso.
func TestDiskAlert(t *testing.T) {
	_, _, tg, f := setup(t)
	startSender(t, tg)
	tg.handle(events.Event{Type: "disk",
		Text: i18n.M("⚠ disco dell'hub quasi pieno: %s liberi (soglia %s), push e nuove sessioni sono sospesi", "1 GiB", "2 GiB")})
	f.want(t, "1 GiB", "2 GiB")
}
