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

// Con ZTNET giù si continua con l'ultimo elenco noto (anche dopo ore), senza
// aspettare ZTNET; oltre la grace si nega.
func TestLookupServesKnownMembersWhileZTNETDown(t *testing.T) {
	var calls atomic.Int32
	r := newResolver(nil, func() (map[string]member, error) {
		calls.Add(1)
		return nil, errors.New("giù")
	})
	r.byIP = map[string]member{"10.0.0.1": {Name: "alex"}}
	r.fetched = time.Now().Add(-3 * time.Hour)
	start := time.Now()
	if name, _, ok := r.Lookup("10.0.0.1"); !ok || name != "alex" {
		t.Fatal("ZTNET giù da 3 ore: il membro noto è stato chiuso fuori")
	}
	if time.Since(start) > time.Second {
		t.Fatal("Lookup ha aspettato ZTNET con la cache disponibile")
	}
	if _, _, ok := r.Lookup("10.0.0.9"); ok {
		t.Fatal("IP sconosciuto accettato")
	}
	// il refresh fallito non svuota la cache
	for deadline := time.Now().Add(2 * time.Second); time.Now().Before(deadline); time.Sleep(time.Millisecond) {
		r.mu.Lock()
		busy := r.refreshing != nil
		r.mu.Unlock()
		if calls.Load() > 0 && !busy {
			break
		}
	}
	r.mu.Lock()
	down := r.down
	r.mu.Unlock()
	if !down {
		t.Error("ZTNET irraggiungibile non registrato")
	}
	if _, _, ok := r.Lookup("10.0.0.1"); !ok {
		t.Fatal("membro perso dopo un aggiornamento fallito")
	}
	// oltre la grace si nega
	r.SetGrace(time.Hour)
	if _, _, ok := r.Lookup("10.0.0.1"); ok {
		t.Fatal("ZTNET giù oltre la grace: accesso concesso")
	}
	// grace ≤0: senza limite
	r.SetGrace(0)
	if _, _, ok := r.Lookup("10.0.0.1"); !ok {
		t.Fatal("grace illimitata: accesso negato")
	}
	var nilR *Resolver
	if _, _, ok := nilR.Lookup("10.0.0.1"); ok {
		t.Fatal("resolver nil ha autenticato")
	}
}

// Un membro tolto in ZTNET sparisce solo quando un aggiornamento riuscito lo
// dice; il ritorno di ZTNET azzera lo stato "giù".
func TestMemberRemovedOnlyBySuccessfulRefresh(t *testing.T) {
	var fail atomic.Bool
	r := newResolver(nil, func() (map[string]member, error) {
		if fail.Load() {
			return nil, errors.New("giù")
		}
		return map[string]member{"10.0.0.2": {Name: "bob"}}, nil // alex tolto
	})
	r.byIP = map[string]member{"10.0.0.1": {Name: "alex"}}
	r.fetched = time.Now().Add(-time.Minute)
	r.down = true
	refresh := func() {
		r.mu.Lock()
		r.lastTry = time.Time{}
		ch := r.refreshLocked()
		r.mu.Unlock()
		<-ch
	}
	fail.Store(true)
	refresh()
	if _, _, ok := r.Lookup("10.0.0.1"); !ok {
		t.Fatal("alex perso con ZTNET giù")
	}
	fail.Store(false)
	refresh()
	if _, _, ok := r.Lookup("10.0.0.1"); ok {
		t.Fatal("alex ancora accettato dopo che ZTNET l'ha tolto")
	}
	if _, _, ok := r.Lookup("10.0.0.2"); !ok {
		t.Fatal("bob non riconosciuto")
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.down {
		t.Error("ZTNET tornato ma ancora segnato giù")
	}
}
