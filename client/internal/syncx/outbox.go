package syncx

// Outbox: snapshot congelato per l'autosave in background.
//
// Prima l'autosave faceva save-off, poi l'intero push (scansione + upload) e
// solo alla fine save-on: con un uplink lento il server restava in save-off
// per quasi tutto il tempo, e l'upload leggeva i file vivi (un file cambiato
// dopo la scansione faceva fallire il blob per hash, ritentato inutilmente).
//
// Ora, ancora in save-off, UNA passata (Snapshot) scansiona, calcola hash e
// chunk e copia in <cache>/<spazio>-outbox/<hash> ogni blob che l'hub non ha
// ancora; per ultimo scrive pending.json (manifest, base, istante). Da lì il
// mondo può ripartire (save-on) e l'upload (PushSnapshot) legge SOLO
// dall'outbox, con calma e a banda limitata.
//
// Ripresa dopo un crash: l'outbox di una sessione precedente si butta
// (ResetOutbox all'avvio della sessione). Non serve riprenderla: i blob già
// caricati restano sull'hub (il begin successivo non li richiede), e lo stato
// locale lo gestisce la protezione delle modifiche locali al primo pull.

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	"minesync/client/internal/api"
	"minesync/client/internal/config"
	"minesync/client/internal/i18n"
)

// outboxMargin: spazio da lasciare comunque libero sul disco della cache.
const outboxMargin = 256 << 20

// diskFreeFn misura lo spazio libero (variabile per i test).
var diskFreeFn = diskFree

// ErrOutboxNoSpace: il disco della cache non ha posto per lo snapshot. Chi
// chiama ripiega sul push sincrono di una volta.
var ErrOutboxNoSpace = i18n.NewError("spazio su disco insufficiente per lo snapshot dell'autosave")

// Snapshot è uno stato congelato della cartella, pronto da caricare.
type Snapshot struct {
	Manifest     api.Manifest
	Parent       int    // generazione dell'hub su cui si basa
	ParentDigest string // suo digest come lo conosciamo ("" = ignoto)
	At           time.Time
	NoChange     bool  // identico a HEAD: niente da caricare
	Blobs        int   // blob copiati nell'outbox
	Bytes        int64 // loro dimensione
	Corrupt      []string

	cache   Cache
	sources map[string]blobSrc
}

// pendingFile è il formato di pending.json (documentazione dello snapshot in
// corso; oggi non viene ripreso dopo un crash, vedi sopra).
type pendingFile struct {
	Parent       int          `json:"parent"`
	ParentDigest string       `json:"parentDigest,omitempty"`
	SnapshotAt   time.Time    `json:"snapshotAt"`
	Corrupt      []string     `json:"corrupt,omitempty"`
	Manifest     api.Manifest `json:"manifest"`
}

// OutboxDir è la cartella dell'outbox di questo spazio (accanto alla cache).
func (e *Engine) OutboxDir() string {
	return filepath.Join(filepath.Dir(e.CachePath), e.SpaceID+"-outbox")
}

// ResetOutbox butta l'outbox (avvio sessione: temporanei e snapshot di una
// sessione precedente non servono più).
func (e *Engine) ResetOutbox() error {
	e.opMu.Lock()
	defer e.opMu.Unlock()
	return os.RemoveAll(e.OutboxDir())
}

const pendingName = "pending.json"

// Snapshot congela lo stato della cartella (vedi il commento del file). Va
// chiamato con il mondo fermo (save-off confermato). Rispetta le stesse
// guardie del push (cancellazione di massa, base vecchia).
func (e *Engine) Snapshot(ctx context.Context) (*Snapshot, error) {
	e.opMu.Lock()
	defer e.opMu.Unlock()
	remote, err := e.remoteManifest(ctx, 0)
	if err != nil {
		return nil, err
	}
	dir := e.OutboxDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	onHub := map[string]bool{}
	for _, fm := range remote.Files {
		for _, b := range fileBlobs(fm) {
			onHub[b] = true
		}
	}
	inOutbox := map[string]bool{}
	if entries, err := os.ReadDir(dir); err == nil {
		for _, en := range entries {
			name := en.Name()
			switch {
			case validHash(name):
				inOutbox[name] = true
			case name != pendingName:
				os.Remove(filepath.Join(dir, name)) // temporaneo di un giro interrotto
			}
		}
	}
	os.Remove(filepath.Join(dir, pendingName)) // lo snapshot vecchio non vale più

	free := diskFreeFn(dir)
	snap := &Snapshot{At: time.Now(), Parent: remote.Head}
	needed := func(h string) bool { return !onHub[h] && !inOutbox[h] }
	tee := func(h string, data []byte) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		if !needed(h) {
			return nil
		}
		if free >= 0 && snap.Bytes+int64(len(data))+outboxMargin > free {
			return ErrOutboxNoSpace
		}
		if err := writeBlobFile(dir, h, data); err != nil {
			return err
		}
		inOutbox[h] = true
		snap.Blobs++
		snap.Bytes += int64(len(data))
		return nil
	}
	trust := func(ce cacheEntry) bool {
		for _, b := range ce.blobs() {
			if needed(b) {
				return false
			}
		}
		return true
	}
	res, err := e.scanLocal(scanOpts{trust: trust, tee: tee, now: snap.At})
	if err != nil {
		return nil, err
	}
	local := res.Manifest
	keepRemoteFor(local, remote.Files, res.Unreadable)
	snap.Manifest, snap.cache = local, res.Cache

	if manifestsEqual(local, remote.Files) {
		if err := e.saveMeta(res.Cache, remote.Gen, remote.Digest); err != nil {
			return nil, i18n.Errorf("salvataggio dello stato locale: %w", err)
		}
		e.clearOutbox()
		snap.NoChange = true
		return snap, nil
	}
	if err := e.saveMeta(res.Cache, e.meta.Gen, e.meta.GenDigest); err != nil {
		return nil, i18n.Errorf("salvataggio dello stato locale: %w", err)
	}
	if err := e.checkGuards(local, remote); err != nil {
		return nil, err
	}
	snap.ParentDigest = e.parentDigest(remote)
	snap.Corrupt = newCorrupt(local, remote.Files, res.Cache)

	// sorgenti: l'outbox per quello che l'hub non ha; il file vivo (da
	// verificare) per quello che dovrebbe già avere
	snap.sources = map[string]blobSrc{}
	for h, src := range liveSources(local) {
		if inOutbox[h] {
			src.outbox = filepath.Join(dir, h)
		} else {
			src.verify = true
		}
		snap.sources[h] = src
	}
	// blob dell'outbox che questo snapshot non usa: via
	if entries, err := os.ReadDir(dir); err == nil {
		for _, en := range entries {
			if name := en.Name(); validHash(name) {
				if _, ok := snap.sources[name]; !ok {
					os.Remove(filepath.Join(dir, name))
				}
			}
		}
	}
	b, err := json.Marshal(pendingFile{Parent: snap.Parent, ParentDigest: snap.ParentDigest,
		SnapshotAt: snap.At, Corrupt: snap.Corrupt, Manifest: local})
	if err != nil {
		return nil, err
	}
	if err := config.WriteFileAtomic(filepath.Join(dir, pendingName), b, 0o644); err != nil {
		return nil, err
	}
	return snap, nil
}

// PushSnapshot carica uno snapshot: begin → blob mancanti dall'outbox →
// commit. Se l'hub chiede un blob che non è nell'outbox lo si rilegge dal
// file vivo e lo si verifica; se il file è cambiato lo snapshot è da rifare
// (errore, si riprova al giro successivo). Il commit è idempotente. Su
// successo la base locale avanza alla nuova generazione e l'outbox si svuota;
// su errore l'outbox resta (il giro successivo riusa i blob ancora validi).
func (e *Engine) PushSnapshot(ctx context.Context, snap *Snapshot, message string, opts UploadOpts) (PushResult, error) {
	e.opMu.Lock()
	defer e.opMu.Unlock()
	if snap.NoChange {
		return PushResult{NoChange: true, Gen: api.GenSummary{N: snap.Parent}}, nil
	}
	begin, err := e.begin(ctx, snap.Parent, snap.ParentDigest, message, snap.Manifest, snap.Corrupt, false)
	if err != nil {
		return PushResult{}, err
	}
	totalB, err := e.uploadMissing(ctx, begin.PushID, begin.Missing, snap.sources, opts)
	if err != nil {
		return PushResult{}, err
	}
	e.setPhase("commit")
	gen, err := e.commit(ctx, begin.PushID, snap.Parent, snap.Manifest)
	if err != nil {
		return PushResult{}, err
	}
	if err := e.saveMeta(snap.cache, gen.N, gen.Digest); err != nil {
		return PushResult{}, i18n.Errorf("push riuscito (generazione #%d) ma salvataggio dello stato locale fallito: %w", gen.N, err)
	}
	e.clearOutbox()
	e.setPhase("done")
	return PushResult{Gen: gen, Uploaded: len(begin.Missing), Bytes: totalB, Corrupt: snap.Corrupt}, nil
}

// clearOutbox svuota l'outbox (lo snapshot è arrivato, o non serviva).
func (e *Engine) clearOutbox() {
	dir := e.OutboxDir()
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, en := range entries {
		os.Remove(filepath.Join(dir, en.Name()))
	}
}

// fileBlobs: i blob che compongono un file del manifest.
func fileBlobs(fm api.FileMeta) []string {
	if len(fm.Chunks) == 0 {
		return []string{fm.Hash}
	}
	out := make([]string, len(fm.Chunks))
	for i, c := range fm.Chunks {
		out[i] = c.Hash
	}
	return out
}

// writeBlobFile scrive un blob nell'outbox in modo atomico e durevole
// (temporaneo, fsync, rename): dopo un blackout c'è il blob intero o niente.
func writeBlobFile(dir, hash string, data []byte) error {
	tmp := filepath.Join(dir, hash+".tmp")
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	_, err = f.Write(data)
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(tmp)
		return err
	}
	return config.ReplaceFile(tmp, filepath.Join(dir, hash))
}
