package syncx

import (
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync/atomic"

	"minesync/client/internal/api"
	"minesync/client/internal/i18n"
)

// commitRetries: tentativi extra del commit su errore di trasporto. Il
// commit è idempotente sull'hub (stesso pushId → stessa generazione), quindi
// ritentare dopo una risposta persa è sicuro.
const commitRetries = 3

// PushResult riassume un push completato.
type PushResult struct {
	Gen      api.GenSummary
	Uploaded int
	Bytes    int64
	NoChange bool
	Corrupt  []string // region file danneggiati introdotti da questo push
}

// massDeleteShare: oltre questa quota di file spariti rispetto all'hub, un
// push viene considerato una cancellazione di massa e va confermato a mano.
// Un aggiornamento di modpack sostituisce mod e config ma non cancella l'80%
// della cartella; un disco non montato sì.
const massDeleteShare = 0.8

// ErrMassDelete: il push cancellerebbe quasi tutto quello che c'è sull'hub.
var ErrMassDelete = i18n.NewError("push distruttivo")

// MassDeleteError descrive cosa sparirebbe.
type MassDeleteError struct {
	Removed, Total int
	Dir            string
}

func (e *MassDeleteError) Error() string {
	return i18n.Sf("questo push toglierebbe %d dei %d file presenti sull'hub: "+
		"la cartella %s è vuota o incompleta (disco non montato? spazio collegato alla cartella sbagliata?). "+
		"Se è davvero quello che vuoi, forza la conferma",
		e.Removed, e.Total, e.Dir)
}

func (e *MassDeleteError) Unwrap() error { return ErrMassDelete }

// Push scansiona, carica i blob mancanti e committa una nuova generazione.
func (e *Engine) Push(ctx context.Context, message string, nolock bool) (PushResult, error) {
	remote, err := e.remoteManifest(ctx, 0)
	if err != nil {
		return PushResult{}, err
	}
	local, cache, err := e.ScanLocal()
	if err != nil {
		return PushResult{}, err
	}

	if manifestsEqual(local, remote.Files) {
		// già allineati: da qui in poi il locale discende da HEAD
		if err := e.saveMeta(cache, remote.Gen); err != nil {
			return PushResult{}, i18n.Errorf("salvataggio dello stato locale: %w", err)
		}
		return PushResult{NoChange: true, Gen: api.GenSummary{N: remote.Gen}}, nil
	}
	// la cache aggiornata si salva comunque (gli hash appena calcolati non
	// vanno ricalcolati al prossimo giro); la base resta quella che era
	if err := e.saveMeta(cache, e.meta.Gen); err != nil {
		return PushResult{}, i18n.Errorf("salvataggio dello stato locale: %w", err)
	}

	if err := e.checkGuards(local, remote); err != nil {
		return PushResult{}, err
	}

	// integrità: tra i file che questo push aggiunge o modifica, quali region
	// risultano danneggiati. Solo la corruzione nuova, non quella ereditata.
	var corrupt []string
	for rel, fm := range local {
		if r, ok := remote.Files[rel]; ok && r.Hash == fm.Hash {
			continue
		}
		if ce, ok := cache[rel]; ok && ce.Corrupt != "" {
			corrupt = append(corrupt, rel)
		}
	}
	sort.Strings(corrupt)

	begin, err := e.Client.PushBegin(ctx, e.SpaceID, remote.Head, message, local, corrupt, e.LockSession, nolock)
	if err != nil {
		return PushResult{}, err
	}
	totalB, err := e.uploadMissing(ctx, begin.PushID, begin.Missing, buildSources(local))
	if err != nil {
		return PushResult{}, err
	}

	e.setPhase("commit")
	gen, err := e.commit(ctx, begin.PushID, remote.Head, local)
	if err != nil {
		return PushResult{}, err
	}
	// da qui in poi discendiamo dalla generazione appena creata: senza
	// aggiornarlo, il push successivo della stessa sessione si bloccherebbe
	// da solo sulla guardia della base
	if err := e.saveMeta(cache, gen.N); err != nil {
		return PushResult{}, i18n.Errorf("push riuscito (generazione #%d) ma salvataggio dello stato locale fallito: %w", gen.N, err)
	}
	e.setPhase("done")
	return PushResult{Gen: gen, Uploaded: len(begin.Missing), Bytes: totalB, Corrupt: corrupt}, nil
}

// checkGuards rifiuta i push che distruggerebbero lavoro sull'hub.
func (e *Engine) checkGuards(local api.Manifest, remote api.ManifestResp) error {
	// Cancellazione di massa: una cartella locale vuota (o quasi) contro un
	// hub pieno non è un push, è una cancellazione. Succede davvero: disco
	// esterno non montato, cartella ricreata vuota da un link sbagliato,
	// spazio collegato alla directory errata. Senza questa guardia diventava
	// HEAD e la sera dopo il mondo non c'era più per nessuno.
	if len(remote.Files) > 0 && !e.AllowMassDelete {
		removed := 0
		for rel := range remote.Files {
			if _, ok := local[rel]; !ok {
				removed++
			}
		}
		if share := float64(removed) / float64(len(remote.Files)); share >= massDeleteShare {
			return &MassDeleteError{Removed: removed, Total: len(remote.Files), Dir: e.LocalPath}
		}
	}

	// Base: se dall'ultimo pull/push qualcun altro ha creato generazioni, il
	// nostro albero non discende da HEAD. Pushare lo stesso significa
	// riportare l'hub indietro e cancellare quello che ha fatto l'altro, in
	// silenzio. Una base ignota (cache persa, di un'altra cartella) o un pull
	// interrotto valgono come base vecchia appena l'hub ha dei file: non c'è
	// modo di sapere cosa si cancellerebbe.
	if e.AllowStaleBase {
		return nil
	}
	base := e.meta.Gen
	switch {
	case base == genPulling:
		return &StaleBaseError{Base: genPulling, Head: remote.Head}
	case base <= 0 && len(remote.Files) > 0:
		return &StaleBaseError{Base: 0, Head: remote.Head}
	case base > 0 && remote.Head > base:
		return &StaleBaseError{Base: base, Head: remote.Head}
	}
	return nil
}

// blobSrc dice da dove leggere un blob da caricare: un file intero
// (chunk=false) o una sezione di file (chunk=true, delta sync).
type blobSrc struct {
	rel       string
	off, size int64
	chunk     bool
}

// buildSources mappa ogni blob del manifest locale alla sua sorgente: file
// intero, o sezione di file per i chunk (delta sync: dei file grandi si
// caricano solo i pezzi che l'hub non ha).
func buildSources(local api.Manifest) map[string]blobSrc {
	sources := map[string]blobSrc{}
	for rel, fm := range local {
		if len(fm.Chunks) == 0 {
			if _, ok := sources[fm.Hash]; !ok {
				sources[fm.Hash] = blobSrc{rel: rel, size: fm.Size}
			}
			continue
		}
		off := int64(0)
		for _, c := range fm.Chunks {
			if _, ok := sources[c.Hash]; !ok {
				sources[c.Hash] = blobSrc{rel: rel, off: off, size: c.Size, chunk: true}
			}
			off += c.Size
		}
	}
	return sources
}

// uploadMissing carica in parallelo i blob che l'hub non ha. Restituisce i
// byte (non compressi) caricati.
func (e *Engine) uploadMissing(ctx context.Context, pushID string, missing []string, sources map[string]blobSrc) (int64, error) {
	var totalB int64
	for _, h := range missing {
		src, ok := sources[h]
		if !ok {
			return 0, i18n.Errorf("l'hub chiede un blob che non fa parte di questo push (%s)", short(h))
		}
		totalB += src.size
	}
	e.startTransfer("push", len(missing), totalB)
	err := runPool(ctx, missing, func(ctx context.Context, hash string) error {
		src := sources[hash]
		if err := e.uploadBlob(ctx, pushID, hash, src); err != nil {
			return fmt.Errorf("%s: %w", src.rel, err)
		}
		return nil
	})
	return totalB, err
}

// commit chiude il push. Se la risposta si perde (timeout, connessione
// caduta) il commit si ritenta con lo stesso pushId: l'hub lo riconosce e
// restituisce la stessa generazione. Se l'hub non lo riconosce (versione
// vecchia, 404) si controlla HEAD: se ha esattamente il nostro contenuto ed è
// figlio della nostra base, il commit era andato a buon fine.
func (e *Engine) commit(ctx context.Context, pushID string, parent int, local api.Manifest) (api.GenSummary, error) {
	var gen api.GenSummary
	err := retry(ctx, commitRetries, func() error {
		g, err := e.Client.PushCommit(ctx, e.SpaceID, pushID)
		if err == nil {
			gen = g
			return nil
		}
		var ae *api.APIError
		if errors.As(err, &ae) && ae.Status < 500 {
			return permanent(err) // risposta vera dell'hub: ritentare non cambia niente
		}
		return err
	})
	if err == nil {
		return gen, nil
	}
	if ctx.Err() == nil {
		if m, merr := e.remoteManifest(ctx, 0); merr == nil && m.Head > parent && manifestsEqual(local, m.Files) {
			return api.GenSummary{N: m.Head, Parent: parent}, nil
		}
	}
	return gen, err
}

func (e *Engine) uploadBlob(ctx context.Context, pushID, hash string, src blobSrc) error {
	e.fileStart(src.rel)
	defer e.fileDone(src.rel)
	path := filepath.Join(e.LocalPath, filepath.FromSlash(src.rel))
	return retry(ctx, retries, func() error {
		return e.tryUpload(ctx, pushID, hash, path, src)
	})
}

// alreadyCompressed: estensioni che una passata di gzip non aiuta (i .mca
// hanno i chunk già zlib, i .dat sono NBT gzip, jar/zip/png idem).
// La stessa lista vive nell'hub (api/export.go): tienile allineate.
func alreadyCompressed(path string) bool {
	i := strings.LastIndexByte(path, '.')
	if i < 0 {
		return false
	}
	switch strings.ToLower(path[i:]) {
	case ".mca", ".mcr", ".dat", ".dat_old", ".jar", ".zip", ".gz", ".zst",
		".png", ".jpg", ".jpeg", ".ogg", ".mp3", ".rar", ".7z":
		return true
	}
	return false
}

func (e *Engine) tryUpload(ctx context.Context, pushID, hash, path string, src blobSrc) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	var body io.Reader = f
	size := src.size
	if src.chunk {
		body = io.NewSectionReader(f, src.off, src.size)
	} else {
		fi, err := f.Stat()
		if err != nil {
			return err
		}
		size = fi.Size()
	}
	// il progresso conta i byte LETTI dal file (coerente con TotalBytes),
	// non quelli compressi che passano sulla rete
	pr := &progressReader{r: body, eng: e}
	if alreadyCompressed(path) {
		if err := e.Client.UploadBlob(ctx, e.SpaceID, pushID, hash, pr, size, false); err != nil {
			e.addBytes(-pr.read())
			return err
		}
		return nil
	}
	// comprimi in streaming: config, json e NBT sciolti si riducono parecchio
	rp, wp := io.Pipe()
	done := make(chan struct{})
	go func() {
		defer close(done)
		zw, _ := gzip.NewWriterLevel(wp, gzip.BestSpeed)
		if _, cerr := io.Copy(zw, pr); cerr != nil {
			wp.CloseWithError(cerr)
			return
		}
		wp.CloseWithError(zw.Close())
	}()
	err = e.Client.UploadBlob(ctx, e.SpaceID, pushID, hash, rp, -1, true)
	rp.Close() // sblocca il goroutine se l'upload è morto a metà
	<-done     // e lo aspetta: legge ancora da pr e dal file
	if err != nil {
		e.addBytes(-pr.read())
		return err
	}
	return nil
}

// progressReader conta i byte letti e li riporta al progresso dell'engine.
type progressReader struct {
	r   io.Reader
	eng *Engine
	n   atomic.Int64
}

func (p *progressReader) Read(b []byte) (int, error) {
	n, err := p.r.Read(b)
	if n > 0 {
		p.n.Add(int64(n))
		p.eng.addBytes(int64(n))
	}
	return n, err
}

func (p *progressReader) read() int64 { return p.n.Load() }
