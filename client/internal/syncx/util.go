package syncx

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"sync"
	"time"

	"minesync/client/internal/config"
	"minesync/client/internal/i18n"
)

// partSuffix: estensione dei file temporanei di download. La scansione li
// ignora sempre: un pull interrotto non deve farli finire sull'hub.
const partSuffix = ".minesyncpart"

// retryBackoff: attesa base tra un tentativo e l'altro (cresce linearmente).
// Variabile per i test.
var retryBackoff = time.Second

// permanentError interrompe retry: l'errore non migliora ritentando.
type permanentError struct{ err error }

func (p *permanentError) Error() string { return p.err.Error() }
func (p *permanentError) Unwrap() error { return p.err }

func permanent(err error) error {
	if err == nil {
		return nil
	}
	return &permanentError{err}
}

// retry esegue fn fino a 1+n volte, con attesa crescente tra i tentativi.
// Si ferma subito se il contesto è chiuso o se fn restituisce permanent(err).
func retry(ctx context.Context, n int, fn func() error) error {
	var err error
	for attempt := 0; attempt <= n; attempt++ {
		if attempt > 0 {
			select {
			case <-time.After(time.Duration(attempt) * retryBackoff):
			case <-ctx.Done():
				return ctx.Err()
			}
		}
		err = fn()
		if err == nil {
			return nil
		}
		var p *permanentError
		if errors.As(err, &p) {
			return p.err
		}
		if ctx.Err() != nil {
			return err
		}
	}
	return err
}

// runPool esegue fn su ogni elemento con `workers` goroutine. Al primo errore
// annulla il contesto passato agli altri (gli elementi non ancora iniziati
// vengono saltati) e restituisce quell'errore.
func runPool(ctx context.Context, items []string, fn func(ctx context.Context, item string) error) error {
	cctx, cancel := context.WithCancel(ctx)
	defer cancel()
	jobs := make(chan string)
	var wg sync.WaitGroup
	var firstErr error
	var errOnce sync.Once
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for it := range jobs {
				if cctx.Err() != nil {
					continue
				}
				if err := fn(cctx, it); err != nil {
					errOnce.Do(func() { firstErr = err; cancel() })
				}
			}
		}()
	}
	for _, it := range items {
		jobs <- it
	}
	close(jobs)
	wg.Wait()
	if firstErr == nil && ctx.Err() != nil {
		return ctx.Err()
	}
	return firstErr
}

// hashMismatchError: il contenuto scritto non ha l'hash atteso.
type hashMismatchError struct{ got, want string }

func (e *hashMismatchError) Error() string {
	return i18n.Sf("hash non combacia (%s ≠ %s)", short(e.got), short(e.want))
}

func short(h string) string {
	if len(h) > 12 {
		return h[:12]
	}
	return h
}

// writeVerified materializza dst in modo atomico: fill scrive il contenuto in
// un temporaneo accanto a dst, l'hash SHA-256 viene verificato, il
// temporaneo va su disco (fsync) e solo allora prende il posto di dst. Su
// qualunque errore il temporaneo sparisce e dst resta com'era.
func writeVerified(dst, hash string, perm os.FileMode, fill func(w io.Writer) error) error {
	tmp := dst + partSuffix
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, perm)
	if err != nil {
		return err
	}
	h := sha256.New()
	err = fill(io.MultiWriter(f, h))
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		if got := hex.EncodeToString(h.Sum(nil)); got != hash {
			err = &hashMismatchError{got: got, want: hash}
		}
	}
	if err != nil {
		os.Remove(tmp)
		return err
	}
	if err := config.ReplaceFile(tmp, dst); err != nil {
		return err
	}
	// il permesso di OpenFile passa per la umask: si fissa esplicitamente
	return os.Chmod(dst, perm)
}

// fileMode: permessi di un file materializzato dal manifest.
func fileMode(exec bool) os.FileMode {
	if exec {
		return 0o755
	}
	return 0o644
}
