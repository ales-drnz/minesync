package syncx

import (
	"bytes"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

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

// UploadOpts regola la velocità di un upload. Lo zero vale "a tutta":
// workers paralleli e nessun limite di banda (push finale e manuali).
type UploadOpts struct {
	Workers  int   // upload paralleli (0 = workers)
	LimitBps int64 // byte/s sulla rete (0 = nessun limite)
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

// ErrBlobRejected: l'hub ha rifiutato un blob (di solito: hash che non
// combacia, perché il file è cambiato mentre lo si caricava). Ritentare con
// lo stesso hash non serve: il push si interrompe e il prossimo tentativo
// riparte da una scansione fresca.
var ErrBlobRejected = i18n.NewError("l'hub ha rifiutato un blob (file cambiato durante il caricamento?)")

// Push scansiona, carica i blob mancanti e committa una nuova generazione.
func (e *Engine) Push(ctx context.Context, message string, nolock bool) (PushResult, error) {
	e.opMu.Lock()
	defer e.opMu.Unlock()
	remote, err := e.remoteManifest(ctx, 0)
	if err != nil {
		return PushResult{}, err
	}
	res, err := e.scanLocal(scanOpts{})
	if err != nil {
		return PushResult{}, err
	}
	local, cache := res.Manifest, res.Cache
	keepRemoteFor(local, remote.Files, res.Unreadable)

	if manifestsEqual(local, remote.Files) {
		// già allineati: da qui in poi il locale discende da HEAD
		if err := e.saveMeta(cache, remote.Gen, remote.Digest); err != nil {
			return PushResult{}, i18n.Errorf("salvataggio dello stato locale: %w", err)
		}
		return PushResult{NoChange: true, Gen: api.GenSummary{N: remote.Gen, Digest: remote.Digest}}, nil
	}
	// la cache aggiornata si salva comunque (gli hash appena calcolati non
	// vanno ricalcolati al prossimo giro); la base resta quella che era
	if err := e.saveMeta(cache, e.meta.Gen, e.meta.GenDigest); err != nil {
		return PushResult{}, i18n.Errorf("salvataggio dello stato locale: %w", err)
	}

	if err := e.checkGuards(local, remote); err != nil {
		return PushResult{}, err
	}
	corrupt := newCorrupt(local, remote.Files, cache)

	begin, err := e.begin(ctx, remote.Head, e.parentDigest(remote), message, local, corrupt, nolock)
	if err != nil {
		return PushResult{}, err
	}
	totalB, err := e.uploadMissing(ctx, begin.PushID, begin.Missing, liveSources(local), UploadOpts{})
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
	if err := e.saveMeta(cache, gen.N, gen.Digest); err != nil {
		return PushResult{}, i18n.Errorf("push riuscito (generazione #%d) ma salvataggio dello stato locale fallito: %w", gen.N, err)
	}
	e.setPhase("done")
	return PushResult{Gen: gen, Uploaded: len(begin.Missing), Bytes: totalB, Corrupt: corrupt}, nil
}

// newCorrupt: tra i file che questo push aggiunge o modifica, i region che
// risultano danneggiati. Solo la corruzione nuova, non quella ereditata.
func newCorrupt(local, remote api.Manifest, cache Cache) []string {
	var corrupt []string
	for rel, fm := range local {
		if r, ok := remote[rel]; ok && r.Hash == fm.Hash {
			continue
		}
		if ce, ok := cache[rel]; ok && ce.Corrupt != "" {
			corrupt = append(corrupt, rel)
		}
	}
	sort.Strings(corrupt)
	return corrupt
}

// parentDigest: il digest da dichiarare all'hub per la base del push, ""
// se non lo conosciamo (o se non stiamo pushando sopra la nostra base).
func (e *Engine) parentDigest(remote api.ManifestResp) string {
	if e.meta.Gen == remote.Head && e.meta.GenDigest != "" {
		return e.meta.GenDigest
	}
	return ""
}

// begin apre il push e traduce i rifiuti noti dell'hub.
func (e *Engine) begin(ctx context.Context, parent int, parentDigest, message string, files api.Manifest, corrupt []string, nolock bool) (api.PushBeginResp, error) {
	begin, err := e.Client.BeginPush(ctx, e.SpaceID, api.PushBeginReq{
		Parent: parent, ParentDigest: parentDigest, Message: message, Files: files,
		Corrupt: corrupt, Session: e.LockSession, NoLock: nolock,
	})
	if api.IsStaleBase(err) {
		// stesso numero di generazione, contenuto diverso: la nostra base non
		// è la sua (NAS ripristinato, spazio ricreato)
		return begin, &StaleBaseError{Base: 0, Head: parent}
	}
	return begin, err
}

// baseKnown: la generazione base del locale è davvero quella che l'hub chiama
// con lo stesso numero. Un hub che non fornisce digest (precedente alla 3.2)
// si crede sulla parola, come prima; altrimenti serve il digest giusto e una
// cache senza digest (versione precedente) vale come base ignota.
func (e *Engine) baseKnown(hubDigest string) bool {
	if e.meta.Gen <= 0 {
		return false
	}
	return hubDigest == "" || e.meta.GenDigest == hubDigest
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
	// silenzio. Una base ignota (cache persa, di un'altra cartella, o con lo
	// stesso numero ma un altro digest) o un pull interrotto valgono come
	// base vecchia appena l'hub ha dei file: non c'è modo di sapere cosa si
	// cancellerebbe.
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
	case base > 0 && base == remote.Head && len(remote.Files) > 0 && !e.baseKnown(remote.Digest):
		return &StaleBaseError{Base: 0, Head: remote.Head}
	}
	return nil
}

// blobSrc dice da dove leggere un blob da caricare: un file intero
// (chunk=false) o una sezione di file (chunk=true, delta sync), oppure una
// copia nell'outbox dello snapshot.
type blobSrc struct {
	rel       string
	off, size int64
	chunk     bool
	// outbox: copia congelata del blob (snapshot); "" = file vivo
	outbox string
	// verify: il file vivo va riletto e verificato contro l'hash prima di
	// caricarlo (snapshot: il file può essere cambiato dopo)
	verify bool
}

// liveSources mappa ogni blob del manifest locale alla sua sorgente: file
// intero, o sezione di file per i chunk (delta sync: dei file grandi si
// caricano solo i pezzi che l'hub non ha).
func liveSources(local api.Manifest) map[string]blobSrc {
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
func (e *Engine) uploadMissing(ctx context.Context, pushID string, missing []string, sources map[string]blobSrc, opts UploadOpts) (int64, error) {
	var totalB int64
	for _, h := range missing {
		src, ok := sources[h]
		if !ok {
			return 0, i18n.Errorf("l'hub chiede un blob che non fa parte di questo push (%s)", short(h))
		}
		totalB += src.size
	}
	e.startTransfer("push", len(missing), totalB)
	lim := newRateLimiter(opts.LimitBps)
	start := time.Now()
	err := runPool(ctx, opts.Workers, missing, func(ctx context.Context, hash string) error {
		src := sources[hash]
		if err := e.uploadBlob(ctx, pushID, hash, src, lim); err != nil {
			return fmt.Errorf("%s: %w", src.rel, err)
		}
		return nil
	})
	if err == nil && lim == nil {
		e.measure(totalB, time.Since(start))
	}
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
		if gen.Digest == "" {
			// hub che non lo restituisce nel commit: lo si legge dal manifest
			if m, merr := e.remoteManifest(ctx, gen.N); merr == nil {
				gen.Digest = m.Digest
			}
		}
		return gen, nil
	}
	if ctx.Err() == nil {
		if m, merr := e.remoteManifest(ctx, 0); merr == nil && m.Head > parent && manifestsEqual(local, m.Files) {
			return api.GenSummary{N: m.Head, Parent: parent, Digest: m.Digest}, nil
		}
	}
	return gen, err
}

func (e *Engine) uploadBlob(ctx context.Context, pushID, hash string, src blobSrc, lim *rateLimiter) error {
	e.fileStart(src.rel)
	defer e.fileDone(src.rel)
	return retry(ctx, retries, func() error {
		err := e.tryUpload(ctx, pushID, hash, src, lim)
		if api.IsBadRequest(err) {
			// di solito l'hash non combacia: lo stesso hash fallirebbe ancora
			return permanent(fmt.Errorf("%w: %v", ErrBlobRejected, err))
		}
		return err
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

// errSnapshotStale: l'hub chiede un blob che lo snapshot credeva già sul
// posto, e il file vivo nel frattempo è cambiato. Lo snapshot non è più
// caricabile: si rifà al prossimo giro.
var errSnapshotStale = i18n.NewError("un file è cambiato dopo lo snapshot e l'hub ne chiede la versione vecchia: si rifà lo snapshot al prossimo autosave")

// openSrc apre la sorgente di un blob: copia nell'outbox, sezione verificata
// del file vivo, o file vivo così com'è.
func (e *Engine) openSrc(hash string, src blobSrc) (io.Reader, int64, func(), error) {
	if src.outbox != "" {
		f, err := os.Open(src.outbox)
		if err != nil {
			return nil, 0, nil, err
		}
		st, err := f.Stat()
		if err != nil {
			f.Close()
			return nil, 0, nil, err
		}
		return f, st.Size(), func() { f.Close() }, nil
	}
	f, err := os.Open(filepath.Join(e.LocalPath, filepath.FromSlash(src.rel)))
	if err != nil {
		return nil, 0, nil, err
	}
	if src.verify {
		defer f.Close()
		data, err := io.ReadAll(io.NewSectionReader(f, src.off, src.size))
		if err != nil {
			return nil, 0, nil, err
		}
		if int64(len(data)) != src.size || hashBytes(data) != hash {
			return nil, 0, nil, permanent(errSnapshotStale)
		}
		return bytes.NewReader(data), src.size, func() {}, nil
	}
	if src.chunk {
		return io.NewSectionReader(f, src.off, src.size), src.size, func() { f.Close() }, nil
	}
	st, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, 0, nil, err
	}
	return f, st.Size(), func() { f.Close() }, nil
}

func (e *Engine) tryUpload(ctx context.Context, pushID, hash string, src blobSrc, lim *rateLimiter) error {
	body, size, closeFn, err := e.openSrc(hash, src)
	if err != nil {
		return err
	}
	defer closeFn()
	// il progresso conta i byte LETTI dal file (coerente con TotalBytes),
	// non quelli compressi che passano sulla rete
	pr := &progressReader{r: body, eng: e}
	limit := func(r io.Reader) io.Reader {
		if lim == nil {
			return r
		}
		return &limitedReader{r: r, l: lim, ctx: ctx}
	}
	if alreadyCompressed(src.rel) {
		if err := e.Client.UploadBlob(ctx, e.SpaceID, pushID, hash, limit(pr), size, false); err != nil {
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
	err = e.Client.UploadBlob(ctx, e.SpaceID, pushID, hash, limit(rp), -1, true)
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

// --- velocità di upload e limite automatico ---

// Limiti del limite automatico: mai sotto il minimo (l'autosave deve pur
// finire), mai sopra il massimo (oltre non serve limitare).
const (
	autoLimitMin   = 128 << 10
	autoLimitMax   = 64 << 20
	autoLimitShare = 0.7
	// misurare upload piccoli dà numeri a caso (conta la latenza, non la banda)
	measureMinBytes = 1 << 20
)

// measure registra la velocità di un upload a piena velocità.
func (e *Engine) measure(bytes int64, el time.Duration) {
	if bytes < measureMinBytes || el <= 0 {
		return
	}
	bps := int64(float64(bytes) / el.Seconds())
	e.upBps.Store(bps)
	e.meta.UpBps = bps
}

// MeasuredUploadBps: velocità di upload misurata sugli ultimi push a piena
// velocità (anche di sessioni precedenti), 0 = mai misurata.
func (e *Engine) MeasuredUploadBps() int64 {
	if v := e.upBps.Load(); v > 0 {
		return v
	}
	_, meta := LoadCacheMeta(e.CachePath, e.LocalPath)
	return meta.UpBps
}

// UploadLimit decide il limite di banda degli upload in background (byte/s,
// 0 = nessun limite). La variabile d'ambiente MINESYNC_UPLOAD_LIMIT (KB/s) ha
// la precedenza su cfgKBps (la config); per entrambi 0 = automatico (il 70%
// della velocità misurata, entro limiti ragionevoli; nessun limite finché
// non c'è una misura) e un valore negativo = nessun limite.
func (e *Engine) UploadLimit(cfgKBps int) int64 {
	kbps := cfgKBps
	if v := strings.TrimSpace(os.Getenv("MINESYNC_UPLOAD_LIMIT")); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			kbps = n
		}
	}
	switch {
	case kbps < 0:
		return 0
	case kbps > 0:
		return int64(kbps) << 10
	}
	m := e.MeasuredUploadBps()
	if m <= 0 {
		return 0
	}
	l := int64(float64(m) * autoLimitShare)
	return min(max(l, autoLimitMin), autoLimitMax)
}
