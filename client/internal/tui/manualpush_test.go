package tui

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"minesync/client/internal/api"
	"minesync/client/internal/lockbeat"
	"minesync/client/internal/syncx"
	"minesync/client/internal/syncx/fakehub"
)

// slowHub: fakehub con l'upload dei blob rallentato; onPut gira al primo PUT.
func slowHub(t *testing.T, delay time.Duration, onPut func(*fakehub.Hub)) (*fakehub.Hub, *syncx.Engine) {
	t.Helper()
	hub := fakehub.New()
	t.Cleanup(hub.Close)
	inner := hub.Srv.Config.Handler
	var once sync.Once
	hub.Srv.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "PUT" {
			once.Do(func() {
				if onPut != nil {
					onPut(hub)
				}
			})
			time.Sleep(delay)
		}
		inner.ServeHTTP(w, r)
	})
	local := t.TempDir()
	for _, n := range []string{"a.txt", "b.txt", "c.txt"} {
		if err := os.WriteFile(filepath.Join(local, n), []byte("contenuto "+n), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	eng := &syncx.Engine{Client: api.New(hub.URL()), SpaceID: "sp", LocalPath: local,
		CachePath: filepath.Join(t.TempDir(), "sp.json"), Matcher: syncx.NewMatcher(nil)}
	return hub, eng
}

func fastBeats(t *testing.T) {
	prev := pushBeatEvery
	pushBeatEvery = 10 * time.Millisecond
	t.Cleanup(func() { pushBeatEvery = prev })
}

// Il lock forzato da un altro a metà push annulla il push (niente commit) con
// un errore chiaro, invece di caricare tutto e farsi rifiutare il commit.
func TestManualPushLockPersoAMeta(t *testing.T) {
	fastBeats(t)
	hub, eng := slowHub(t, 80*time.Millisecond, (*fakehub.Hub).StealLock)
	_, err := manualPush(context.Background(), eng.Client, eng, "sp", "test")
	if !errors.Is(err, lockbeat.ErrLockLost) {
		t.Fatalf("errore %v, atteso lock perso", err)
	}
	hub.Lock()
	defer hub.Unlock()
	if hub.Commits != 0 {
		t.Errorf("commit eseguito con il lock perso")
	}
}

// Senza guasti il push lento va in porto (gli heartbeat non disturbano).
func TestManualPushLentoRiesce(t *testing.T) {
	fastBeats(t)
	hub, eng := slowHub(t, 40*time.Millisecond, nil)
	res, err := manualPush(context.Background(), eng.Client, eng, "sp", "test")
	if err != nil {
		t.Fatal(err)
	}
	if res.NoChange || hub.Head() != 1 {
		t.Errorf("push non arrivato: %+v head=%d", res, hub.Head())
	}
}
