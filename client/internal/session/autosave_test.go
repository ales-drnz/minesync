package session

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"minesync/client/internal/i18n"
	"minesync/client/internal/mc"
)

// Il binario dei test fa anche da finto server Minecraft (stdin/stdout come
// quello vero), quando lo si lancia con MINESYNC_FAKE_SERVER=1.
func TestMain(m *testing.M) {
	if os.Getenv("MINESYNC_FAKE_SERVER") == "1" {
		fakeServer()
		return
	}
	os.Exit(m.Run())
}

// fakeServer: annuncia l'avvio, esegue save-off/save-all flush/save-on/stop
// come il server vero e registra ogni comando (con l'istante) nel file
// MINESYNC_FAKE_LOG. "crash" esce con errore. Con MINESYNC_FAKE_LATE scrive
// quel file poco DOPO la conferma di salvataggio (un mod che non rispetta il
// save-off).
func fakeServer() {
	logf, err := os.OpenFile(os.Getenv("MINESYNC_FAKE_LOG"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		os.Exit(2)
	}
	late := os.Getenv("MINESYNC_FAKE_LATE")
	out := func(s string) { fmt.Printf("[12:00:00] [Server thread/INFO]: %s\n", s) }
	out(`Done (0.1s)! For help, type "help"`)
	sc := bufio.NewScanner(os.Stdin)
	for sc.Scan() {
		cmd := strings.TrimSpace(sc.Text())
		fmt.Fprintf(logf, "%d %s\n", time.Now().UnixNano(), cmd)
		logf.Sync()
		switch cmd {
		case "save-off":
			out("Automatic saving is now disabled")
		case "save-all flush":
			out("Saving the game (this may take a moment!)")
			out("Saved the game")
			if late != "" {
				go func() {
					time.Sleep(400 * time.Millisecond)
					os.WriteFile(late, []byte(strconv.FormatInt(time.Now().UnixNano(), 10)), 0o644)
				}()
			}
		case "save-on":
			out("Automatic saving is now enabled")
		case "stop":
			out("Stopping server")
			os.Exit(0)
		case "crash":
			os.Exit(3)
		}
	}
}

type cmdEntry struct {
	at  time.Time
	cmd string
}

// e2e: una sessione vera contro il finto hub e il finto server.
type e2e struct {
	t    *testing.T
	f    *fixture
	s    *Session
	log  string
	mu   sync.Mutex
	evs  []Event
	done chan struct{}
	err  error
}

func startE2E(t *testing.T, prep func(f *fixture)) *e2e {
	t.Helper()
	setVar(t, &quiesceStable, 300*time.Millisecond)
	setVar(t, &quiesceCap, 3*time.Second)
	setVar(t, &quiescePoll, 50*time.Millisecond)
	setVar(t, &flushWait, 5*time.Second)
	t.Setenv("MINESYNC_UPLOAD_LIMIT", "")

	f := newFixture(t)
	f.hub.Commit(map[string][]byte{"server.properties": []byte("server-port=25565")})
	if prep != nil {
		prep(f)
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	e := &e2e{t: t, f: f, log: filepath.Join(t.TempDir(), "cmd.log"), done: make(chan struct{})}
	t.Setenv("MINESYNC_FAKE_SERVER", "1")
	t.Setenv("MINESYNC_FAKE_LOG", e.log)

	lk, err := f.cl.LockAcquire(context.Background(), "sp", PlayLockInfo(nil))
	if err != nil {
		t.Fatal(err)
	}
	e.s = New(Config{
		Client: f.cl, SpaceID: "sp", LocalPath: f.local, CachePath: f.cache,
		Owner: "alice", LockSession: lk.Session,
		AutosaveEvery: time.Second, HeartbeatEvery: 50 * time.Millisecond,
		EmptyStopAfter: -1, MaxRestarts: -1,
	})
	e.s.launchOverride = func() (mc.ServerInfo, string, error) {
		return mc.ServerInfo{Dir: f.local, Launch: []string{exe, "-test.run=^$"}}, "", nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	go e.s.Run(ctx)
	go func() {
		for ev := range e.s.Events() {
			e.mu.Lock()
			e.evs = append(e.evs, ev)
			if ev.Kind == EvDone {
				e.err = ev.Err
			}
			e.mu.Unlock()
		}
		close(e.done)
	}()
	t.Cleanup(func() {
		cancel()
		select {
		case <-e.done:
		case <-time.After(60 * time.Second):
			t.Error("la sessione non si è chiusa")
		}
	})
	e.waitEv("avvio del server", 20*time.Second, func(ev Event) bool {
		return ev.Kind == EvNote && strings.HasPrefix(ev.Note, strings.Split(i18n.S("Server avviato (porta %s)"), "%")[0])
	})
	return e
}

func setVar[T any](t *testing.T, p *T, v T) {
	old := *p
	*p = v
	t.Cleanup(func() { *p = old })
}

// waitEv aspetta un evento (anche già arrivato) e restituisce l'istante in
// cui l'ha visto.
func (e *e2e) waitEv(what string, d time.Duration, pred func(Event) bool) Event {
	e.t.Helper()
	deadline := time.Now().Add(d)
	for {
		e.mu.Lock()
		for _, ev := range e.evs {
			if pred(ev) {
				e.mu.Unlock()
				return ev
			}
		}
		e.mu.Unlock()
		if time.Now().After(deadline) {
			e.t.Fatalf("%s: non arrivato entro %s", what, d)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func (e *e2e) cmds() []cmdEntry {
	b, _ := os.ReadFile(e.log)
	var out []cmdEntry
	for _, l := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		ts, cmd, ok := strings.Cut(l, " ")
		if !ok {
			continue
		}
		n, _ := strconv.ParseInt(ts, 10, 64)
		out = append(out, cmdEntry{time.Unix(0, n), cmd})
	}
	return out
}

func (e *e2e) count(cmd string) int {
	n := 0
	for _, c := range e.cmds() {
		if c.cmd == cmd {
			n++
		}
	}
	return n
}

func (e *e2e) waitDone(d time.Duration) error {
	e.t.Helper()
	select {
	case <-e.done:
	case <-time.After(d):
		e.t.Fatalf("sessione non finita entro %s", d)
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.err
}

func (e *e2e) setBps(bps int) {
	e.f.hub.Lock()
	e.f.hub.UploadBps = bps
	e.f.hub.Unlock()
}

func randData(n int, seed int64) []byte {
	b := make([]byte, n)
	rand.New(rand.NewSource(seed)).Read(b)
	return b
}

func (e *e2e) writeWorld(rel string, data []byte) {
	p := filepath.Join(e.f.local, filepath.FromSlash(rel))
	os.MkdirAll(filepath.Dir(p), 0o755)
	if err := os.WriteFile(p, data, 0o644); err != nil {
		e.t.Fatal(err)
	}
}

func uploading(ev Event) bool { return ev.Kind == EvUpload && ev.Uploading }

// Il cuore della 3.2: con un uplink lento il save-on arriva subito dopo lo
// snapshot (non dopo l'upload), durante l'upload non parte un altro save-off
// (i tick si saltano), il ciclo resta reattivo e a fine upload riparte il
// ciclo successivo.
func TestAutosaveUploadInBackground(t *testing.T) {
	e := startE2E(t, func(f *fixture) {})
	e.setBps(40_000)
	big := randData(200_000, 1)
	e.writeWorld("world/data/big.dat", big)

	e.waitEv("upload in background", 15*time.Second, uploading)
	cs := e.cmds()
	var flushAt, onAt time.Time
	for _, c := range cs {
		switch c.cmd {
		case "save-all flush":
			flushAt = c.at
		case "save-on":
			if !flushAt.IsZero() && onAt.IsZero() {
				onAt = c.at
			}
		}
	}
	if flushAt.IsZero() || onAt.IsZero() {
		t.Fatalf("comandi: %v", cs)
	}
	if d := onAt.Sub(flushAt); d > 3*time.Second {
		t.Errorf("save-on dopo %s dal flush: il server è rimasto in save-off durante l'upload", d)
	}
	// l'upload dura secondi: passano più tick, nessun nuovo save-off
	time.Sleep(2500 * time.Millisecond)
	if !e.s.Uploading() {
		t.Fatal("upload già finito: il finto hub non sta rallentando")
	}
	if n := e.count("save-off"); n != 1 {
		t.Errorf("save-off durante l'upload: %d", n)
	}
	// il ciclo è reattivo: un comando arriva subito al server
	e.s.SendCommand("list")
	time.Sleep(300 * time.Millisecond)
	if e.count("list") != 1 {
		t.Error("console bloccata durante l'upload")
	}

	saved := e.waitEv("autosave completato", 20*time.Second, func(ev Event) bool { return ev.Kind == EvSaved })
	if saved.HubSavedAt.IsZero() || saved.HubSavedAt.After(onAt) {
		t.Errorf("HubSavedAt = %v (snapshot prima del save-on %v)", saved.HubSavedAt, onAt)
	}
	if got := e.f.hub.Files(saved.Gen)["world/data/big.dat"]; len(got) != len(big) {
		t.Errorf("autosave senza il file: %d byte", len(got))
	}
	// l'intervallo è passato durante l'upload: il ciclo successivo parte da sé
	deadline := time.Now().Add(5 * time.Second)
	for e.count("save-off") < 2 && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	if e.count("save-off") < 2 {
		t.Error("nessun ciclo dopo la fine dell'upload")
	}
	if e.count("save-off") > e.count("save-on") {
		// aspetta il save-on del ciclo appena partito
		time.Sleep(2 * time.Second)
	}
	e.s.RequestStop()
	if err := e.waitDone(30 * time.Second); err != nil {
		t.Fatalf("sessione: %v", err)
	}
	if e.count("save-off") != e.count("save-on") {
		t.Errorf("save-off %d, save-on %d: un save-off è rimasto senza save-on", e.count("save-off"), e.count("save-on"))
	}
}

// Stop durante un upload lento: l'upload si annulla, il push finale (dai
// file veri) arriva sull'hub e la sessione chiude. Un salvataggio manuale
// chiesto durante l'upload viene messo in coda, non sovrapposto.
func TestStopDuranteUpload(t *testing.T) {
	e := startE2E(t, nil)
	e.setBps(10_000)
	big := randData(300_000, 2)
	e.writeWorld("world/data/big.dat", big)
	e.waitEv("upload in background", 15*time.Second, uploading)

	e.s.RequestSaveNow()
	e.waitEv("salvataggio in coda", 3*time.Second, func(ev Event) bool {
		return ev.Kind == EvNote && ev.Note == i18n.S("Salvataggio già in corso: ne parte un altro appena finisce.")
	})
	if n := e.count("save-off"); n != 1 {
		t.Errorf("save-off: %d", n)
	}

	e.setBps(0)
	start := time.Now()
	e.s.RequestStop()
	if err := e.waitDone(20 * time.Second); err != nil {
		t.Fatalf("sessione: %v", err)
	}
	if el := time.Since(start); el > 15*time.Second {
		t.Errorf("stop dopo %s: ha aspettato l'upload lento", el)
	}
	head := e.f.hub.Head()
	if got := e.f.hub.Files(head)["world/data/big.dat"]; len(got) != len(big) {
		t.Errorf("push finale senza il file (%d byte)", len(got))
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, ev := range e.evs {
		if ev.Kind == EvSaved {
			t.Error("l'autosave annullato risulta completato")
		}
	}
}

// Crash del server durante un upload: il ciclo della sessione non è bloccato,
// il crash si vede subito e lo stato va sull'hub con il push post-crash.
func TestCrashDuranteUpload(t *testing.T) {
	e := startE2E(t, nil)
	e.setBps(10_000)
	big := randData(300_000, 3)
	e.writeWorld("world/data/big.dat", big)
	e.waitEv("upload in background", 15*time.Second, uploading)

	e.setBps(0) // il push post-crash va a piena velocità
	e.s.SendCommand("crash")
	sent := time.Now()
	e.waitEv("crash rilevato", 5*time.Second, func(ev Event) bool {
		return ev.Kind == EvNote && ev.Note == i18n.S("Server terminato in modo anomalo: salvataggio dello stato sull'hub.")
	})
	if el := time.Since(sent); el > 5*time.Second {
		t.Errorf("crash visto dopo %s", el)
	}
	if err := e.waitDone(20 * time.Second); err == nil {
		t.Error("la sessione crashata finisce senza errore")
	}
	if got := e.f.hub.Files(e.f.hub.Head())["world/data/big.dat"]; len(got) != len(big) {
		t.Errorf("push post-crash senza il file (%d byte)", len(got))
	}
}

// Quiete: un file scritto dopo la conferma (mod che ignora il save-off)
// entra nello snapshot, che aspetta la fine delle scritture.
func TestQuieteAspettaScritturaTardiva(t *testing.T) {
	t.Setenv("MINESYNC_FAKE_LATE", "tardi.dat")
	e := startE2E(t, nil)
	saved := e.waitEv("autosave", 20*time.Second, func(ev Event) bool { return ev.Kind == EvSaved })
	if _, ok := e.f.hub.Files(saved.Gen)["tardi.dat"]; !ok {
		t.Error("lo snapshot non ha aspettato il file scritto dopo la conferma")
	}
	e.s.RequestStop()
	if err := e.waitDone(20 * time.Second); err != nil {
		t.Fatal(err)
	}
}

// H: spazio cancellato dall'hub durante la sessione → stop pulito con
// ErrSpaceGone, niente "hub irraggiungibile" all'infinito.
func TestSpazioCancellato(t *testing.T) {
	e := startE2E(t, nil)
	e.f.hub.Lock()
	e.f.hub.SpaceGone = true
	e.f.hub.Unlock()
	err := e.waitDone(20 * time.Second)
	if !errors.Is(err, ErrSpaceGone) {
		t.Fatalf("errore = %v, atteso ErrSpaceGone", err)
	}
	if e.count("stop") != 1 {
		t.Error("server non fermato")
	}
}

// Un file illeggibile (bloccato, antivirus) non fa fallire l'autosave: si
// salta con un avviso e sull'hub resta la sua versione precedente.
func TestAutosaveFileIlleggibile(t *testing.T) {
	if runtime.GOOS == "windows" || os.Getuid() == 0 {
		t.Skip("permessi non applicabili")
	}
	e := startE2E(t, func(f *fixture) {
		f.hub.Commit(map[string][]byte{"server.properties": []byte("server-port=25565"), "bloccato.dat": []byte("hub")})
	})
	e.writeWorld("bloccato.dat", []byte("locale"))
	p := filepath.Join(e.f.local, "bloccato.dat")
	os.Chmod(p, 0)
	defer os.Chmod(p, 0o644)
	e.writeWorld("nuovo.dat", []byte("nuovo"))
	saved := e.waitEv("autosave", 20*time.Second, func(ev Event) bool { return ev.Kind == EvSaved })
	files := e.f.hub.Files(saved.Gen)
	if string(files["bloccato.dat"]) != "hub" || string(files["nuovo.dat"]) != "nuovo" {
		t.Errorf("generazione: bloccato=%q nuovo=%q", files["bloccato.dat"], files["nuovo.dat"])
	}
	e.mu.Lock()
	warned := false
	for _, ev := range e.evs {
		if ev.Kind == EvNote && ev.Warn && strings.Contains(ev.Note, "bloccato.dat") {
			warned = true
		}
	}
	e.mu.Unlock()
	if !warned {
		t.Error("nessun avviso sul file illeggibile")
	}
	os.Chmod(p, 0o644)
	e.s.RequestStop()
	if err := e.waitDone(20 * time.Second); err != nil {
		t.Fatal(err)
	}
}

// C2: le info del lock di gioco dicono "play".
func TestPlayLockInfo(t *testing.T) {
	info := PlayLockInfo(map[string]string{"host": "10.0.0.1"})
	if info["action"] != "play" || info["host"] != "10.0.0.1" {
		t.Errorf("info = %v", info)
	}
}
