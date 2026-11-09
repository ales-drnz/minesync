package syncx

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"

	"minesync/client/internal/api"
	"minesync/client/internal/i18n"
)

// PullPlan: cosa scaricare/eliminare rispetto al manifest remoto.
type PullPlan struct {
	Gen      int
	Download []string // percorsi da scaricare
	Chmod    []string // percorsi con solo il bit di esecuzione da correggere
	Delete   []string // percorsi locali non più nel manifest
	Skipped  int      // file remoti ignorati perché ora esclusi
	Bytes    int64    // byte totali da scaricare
	Remote   api.Manifest
	// Backup: cartella in cui sono finite le modifiche locali scartate
	// (solo con Engine.DiscardLocal; "" se non c'era niente da salvare).
	Backup string

	dirty *DirtyLocalError // modifiche locali (anche quando DiscardLocal le scarta)
	cache Cache            // cache della scansione da cui nasce il piano
}

// PlanPull calcola cosa scaricare/eliminare rispetto al manifest remoto.
//
// Se la cartella locale ha modifiche mai pushate restituisce, insieme al
// piano, un *DirtyLocalError (a meno che DiscardLocal sia attivo).
func (e *Engine) PlanPull(ctx context.Context) (PullPlan, error) {
	remote, err := e.remoteManifest(ctx, 0)
	if err != nil {
		return PullPlan{}, err
	}
	local, cache, err := e.ScanLocal()
	if err != nil {
		return PullPlan{}, err
	}
	// indice chunk→(file locale, offset): durante il pull i pezzi che abbiamo
	// già si copiano dal disco invece di riscaricarli
	e.localIdx = map[string]localChunk{}
	for rel, ce := range cache {
		off := int64(0)
		for _, c := range ce.Chunks {
			if _, ok := e.localIdx[c.Hash]; !ok {
				e.localIdx[c.Hash] = localChunk{rel: rel, off: off, size: c.Size}
			}
			off += c.Size
		}
	}
	plan := PullPlan{Gen: remote.Gen, Remote: remote.Files, cache: cache}
	for rel, rm := range remote.Files {
		// se un pattern di esclusione è stato aggiunto DOPO che il file era
		// già sull'hub, il file resta nel manifest remoto e non comparirà mai
		// in locale: senza questo salto verrebbe riscaricato (sovrascrivendo
		// la copia locale) a ogni singolo pull
		if e.Matcher.Match(rel) {
			plan.Skipped++
			continue
		}
		lm, ok := local[rel]
		switch {
		case !ok || lm.Hash != rm.Hash:
			plan.Download = append(plan.Download, rel)
			plan.Bytes += rm.Size
		case lm.Exec != rm.Exec:
			// contenuto identico, permessi no: basta il chmod, senza
			// riscaricare niente (è il caso di chi pulla dopo un push
			// fatto da Windows, dove il bit si perde)
			plan.Chmod = append(plan.Chmod, rel)
		}
	}
	for rel := range local {
		if _, ok := remote.Files[rel]; !ok {
			plan.Delete = append(plan.Delete, rel)
		}
	}
	sort.Strings(plan.Download)
	sort.Strings(plan.Chmod)
	sort.Strings(plan.Delete)

	dirty, err := e.checkDirty(ctx, local, remote)
	if err != nil {
		return plan, err
	}
	plan.dirty = dirty
	if dirty != nil && !e.DiscardLocal {
		return plan, dirty
	}
	return plan, nil
}

// ErrStaleBase: il locale non discende dalla generazione corrente dell'hub.
var ErrStaleBase = i18n.NewError("base non aggiornata")

// StaleBaseError dice da dove si parte e dove è arrivato l'hub. Base 0 =
// generazione di partenza ignota (cache persa o mai sincronizzato), -1 = un
// pull si è interrotto a metà.
type StaleBaseError struct{ Base, Head int }

func (e *StaleBaseError) Error() string {
	switch {
	case e.Base == genPulling:
		return i18n.S("un pull precedente si è interrotto a metà: la cartella locale è incompleta. " +
			"Ripeti il pull prima di pushare, altrimenti il push cancellerebbe sull'hub i file non ancora scaricati")
	case e.Base <= 0:
		return i18n.Sf("non so da quale generazione parta la cartella locale (cache assente o "+
			"di un'altra cartella) e l'hub ha già dei file (generazione #%d). Fai prima un pull, "+
			"altrimenti il push potrebbe cancellare il lavoro degli altri", e.Head)
	}
	return i18n.Sf("il tuo mondo parte dalla generazione #%d ma l'hub è alla #%d: "+
		"qualcun altro ha giocato nel frattempo. Fai prima un pull, "+
		"altrimenti il push cancellerebbe quello che ha fatto lui",
		e.Base, e.Head)
}

func (e *StaleBaseError) Unwrap() error { return ErrStaleBase }

// ErrEmptyRemote: l'hub non ha ancora nessun file per questo spazio, ma la
// cartella locale non è vuota. Il pull, che allinea il locale al remoto,
// cancellerebbe tutto: quasi sempre significa che lo spazio è appena stato
// creato e il primo push non è ancora stato fatto.
var ErrEmptyRemote = i18n.NewError("spazio vuoto sull'hub")

// EmptyRemoteError descrive cosa verrebbe cancellato, per il messaggio a video.
type EmptyRemoteError struct {
	Gen   int
	Files int
	Dir   string
}

func (e *EmptyRemoteError) Error() string {
	return i18n.Sf("l'hub non ha ancora nessun file per questo spazio (generazione #%d): "+
		"il pull cancellerebbe i %d file in %s. Carica prima la cartella con un push.",
		e.Gen, e.Files, e.Dir)
}

func (e *EmptyRemoteError) Unwrap() error { return ErrEmptyRemote }

// Pull scarica la generazione HEAD (checkout completo del manifest remoto).
func (e *Engine) Pull(ctx context.Context) (PullPlan, error) {
	plan, err := e.PlanPull(ctx)
	if err != nil {
		return plan, err
	}
	// Guardia: manifest remoto vuoto + roba locale = pull distruttivo e basta,
	// non c'è niente da scaricare in cambio. Non si esegue mai da solo,
	// nemmeno con DiscardLocal.
	if len(plan.Remote) == 0 && len(plan.Delete) > 0 {
		return plan, &EmptyRemoteError{Gen: plan.Gen, Files: len(plan.Delete), Dir: e.LocalPath}
	}

	// DiscardLocal: prima di sovrascrivere o cancellare, copia di sicurezza
	// delle modifiche locali che il pull sta per distruggere
	if plan.dirty != nil {
		dir, err := e.backupLocal(affectedByPull(plan))
		if err != nil {
			return plan, err
		}
		plan.Backup = dir
	}

	// Da qui il locale smette di discendere dalla sua base: lo si scrive
	// PRIMA di cancellare o scaricare qualunque cosa. Se il pull si
	// interrompe, il push successivo saprà che la cartella è incompleta.
	if err := e.saveMeta(plan.cache, genPulling); err != nil {
		return plan, i18n.Errorf("salvataggio dello stato locale: %w", err)
	}

	e.startTransfer("pull", len(plan.Download), plan.Bytes)
	e.applyDeletes(plan)

	err = runPool(ctx, plan.Download, func(ctx context.Context, rel string) error {
		if err := e.downloadFile(ctx, rel, plan.Remote[rel]); err != nil {
			return fmt.Errorf("%s: %w", rel, err)
		}
		return nil
	})
	if err != nil {
		return plan, err
	}

	// permessi da riallineare senza riscaricare
	for _, rel := range plan.Chmod {
		p := filepath.Join(e.LocalPath, filepath.FromSlash(rel))
		if err := os.Chmod(p, fileMode(plan.Remote[rel].Exec)); err != nil {
			return plan, i18n.Errorf("permessi di %s: %w", rel, err)
		}
	}

	// aggiorna cache con lo stato appena materializzato: da qui in poi il
	// locale discende dalla generazione appena scaricata
	_, cache, err := Scan(e.LocalPath, e.Matcher, LoadCache(e.CachePath), nil)
	if err != nil {
		return plan, i18n.Errorf("scansione dopo il pull: %w", err)
	}
	if err := e.saveMeta(cache, plan.Gen); err != nil {
		return plan, i18n.Errorf("salvataggio dello stato locale: %w", err)
	}
	// i blob pre-scaricati sono stati materializzati: la cache ha fatto
	// il suo lavoro, si svuota (il prefetch la riempirà di nuovo)
	os.RemoveAll(e.blobCacheDir())
	e.setPhase("done")
	return plan, nil
}

// affectedByPull: i file modificati in locale che il pull sovrascriverebbe o
// cancellerebbe (gli altri restano come sono, non serve salvarli).
func affectedByPull(plan PullPlan) []string {
	touched := map[string]bool{}
	for _, rel := range plan.Download {
		touched[rel] = true
	}
	for _, rel := range plan.Delete {
		touched[rel] = true
	}
	var out []string
	for _, rel := range plan.dirty.Changed {
		if touched[rel] {
			out = append(out, rel)
		}
	}
	return out
}

// applyDeletes esegue le cancellazioni del piano.
//
// Le cancellazioni vanno PRIMA dei download, per due motivi concreti:
//   - su Windows e macOS il filesystem non distingue le maiuscole: se
//     l'hub ha config/Foo.toml e in locale c'è config/foo.toml, scaricare
//     e poi cancellare significa cancellare il file appena scaricato, cioè
//     perderlo del tutto;
//   - quando un aggiornamento trasforma un file in cartella (o viceversa),
//     è la cancellazione a togliere di mezzo l'ostacolo: farla dopo
//     significa che ogni pull fallisce, per sempre.
//
// Chi sta per essere riscaricato non si cancella (confronto senza
// maiuscole: è lo stesso file per il filesystem).
func (e *Engine) applyDeletes(plan PullPlan) {
	incoming := make(map[string]bool, len(plan.Download))
	for _, rel := range plan.Download {
		incoming[strings.ToLower(rel)] = true
	}
	deleted := make([]string, 0, len(plan.Delete))
	for _, rel := range plan.Delete {
		if incoming[strings.ToLower(rel)] {
			continue // stesso file per il filesystem: lo sovrascrive il download
		}
		p := filepath.Join(e.LocalPath, filepath.FromSlash(rel))
		if err := os.Remove(p); err == nil || os.IsNotExist(err) {
			deleted = append(deleted, rel)
		} else if st, serr := os.Stat(p); serr == nil && st.IsDir() {
			// il remoto vuole un file dove noi abbiamo una cartella
			if os.RemoveAll(p) == nil {
				deleted = append(deleted, rel)
			}
		}
	}
	pruneEmptyDirsOf(e.LocalPath, deleted, e.Matcher)
}

// --- blob cache locale (pre-download) ---
//
// ~/.minesync/cache/blobs/<spazio>/<hash>: blob già DECOMPRESSI e verificati,
// scaricati in anticipo dal prefetch. Il pull li usa al posto della rete.

func (e *Engine) blobCacheDir() string {
	return filepath.Join(filepath.Dir(e.CachePath), "blobs", e.SpaceID)
}

func (e *Engine) blobCachePath(hash string) string {
	return filepath.Join(e.blobCacheDir(), hash)
}

// readVerified legge tutto r (attesi size byte) e verifica lo SHA-256.
func readVerified(r io.Reader, size int64, hash string) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(r, size+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) != size {
		return nil, i18n.Errorf("dimensione inattesa (%d ≠ %d)", len(data), size)
	}
	h := sha256.Sum256(data)
	if hex.EncodeToString(h[:]) != hash {
		return nil, i18n.Errorf("hash non combacia")
	}
	return data, nil
}

// fetchChunk procura un chunk verificato: blob cache → file locali → rete.
func (e *Engine) fetchChunk(ctx context.Context, c api.Chunk) ([]byte, error) {
	// 1. pre-scaricato dal prefetch?
	if f, err := os.Open(e.blobCachePath(c.Hash)); err == nil {
		data, verr := readVerified(f, c.Size, c.Hash)
		f.Close()
		if verr == nil {
			return data, nil
		}
		os.Remove(e.blobCachePath(c.Hash)) // corrotto: via
	}
	// 2. già dentro un file locale (versione precedente)?
	if lc, ok := e.localIdx[c.Hash]; ok && lc.size == c.Size {
		if f, err := os.Open(filepath.Join(e.LocalPath, filepath.FromSlash(lc.rel))); err == nil {
			data, verr := readVerified(io.NewSectionReader(f, lc.off, lc.size), c.Size, c.Hash)
			f.Close()
			if verr == nil {
				return data, nil
			}
			// il file locale è cambiato rispetto alla cache: si scarica
		}
	}
	// 3. rete (con retry)
	var data []byte
	err := retry(ctx, retries, func() error {
		body, _, err := e.Client.DownloadBlob(ctx, e.SpaceID, c.Hash)
		if err != nil {
			return err
		}
		defer body.Close()
		data, err = readVerified(body, c.Size, c.Hash)
		return err
	})
	return data, err
}

// downloadFile materializza un file del manifest (verificato e atomico).
func (e *Engine) downloadFile(ctx context.Context, rel string, meta api.FileMeta) error {
	e.fileStart(rel)
	defer e.fileDone(rel)
	dst := filepath.Join(e.LocalPath, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	return retry(ctx, retries, func() error {
		if len(meta.Chunks) > 0 {
			return e.tryDownloadChunked(ctx, meta, dst)
		}
		return e.tryDownload(ctx, meta, dst)
	})
}

// tryDownloadChunked materializza un file spezzato assemblando i chunk
// dalle tre sorgenti; verifica finale sull'hash dell'intero file.
func (e *Engine) tryDownloadChunked(ctx context.Context, meta api.FileMeta, dst string) error {
	var written int64
	err := writeVerified(dst, meta.Hash, fileMode(meta.Exec), func(w io.Writer) error {
		for _, c := range meta.Chunks {
			data, err := e.fetchChunk(ctx, c)
			if err != nil {
				return fmt.Errorf("chunk %s: %w", short(c.Hash), err)
			}
			if _, err := w.Write(data); err != nil {
				return err
			}
			written += int64(len(data))
			e.addBytes(int64(len(data)))
		}
		return nil
	})
	if err != nil {
		e.addBytes(-written) // il retry riparte da zero
	}
	return err
}

// tryDownload scarica un file intero: prima la blob cache del prefetch, poi
// la rete.
func (e *Engine) tryDownload(ctx context.Context, meta api.FileMeta, dst string) error {
	var body io.ReadCloser
	fromCache := false
	if f, err := os.Open(e.blobCachePath(meta.Hash)); err == nil {
		body, fromCache = f, true
	} else {
		var err error
		body, _, err = e.Client.DownloadBlob(ctx, e.SpaceID, meta.Hash)
		if err != nil {
			return err
		}
	}
	defer body.Close()
	var copied int64
	err := writeVerified(dst, meta.Hash, fileMode(meta.Exec), func(w io.Writer) error {
		buf := make([]byte, bufSize)
		for {
			n, rerr := body.Read(buf)
			if n > 0 {
				if _, werr := w.Write(buf[:n]); werr != nil {
					return werr
				}
				copied += int64(n)
				e.addBytes(int64(n))
			}
			if rerr == io.EOF {
				return nil
			}
			if rerr != nil {
				return rerr
			}
		}
	})
	if err != nil {
		e.addBytes(-copied) // il retry ripartirà da zero
		var hm *hashMismatchError
		if fromCache && errors.As(err, &hm) {
			os.Remove(e.blobCachePath(meta.Hash)) // corrotto: il retry usa la rete
		}
	}
	return err
}

// pruneEmptyDirsOf rimuove solo le cartelle rimaste vuote lungo i percorsi
// appena cancellati. Prima si camminava l'intera radice a ogni pull e si
// tentava di rimuovere qualunque cartella vuota, comprese quelle escluse
// dalla sincronizzazione: sparivano backups/, logs/, crash-reports/ e le
// cartelle vuote che certi mod si aspettano di trovare (e che non ricreano).
func pruneEmptyDirsOf(root string, deleted []string, m *Matcher) {
	seen := map[string]bool{}
	var dirs []string
	for _, rel := range deleted {
		d := path.Dir(rel)
		for d != "." && d != "/" && d != "" {
			if !seen[d] {
				seen[d] = true
				dirs = append(dirs, d)
			}
			d = path.Dir(d)
		}
	}
	// prima le più profonde
	sort.Slice(dirs, func(i, j int) bool { return len(dirs[i]) > len(dirs[j]) })
	for _, rel := range dirs {
		if m.MatchDir(rel) {
			continue // cartella esclusa: non è affar nostro
		}
		os.Remove(filepath.Join(root, filepath.FromSlash(rel))) // fallisce (bene) se non vuota
	}
}
