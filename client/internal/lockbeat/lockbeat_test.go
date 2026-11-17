package lockbeat

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"minesync/client/internal/api"
)

// fakeHub simula il lock di uno spazio con un TTL corto: scade se nessun
// heartbeat arriva entro ttl, come sull'hub vero.
type fakeHub struct {
	mu       sync.Mutex
	ttl      time.Duration
	session  string
	lastBeat time.Time
	beats    int
	expired  bool // il lock è scaduto almeno una volta
	status   int  // se ≠0, ogni heartbeat risponde con questo codice
}

func newFakeHub(t *testing.T, ttl time.Duration) (*fakeHub, *api.Client) {
	h := &fakeHub{ttl: ttl, session: "s1", lastBeat: time.Now()}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || r.URL.Path != "/api/v1/spaces/sp/lock/heartbeat" {
			http.NotFound(w, r)
			return
		}
		h.mu.Lock()
		defer h.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		if h.status != 0 {
			w.WriteHeader(h.status)
			w.Write([]byte(`{"error":"finto","code":"locked"}`))
			return
		}
		if time.Since(h.lastBeat) > h.ttl {
			h.expired = true
			w.WriteHeader(http.StatusConflict)
			w.Write([]byte(`{"error":"lock scaduto","code":"locked"}`))
			return
		}
		h.lastBeat = time.Now()
		h.beats++
		w.Write([]byte(`{}`))
	}))
	t.Cleanup(srv.Close)
	return h, api.New(srv.URL)
}

// alive riporta se il lock, visto dall'hub, è ancora valido adesso.
func (h *fakeHub) alive() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return !h.expired && time.Since(h.lastBeat) <= h.ttl
}

func (h *fakeHub) set(status int) {
	h.mu.Lock()
	h.status = status
	h.mu.Unlock()
}

// Un push lungo cinque volte il TTL non perde il lock.
func TestLockVivoDuranteUnPushLungo(t *testing.T) {
	ttl := 150 * time.Millisecond
	h, c := newFakeHub(t, ttl)
	pctx, stop := Keep(context.Background(), c, "sp", "s1", 30*time.Millisecond)
	end := time.Now().Add(5 * ttl)
	for time.Now().Before(end) { // il "push"
		if !h.alive() {
			t.Fatal("lock scaduto durante il push")
		}
		if pctx.Err() != nil {
			t.Fatalf("push annullato senza motivo: %v", context.Cause(pctx))
		}
		time.Sleep(5 * time.Millisecond)
	}
	stop()
	stop() // idempotente
	if Err(pctx) != nil {
		t.Errorf("stop non è una perdita: %v", Err(pctx))
	}
	h.mu.Lock()
	beats := h.beats
	h.mu.Unlock()
	if beats < 5 {
		t.Errorf("solo %d heartbeat", beats)
	}
	// dopo stop non partono più heartbeat
	time.Sleep(100 * time.Millisecond)
	h.mu.Lock()
	if h.beats != beats {
		t.Errorf("heartbeat dopo stop: %d → %d", beats, h.beats)
	}
	h.mu.Unlock()
}

// Il lock forzato da un altro (409) annulla il push con ErrLockLost.
func TestLockPersoAnnullaIlPush(t *testing.T) {
	h, c := newFakeHub(t, time.Second)
	pctx, stop := Keep(context.Background(), c, "sp", "s1", 20*time.Millisecond)
	defer stop()
	time.Sleep(50 * time.Millisecond)
	if pctx.Err() != nil {
		t.Fatal("annullato troppo presto")
	}
	h.set(http.StatusConflict)
	select {
	case <-pctx.Done():
	case <-time.After(2 * time.Second):
		t.Fatal("perdita del lock non rilevata")
	}
	if !errors.Is(Err(pctx), ErrLockLost) {
		t.Errorf("causa: %v", context.Cause(pctx))
	}
	if !strings.Contains(Err(pctx).Error(), "lock") {
		t.Errorf("messaggio poco chiaro: %q", Err(pctx))
	}
}

// Spazio cancellato (404) → ErrSpaceGone.
func TestSpazioSparito(t *testing.T) {
	h, c := newFakeHub(t, time.Second)
	h.set(http.StatusNotFound)
	pctx, stop := Keep(context.Background(), c, "sp", "s1", 10*time.Millisecond)
	defer stop()
	select {
	case <-pctx.Done():
	case <-time.After(2 * time.Second):
		t.Fatal("spazio sparito non rilevato")
	}
	if !errors.Is(Err(pctx), ErrSpaceGone) {
		t.Errorf("causa: %v", context.Cause(pctx))
	}
}

// Un errore transitorio (500, rete) non è una perdita: si riprova.
func TestErroreTransitorioNonAnnulla(t *testing.T) {
	h, c := newFakeHub(t, time.Second)
	h.set(http.StatusInternalServerError)
	pctx, stop := Keep(context.Background(), c, "sp", "s1", 10*time.Millisecond)
	time.Sleep(80 * time.Millisecond)
	if pctx.Err() != nil {
		t.Fatalf("un 500 ha annullato il push: %v", context.Cause(pctx))
	}
	h.set(0)
	time.Sleep(40 * time.Millisecond)
	stop()
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.beats == 0 {
		t.Error("nessun heartbeat riuscito dopo il ritorno dell'hub")
	}
}

// La cancellazione del chiamante (es. Ctrl+C) non è una perdita del lock.
func TestCancellazioneDelChiamante(t *testing.T) {
	_, c := newFakeHub(t, time.Second)
	ctx, cancel := context.WithCancel(context.Background())
	pctx, stop := Keep(ctx, c, "sp", "s1", 10*time.Millisecond)
	defer stop()
	cancel()
	<-pctx.Done()
	if Err(pctx) != nil {
		t.Errorf("Ctrl+C scambiato per lock perso: %v", Err(pctx))
	}
}
