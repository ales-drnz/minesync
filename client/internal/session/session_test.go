package session

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"minesync/client/internal/api"
	"minesync/client/internal/syncx"
	"minesync/client/internal/syncx/fakehub"
)

type fixture struct {
	hub   *fakehub.Hub
	local string
	cache string
	cl    *api.Client
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	hub := fakehub.New()
	t.Cleanup(hub.Close)
	root := t.TempDir()
	f := &fixture{hub: hub, local: filepath.Join(root, "mondo"),
		cache: filepath.Join(t.TempDir(), "sp.json"), cl: api.New(hub.URL())}
	if err := os.MkdirAll(f.local, 0o755); err != nil {
		t.Fatal(err)
	}
	return f
}

// session apre una sessione col lock acquisito (senza avviarla).
func (f *fixture) session(t *testing.T, discard bool) *Session {
	t.Helper()
	lk, err := f.cl.LockAcquire(context.Background(), "sp", nil)
	if err != nil {
		t.Fatal(err)
	}
	return New(Config{
		Client: f.cl, SpaceID: "sp", LocalPath: f.local, CachePath: f.cache,
		Owner: "alice", LockSession: lk.Session, DiscardLocal: discard,
		HeartbeatEvery: 10 * time.Millisecond,
	})
}

// pullBase porta la cartella alla HEAD dell'hub con un engine qualunque.
func (f *fixture) pullBase(t *testing.T) {
	t.Helper()
	eng := &syncx.Engine{Client: f.cl, SpaceID: "sp", LocalPath: f.local, CachePath: f.cache,
		Matcher: syncx.NewMatcher(nil)}
	if _, err := eng.Pull(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func (f *fixture) write(t *testing.T, rel, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(f.local, rel), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// D1/C7: all'avvio della sessione, modifiche locali non divergenti (push
// finale fallito l'ultima volta) vengono pushate prima del pull, non perse.
func TestAvvioFastForwardDelleModificheLocali(t *testing.T) {
	f := newFixture(t)
	f.hub.Commit(map[string][]byte{"level.dat": []byte("v1")})
	f.pullBase(t)
	f.write(t, "level.dat", "serata non pushata")

	s := f.session(t, false)
	plan, err := s.syncAtStart(context.Background())
	if err != nil {
		t.Fatalf("syncAtStart: %v", err)
	}
	if f.hub.Head() != 2 || string(f.hub.Files(2)["level.dat"]) != "serata non pushata" {
		t.Fatalf("modifiche non arrivate sull'hub: HEAD %d", f.hub.Head())
	}
	if plan.Gen != 2 || s.LastGen() != 2 {
		t.Errorf("plan.Gen=%d LastGen=%d, attese 2", plan.Gen, s.LastGen())
	}
	if b, _ := os.ReadFile(filepath.Join(f.local, "level.dat")); string(b) != "serata non pushata" {
		t.Errorf("file locale = %q", b)
	}
}

// Divergenza: la sessione si ferma con il DirtyLocalError (errors.As); con
// DiscardLocal scarta il locale e prosegue.
func TestAvvioDivergenteSiFerma(t *testing.T) {
	f := newFixture(t)
	f.hub.Commit(map[string][]byte{"level.dat": []byte("v1")})
	f.pullBase(t)
	f.write(t, "level.dat", "mia")
	f.hub.Commit(map[string][]byte{"level.dat": []byte("di bob")})

	s := f.session(t, false)
	_, err := s.syncAtStart(context.Background())
	var dirty *syncx.DirtyLocalError
	if !errors.As(err, &dirty) || !dirty.Diverged() {
		t.Fatalf("errore = %v, atteso DirtyLocalError divergente", err)
	}
	if f.hub.Head() != 2 {
		t.Fatalf("l'hub è stato toccato: HEAD %d", f.hub.Head())
	}
	s.releaseLock()

	s = f.session(t, true)
	plan, err := s.syncAtStart(context.Background())
	if err != nil {
		t.Fatalf("con DiscardLocal: %v", err)
	}
	if plan.Backup == "" {
		t.Error("nessun backup delle modifiche scartate")
	}
	if b, _ := os.ReadFile(filepath.Join(f.local, "level.dat")); string(b) != "di bob" {
		t.Errorf("file locale = %q", b)
	}
}

// R6: lock forzato da un altro → avviso bloccante e richiesta di stop.
func TestLockPersoAvvisoBloccante(t *testing.T) {
	f := newFixture(t)
	s := f.session(t, false)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go s.heartbeatLoop(ctx)
	f.hub.StealLock()

	deadline := time.After(5 * time.Second)
	for {
		select {
		case ev := <-s.Events():
			if ev.Kind == EvNote && ev.Alert {
				if !s.isLockLost() {
					t.Fatal("avviso senza lock perso")
				}
				s.mu.Lock()
				stop := s.stopReq
				s.mu.Unlock()
				if !stop {
					t.Error("lock perso ma nessuna richiesta di stop")
				}
				return
			}
		case <-deadline:
			t.Fatal("nessun avviso di lock perso")
		}
	}
}

// Dopo il rilascio volontario, i 409 dell'heartbeat non sono un lock perso.
func TestRilascioNonEUnLockPerso(t *testing.T) {
	f := newFixture(t)
	s := f.session(t, false)
	s.releaseLock()
	s.lockLostAlert(errors.New("409"))
	for {
		select {
		case ev := <-s.Events():
			if ev.Alert {
				t.Fatal("avviso di lock perso dopo un rilascio volontario")
			}
		default:
			return
		}
	}
}
