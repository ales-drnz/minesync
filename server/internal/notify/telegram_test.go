package notify

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"minesync/server/internal/events"
	"minesync/server/internal/store"
)

// fakeTG finge le API di Telegram e raccoglie i testi inviati.
type fakeTG struct {
	*httptest.Server
	msgs chan string
}

func newFakeTG(t *testing.T) *fakeTG {
	t.Helper()
	f := &fakeTG{msgs: make(chan string, 16)}
	f.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/getUpdates") {
			w.Write([]byte(`{"ok":true,"result":[]}`)) // il poller non ha comandi
			return
		}
		body, _ := io.ReadAll(r.Body)
		var req struct {
			ChatID string `json:"chat_id"`
			Text   string `json:"text"`
		}
		if err := json.Unmarshal(body, &req); err != nil {
			t.Errorf("body non JSON: %v", err)
		}
		if req.ChatID != "-100999" {
			t.Errorf("chat_id = %q", req.ChatID)
		}
		f.msgs <- req.Text
		w.Write([]byte(`{"ok":true}`))
	}))
	t.Cleanup(f.Close)
	return f
}

// want attende un messaggio e verifica che contenga tutti i frammenti.
func (f *fakeTG) want(t *testing.T, frags ...string) {
	t.Helper()
	select {
	case msg := <-f.msgs:
		for _, s := range frags {
			if !strings.Contains(msg, s) {
				t.Errorf("messaggio %q: manca %q", msg, s)
			}
		}
	case <-time.After(3 * time.Second):
		t.Fatalf("nessun messaggio (attesi %v)", frags)
	}
}

func (f *fakeTG) wantSilence(t *testing.T) {
	t.Helper()
	select {
	case msg := <-f.msgs:
		t.Fatalf("messaggio inatteso: %q", msg)
	case <-time.After(200 * time.Millisecond):
	}
}

func setup(t *testing.T) (*store.Store, *events.Bus, *Telegram, *fakeTG) {
	t.Helper()
	dir := t.TempDir()
	st, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.CreateSpace("miomondo", "minecraft", nil); err != nil {
		t.Fatal(err)
	}
	bus := events.NewBus(filepath.Join(dir, "events.jsonl"))
	f := newFakeTG(t)
	tg := New("tok", "-100999", "internal", st, bus)
	tg.base = f.URL
	return st, bus, tg, f
}

func TestApreEChiude(t *testing.T) {
	st, bus, tg, f := setup(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go tg.Run(ctx)
	time.Sleep(50 * time.Millisecond) // lascia partire il Subscribe

	// info come la pubblica il client: IP ZeroTier per primo, poi LAN.
	info := map[string]string{"host": "10.147.17.20,192.168.1.40", "port": "25565"}
	lk, _, err := st.AcquireLock("miomondo", "steve", info, 90)
	if err != nil {
		t.Fatal(err)
	}
	bus.Publish(events.Event{Type: "lock", Space: "miomondo", Actor: "steve"})
	f.want(t, "🟢", "miomondo", "👤", "steve",
		"🌐", "zerotier.miomondo.internal", "📡", "10.147.17.20")

	if _, err := st.ReleaseLock("miomondo", lk.Session, false); err != nil {
		t.Fatal(err)
	}
	bus.Publish(events.Event{Type: "unlock", Space: "miomondo", Actor: "steve"})
	f.want(t, "🔴", "miomondo")
}

// Se il client sparisce senza rilasciare il lock, la chiusura deve arrivare
// lo stesso quando il lock scade.
func TestClientSparito(t *testing.T) {
	st, _, tg, f := setup(t)
	if _, _, err := st.AcquireLock("miomondo", "steve", nil, 1); err != nil {
		t.Fatal(err)
	}
	tg.adopt()
	go tg.sender(context.Background())

	tg.sweepStale()
	f.wantSilence(t) // lock ancora vivo: nessun annuncio

	time.Sleep(1100 * time.Millisecond) // TTL 1s scaduto, niente heartbeat
	tg.sweepStale()
	f.want(t, "🔴", "miomondo", "steve", "non risponde")

	tg.sweepStale()
	f.wantSilence(t) // annunciato una volta sola
}

// Un riavvio dell'hub non deve riannunciare un server già aperto.
func TestRiavvioHubNonRiannuncia(t *testing.T) {
	st, _, tg, f := setup(t)
	if _, _, err := st.AcquireLock("miomondo", "steve", nil, 90); err != nil {
		t.Fatal(err)
	}
	tg.adopt()
	go tg.sender(context.Background())
	tg.sweepStale()
	f.wantSilence(t)
	if _, aperto := tg.open["miomondo"]; !aperto {
		t.Error("il lock attivo non è stato adottato: la chiusura andrebbe persa")
	}
}

// Ogni riga deve iniziare con un'emoji, e l'IP LAN dell'host non deve finire
// nel gruppo (agli altri non serve e confonde: si gioca via ZeroTier).
func TestOgniRigaHaEmoji(t *testing.T) {
	_, _, tg, _ := setup(t)
	lk := &store.LockInfo{
		Owner: "steve",
		Info:  map[string]string{"host": "10.147.17.20,192.168.1.40", "port": "25565"},
	}
	msg := tg.openMsg("miomondo", lk)
	for _, line := range strings.Split(msg, "\n") {
		if r := []rune(line)[0]; r < 0x2000 {
			t.Errorf("riga senza emoji iniziale: %q", line)
		}
	}
	if strings.Contains(msg, "192.168.1.40") {
		t.Errorf("l'IP LAN dell'host non va annunciato: %q", msg)
	}
	if strings.Contains(msg, ":25565") {
		t.Errorf("la porta di default è sottintesa, non va mostrata: %q", msg)
	}

	// porta non standard: va mostrata, altrimenti l'indirizzo non è copiabile
	lk.Info["port"] = "25570"
	if got := hostAddr(lk); got != "10.147.17.20:25570" {
		t.Errorf("hostAddr = %q", got)
	}
}

// Un lock senza IP pubblicati (client vecchio) non deve produrre righe vuote.
func TestSenzaIPNienteRiga(t *testing.T) {
	_, _, tg, _ := setup(t)
	msg := tg.openMsg("miomondo", &store.LockInfo{Owner: "steve"})
	if strings.Contains(msg, "📡") {
		t.Errorf("riga IP senza IP: %q", msg)
	}
	if n := len(strings.Split(msg, "\n")); n != 3 { // stato, host, DNS
		t.Errorf("righe = %d: %q", n, msg)
	}
}

// /status fotografa aperti e chiusi, con giocatori e indirizzo fisso.
func TestStatusMsg(t *testing.T) {
	st, _, tg, _ := setup(t)
	st.CreateSpace("SkyFactory", "minecraft", nil)
	lk, _, err := st.AcquireLock("miomondo", "steve",
		map[string]string{"host": "10.147.17.20", "port": "25565"}, 90)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.HeartbeatLock("miomondo", lk.Session, []string{"alex", "bob"}, false); err != nil {
		t.Fatal(err)
	}
	msg := tg.statusMsg()
	for _, frag := range []string{"📊", "🟢", "miomondo", "steve", "alex, bob",
		"zerotier.miomondo.internal", "⚪", "SkyFactory", "chiuso"} {
		if !strings.Contains(msg, frag) {
			t.Errorf("statusMsg senza %q:\n%s", frag, msg)
		}
	}
}

// Sessione viva che non pusha da troppo: un avviso, uno solo, e il push
// successivo riarma il watchdog.
func TestPushWatchdog(t *testing.T) {
	st, _, tg, f := setup(t)
	if _, _, err := st.AcquireLock("miomondo", "steve", nil, 90); err != nil {
		t.Fatal(err)
	}
	tg.adopt()
	go tg.sender(context.Background())

	tg.sweepPushWatchdog()
	f.wantSilence(t) // appena aperto: tutto ok

	s := tg.open["miomondo"]
	s.lastPush = time.Now().Add(-pushWarnAfter - time.Minute)
	tg.open["miomondo"] = s
	tg.sweepPushWatchdog()
	f.want(t, "⚠️", "miomondo", "steve", "non salva")

	tg.sweepPushWatchdog()
	f.wantSilence(t) // una volta sola

	tg.handle(events.Event{Type: "push", Space: "miomondo"})
	if s := tg.open["miomondo"]; s.pushWarned || time.Since(s.lastPush) > time.Second {
		t.Error("il push non ha riarmato il watchdog")
	}
}

func TestSenzaConfigDisattivo(t *testing.T) {
	if New("", "-100999", "", nil, nil) != nil || New("tok", "", "", nil, nil) != nil {
		t.Error("senza token o chat il bot deve restare spento")
	}
}

func TestDurata(t *testing.T) {
	for _, c := range []struct {
		d    time.Duration
		want string
	}{
		{30 * time.Second, ""},
		{5 * time.Minute, "5m"},
		{90 * time.Minute, "1h 30m"},
		{3 * time.Hour, "3h 0m"},
	} {
		if got := dur(c.d); got != c.want {
			t.Errorf("dur(%s) = %q, atteso %q", c.d, got, c.want)
		}
	}
}
