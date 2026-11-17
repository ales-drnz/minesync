package syncx

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
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

// runPool esegue fn su ogni elemento con n goroutine (0 = workers). Al primo errore
// annulla il contesto passato agli altri (gli elementi non ancora iniziati
// vengono saltati) e restituisce quell'errore.
func runPool(ctx context.Context, n int, items []string, fn func(ctx context.Context, item string) error) error {
	cctx, cancel := context.WithCancel(ctx)
	defer cancel()
	jobs := make(chan string)
	var wg sync.WaitGroup
	var firstErr error
	var errOnce sync.Once
	if n <= 0 {
		n = workers
	}
	for i := 0; i < n; i++ {
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
func (e *Engine) writeVerified(dst, hash string, perm os.FileMode, fill func(w io.Writer) error) error {
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
	return e.chmod(dst, perm)
}

// chmod applica i permessi; sui filesystem che non li hanno (exFAT, FAT32,
// certe condivisioni di rete) il chmod fallisce con EPERM/ENOTSUP: il
// contenuto è comunque giusto, quindi si ignora con un solo avviso.
func (e *Engine) chmod(path string, perm os.FileMode) error {
	err := os.Chmod(path, perm)
	if err != nil && chmodUnsupported(err) {
		e.chmodWarn.Do(func() {
			e.warn(i18n.S("Il filesystem della cartella non supporta i permessi dei file (exFAT/FAT?): il bit di esecuzione degli script non verrà applicato."))
		})
		return nil
	}
	return err
}

func chmodUnsupported(err error) bool {
	return errors.Is(err, fs.ErrPermission) || errors.Is(err, errors.ErrUnsupported)
}

// existingDir risale da path fino alla prima cartella esistente (per
// misurare lo spazio libero di una destinazione non ancora creata).
func existingDir(path string) string {
	p := filepath.Clean(path)
	for {
		if st, err := os.Stat(p); err == nil && st.IsDir() {
			return p
		}
		parent := filepath.Dir(p)
		if parent == p {
			return p
		}
		p = parent
	}
}

// rateLimiter è un token bucket condiviso dai worker di un upload: limita i
// byte al secondo che lasciano il PC, così l'autosave in background non
// satura l'uplink di chi ospita (e il gioco degli altri non lagga).
type rateLimiter struct {
	mu     sync.Mutex
	rate   float64 // byte/s
	burst  float64
	tokens float64
	last   time.Time
}

func newRateLimiter(bps int64) *rateLimiter {
	if bps <= 0 {
		return nil
	}
	b := float64(bps) / 4 // al massimo ~250 ms di raffica
	if b < 32<<10 {
		b = 32 << 10
	}
	return &rateLimiter{rate: float64(bps), burst: b, tokens: b, last: time.Now()}
}

// wait consuma n token, aspettando quanto serve (o fino alla fine di ctx).
func (l *rateLimiter) wait(ctx context.Context, n int) error {
	if l == nil || n <= 0 {
		return nil
	}
	l.mu.Lock()
	now := time.Now()
	l.tokens += now.Sub(l.last).Seconds() * l.rate
	if l.tokens > l.burst {
		l.tokens = l.burst
	}
	l.last = now
	l.tokens -= float64(n)
	deficit := -l.tokens
	l.mu.Unlock()
	if deficit <= 0 {
		return nil
	}
	t := time.NewTimer(time.Duration(deficit / l.rate * float64(time.Second)))
	defer t.Stop()
	select {
	case <-t.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// limitedReader passa i byte al ritmo del limiter (letture piccole, così il
// flusso è regolare e il watchdog vede progresso).
type limitedReader struct {
	r   io.Reader
	l   *rateLimiter
	ctx context.Context
}

func (lr *limitedReader) Read(p []byte) (int, error) {
	if len(p) > 16<<10 {
		p = p[:16<<10]
	}
	n, err := lr.r.Read(p)
	if werr := lr.l.wait(lr.ctx, n); werr != nil && err == nil {
		err = werr
	}
	return n, err
}

// fileMode: permessi di un file materializzato dal manifest.
func fileMode(exec bool) os.FileMode {
	if exec {
		return 0o755
	}
	return 0o644
}
