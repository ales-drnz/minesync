package notify

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"minesync/server/internal/events"
	"minesync/server/internal/store"
)

// fakeTG finge le API di Telegram e raccoglie i messaggi inviati.
type fakeTG struct {
	*httptest.Server
	msgs      chan sent
	cmds      chan tgCmd // comandi da consegnare al prossimo getUpdates
	polls     atomic.Int64
	sendCode  atomic.Int64 // status di sendMessage (0 = 200)
	deadTopic atomic.Int64 // topic eliminato: sendMessage lì risponde "message thread not found"
	// throttle: quante risposte 429 dare ancora, con retry_after = retryAfter secondi
	throttle   atomic.Int64
	retryAfter atomic.Int64
	sends      atomic.Int64 // chiamate a sendMessage (anche rifiutate)
}

// playInfo: le info del lock di una sessione di gioco (client 3.2).
func playInfo() map[string]string { return map[string]string{"action": "play"} }

// sent: un messaggio ricevuto; thread = message_thread_id (0 = assente).
type sent struct {
	chat, text string
	thread     int64
}

// tgCmd: un comando nel gruppo; thread > 0 = scritto in quel topic.
type tgCmd struct {
	chat   int64
	text   string
	thread int64
}

func newFakeTG(t *testing.T) *fakeTG {
	t.Helper()
	f := &fakeTG{msgs: make(chan sent, 16), cmds: make(chan tgCmd, 4)}
	var upd atomic.Int64
	f.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/getUpdates") {
			f.polls.Add(1)
			select {
			case c := <-f.cmds:
				topic := ""
				if c.thread > 0 {
					topic = fmt.Sprintf(`,"message_thread_id":%d,"is_topic_message":true`, c.thread)
				}
				fmt.Fprintf(w, `{"ok":true,"result":[{"update_id":%d,"message":{"text":%q,"chat":{"id":%d}%s}}]}`,
					upd.Add(1), c.text, c.chat, topic)
			default:
				w.Write([]byte(`{"ok":true,"result":[]}`)) // nessun comando
			}
			return
		}
		f.sends.Add(1)
		if f.throttle.Add(-1) >= 0 {
			w.WriteHeader(http.StatusTooManyRequests)
			fmt.Fprintf(w, `{"ok":false,"error_code":429,"description":"Too Many Requests: retry after %d","parameters":{"retry_after":%d}}`,
				f.retryAfter.Load(), f.retryAfter.Load())
			return
		}
		if c := f.sendCode.Load(); c != 0 {
			w.WriteHeader(int(c))
			w.Write([]byte(`{"ok":false,"error_code":400,"description":"Bad Request: chat not found"}`))
			return
		}
		body, _ := io.ReadAll(r.Body)
		var req struct {
			ChatID string `json:"chat_id"`
			Text   string `json:"text"`
			Thread *int64 `json:"message_thread_id"`
		}
		if err := json.Unmarshal(body, &req); err != nil {
			t.Errorf("body non JSON: %v", err)
		}
		var th int64
		if req.Thread != nil {
			th = *req.Thread
			if th <= 1 {
				t.Errorf("message_thread_id %d: Telegram lo rifiuta (il Generale va senza)", th)
			}
		}
		if d := f.deadTopic.Load(); d != 0 && th == d {
			w.WriteHeader(400)
			w.Write([]byte(`{"ok":false,"error_code":400,"description":"Bad Request: message thread not found"}`))
			return
		}
		f.msgs <- sent{req.ChatID, req.Text, th}
		w.Write([]byte(`{"ok":true}`))
	}))
	t.Cleanup(f.Close)
	return f
}

// want attende un messaggio e verifica che contenga tutti i frammenti.
func (f *fakeTG) want(t *testing.T, frags ...string) {
	t.Helper()
	f.wantIn(t, "-100999", frags...)
}

// wantIn attende un messaggio nella chat indicata.
func (f *fakeTG) wantIn(t *testing.T, chat string, frags ...string) {
	t.Helper()
	f.next(t, chat, frags...)
}

// next attende un messaggio nella chat indicata e lo restituisce.
func (f *fakeTG) next(t *testing.T, chat string, frags ...string) sent {
	t.Helper()
	select {
	case m := <-f.msgs:
		msg := m.text
		if m.chat != chat {
			t.Errorf("chat_id = %q, attesa %q", m.chat, chat)
		}
		for _, s := range frags {
			if !strings.Contains(msg, s) {
				t.Errorf("messaggio %q: manca %q", msg, s)
			}
		}
		return m
	case <-time.After(3 * time.Second):
		t.Fatalf("nessun messaggio (attesi %v)", frags)
	}
	return sent{}
}

// wantTopic attende un messaggio nel topic thread (0 = chat principale).
func (f *fakeTG) wantTopic(t *testing.T, thread int64, frags ...string) {
	t.Helper()
	if m := f.next(t, "-100999", frags...); m.thread != thread {
		t.Errorf("message_thread_id = %d, atteso %d (%q)", m.thread, thread, m.text)
	}
}

func (f *fakeTG) wantSilence(t *testing.T) {
	t.Helper()
	select {
	case m := <-f.msgs:
		t.Fatalf("messaggio inatteso in %s: %q", m.chat, m.text)
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
	tg := New("internal", st, bus)
	tg.base = f.URL
	tg.coalesce = 0 // chiusure annunciate subito (i test del raggruppamento lo alzano)
	tg.Apply(fullCfg())
	return st, bus, tg, f
}

// fullCfg: bot attivo con tutte le notifiche.
func fullCfg() Config {
	return Config{Enabled: true, Token: "tok", ChatID: "-100999",
		Open: true, Close: true, Alerts: true, Status: true}
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
	if _, _, err := st.AcquireLock("miomondo", "steve", playInfo(), 1); err != nil {
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
	if _, _, err := st.AcquireLock("miomondo", "steve", playInfo(), 90); err != nil {
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
	if _, err := st.HeartbeatLock("miomondo", lk.Session, "", []string{"alex", "bob"}, false); err != nil {
		t.Fatal(err)
	}
	msg := tg.statusMsg(nil)
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
	if _, _, err := st.AcquireLock("miomondo", "steve", playInfo(), 90); err != nil {
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
	for _, c := range []Config{
		{Enabled: true, ChatID: "-100999"},
		{Enabled: true, Token: "tok"},
		{Token: "tok", ChatID: "-100999"},
	} {
		if c.active() {
			t.Errorf("%+v: senza token, chat o enabled il bot deve restare spento", c)
		}
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
