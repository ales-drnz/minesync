package ztauth

import (
	"errors"
	"sync/atomic"
	"testing"
	"time"
)

// S11: con la cache valida Lookup non aspetta ztnet; le fetch non si
// sovrappongono; con ztnet giù da troppo si nega.
func TestLookupCacheAndBackgroundRefresh(t *testing.T) {
	var calls atomic.Int32
	release := make(chan struct{})
	slow := atomic.Bool{}
	r := newResolver([]string{"Alex"}, func() (map[string]member, error) {
		calls.Add(1)
		if slow.Load() {
			<-release
		}
		return map[string]member{"10.0.0.1": {Name: "alex", ID: "abc"}}, nil
	})
	// prima lookup: cache vuota, aspetta la fetch
	if name, admin, ok := r.Lookup("10.0.0.1"); !ok || name != "alex" || !admin {
		t.Fatalf("lookup iniziale: %q %v %v", name, admin, ok)
	}
	if _, _, ok := r.Lookup("10.0.0.9"); ok {
		t.Fatal("IP sconosciuto accettato")
	}
	// cache scaduta ma recente: risposta immediata, refresh in background lento
	slow.Store(true)
	r.mu.Lock()
	r.fetched = time.Now().Add(-time.Minute)
	r.lastTry = time.Time{}
	r.mu.Unlock()
	done := make(chan struct{})
	go func() {
		for i := 0; i < 20; i++ {
			if _, _, ok := r.Lookup("10.0.0.1"); !ok {
				t.Error("lookup negata durante il refresh")
			}
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Lookup bloccata in attesa di ztnet")
	}
	// il refresh parte in una goroutine: aspetta che sia entrato nella fetch
	for deadline := time.Now().Add(2 * time.Second); calls.Load() < 2 && time.Now().Before(deadline); {
		time.Sleep(time.Millisecond)
	}
	close(release)
	if c := calls.Load(); c != 2 {
		t.Fatalf("fetch eseguite %d volte, attese 2 (singleflight)", c)
	}
}

func TestLookupDeniesWhenTooStale(t *testing.T) {
	r := newResolver(nil, func() (map[string]member, error) { return nil, errors.New("giù") })
	r.byIP = map[string]member{"10.0.0.1": {Name: "alex"}}
	r.fetched = time.Now().Add(-10 * time.Minute)
	if _, _, ok := r.Lookup("10.0.0.1"); ok {
		t.Fatal("cache vecchia di 10 minuti con ztnet giù: accesso concesso")
	}
	var nilR *Resolver
	if _, _, ok := nilR.Lookup("10.0.0.1"); ok {
		t.Fatal("resolver nil ha autenticato")
	}
}
