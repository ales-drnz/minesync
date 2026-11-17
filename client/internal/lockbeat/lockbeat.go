// Package lockbeat tiene vivo il lock di uno spazio per tutta la durata di un
// push manuale (TUI `u`, `minesync push`), come fa la sessione di gioco col
// suo heartbeat (C2 della 3.2.0).
//
// Senza heartbeat un push più lungo del TTL del lock (minuti di upload su una
// rete lenta) perdeva il lock a metà: l'hub lo considerava scaduto, un altro
// poteva prenderlo, e il commit finale veniva rifiutato dopo aver caricato
// tutto.
//
// Uso:
//
//	pctx, stop := lockbeat.Keep(ctx, client, id, lk.Session, lockbeat.DefaultEvery)
//	res, err := eng.Push(pctx, msg, false)
//	stop()
//	if err != nil {
//		if lerr := lockbeat.Err(pctx); lerr != nil {
//			err = lerr // il push è stato annullato perché il lock non è più nostro
//		}
//	}
//
// La perdita del lock si segnala cancellando il contesto restituito da Keep
// con causa ErrLockLost (o ErrSpaceGone): il push in corso si interrompe da
// solo e Err la riconosce.
package lockbeat

import (
	"context"
	"errors"
	"net/http"
	"sync"
	"time"

	"minesync/client/internal/api"
	"minesync/client/internal/i18n"
)

// DefaultEvery è il ritmo degli heartbeat (lo stesso della sessione di gioco).
const DefaultEvery = 20 * time.Second

// ErrLockLost: durante il push l'hub ha risposto che il lock non è più nostro
// (forzato da un altro o scaduto). Il push viene annullato.
var ErrLockLost = i18n.NewError("lock perso durante il push (forzato da un altro o scaduto): push annullato, i file locali sono intatti")

// ErrSpaceGone: durante il push lo spazio è sparito dall'hub.
var ErrSpaceGone = i18n.NewError("lo spazio non esiste più sull'hub: push annullato, i file locali sono intatti")

// errStopped è la causa della cancellazione a push finito (non è una perdita).
var errStopped = errors.New("lockbeat: fermato")

// Keep manda un heartbeat ogni every (≤0 → DefaultEvery) per il lock
// (spaceID, session) finché ctx vive o finché non si chiama stop.
//
// Restituisce un contesto derivato da ctx da usare per il push: se l'hub
// risponde 409 (lock non più nostro) viene cancellato con causa ErrLockLost,
// se risponde 404 con causa ErrSpaceGone. Gli errori di rete sono
// transitori: si riprova al giro dopo (il TTL dell'hub copre qualche battito
// mancato). stop è idempotente e ritorna solo a goroutine terminata.
func Keep(ctx context.Context, c *api.Client, spaceID, session string, every time.Duration) (context.Context, func()) {
	if every <= 0 {
		every = DefaultEvery
	}
	pctx, cancel := context.WithCancelCause(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		t := time.NewTicker(every)
		defer t.Stop()
		for {
			select {
			case <-pctx.Done():
				return
			case <-t.C:
			}
			// un heartbeat appeso non deve saltare i successivi
			hctx, hcancel := context.WithTimeout(pctx, max(every, time.Second))
			_, err := c.LockHeartbeat(hctx, spaceID, session, nil, false)
			hcancel()
			if lost := classify(err); lost != nil {
				cancel(lost)
				return
			}
		}
	}()
	var once sync.Once
	return pctx, func() {
		once.Do(func() {
			cancel(errStopped)
			<-done
		})
	}
}

// classify traduce l'esito di un heartbeat: nil se il lock è ancora nostro (o
// se l'errore è transitorio), altrimenti la causa della perdita.
func classify(err error) error {
	var ae *api.APIError
	if err == nil || !errors.As(err, &ae) {
		return nil
	}
	switch ae.Status {
	case http.StatusConflict:
		return ErrLockLost
	case http.StatusNotFound, http.StatusGone:
		return ErrSpaceGone
	}
	return nil
}

// Err riporta perché il contesto di Keep è stato cancellato, se è stato per
// la perdita del lock (ErrLockLost) o dello spazio (ErrSpaceGone); nil in
// tutti gli altri casi (ctx ancora vivo, stop, cancellazione del chiamante).
func Err(ctx context.Context) error {
	cause := context.Cause(ctx)
	if errors.Is(cause, ErrLockLost) || errors.Is(cause, ErrSpaceGone) {
		return cause
	}
	return nil
}
