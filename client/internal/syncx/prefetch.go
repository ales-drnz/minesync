// Prefetch ("warm cache"): scarica in anticipo, nella blob cache locale,
// i blob che un futuro pull richiederebbe — così quando premi G il checkout
// è (quasi) istantaneo. Non tocca MAI la cartella del mondo: riempie solo
// ~/.minesync/cache/blobs/<spazio>/, che il pull consuma e poi svuota.
package syncx

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"sort"

	"minesync/client/internal/i18n"
)

// PrefetchStatus è lo stato di un pre-download, per la UI.
type PrefetchStatus struct {
	SpaceID    string
	Total      int   // blob da scaricare in questo giro
	Done       int   // blob completati
	TotalBytes int64 // stima byte (dimensioni non compresse)
	DoneBytes  int64
	Running    bool
	Err        error
}

// Prefetch confronta il manifest remoto con lo stato locale (cache della
// scansione, senza ri-scansionare) e scarica i blob mancanti nella blob
// cache. Riporta quanti blob ha scaricato. Sicuro da interrompere e da
// ripetere: è tutto content-addressed e verificato.
func (e *Engine) Prefetch(ctx context.Context, report func(PrefetchStatus)) (int, error) {
	remote, err := e.remoteManifest(ctx, 0)
	if err != nil {
		return 0, err
	}

	// cosa serve per materializzare HEAD: chunk dei file spezzati, interi
	// degli altri
	type need struct {
		hash string
		size int64
	}
	wanted := map[string]int64{}
	for _, fm := range remote.Files {
		if len(fm.Chunks) == 0 {
			wanted[fm.Hash] = fm.Size
			continue
		}
		for _, c := range fm.Chunks {
			wanted[c.Hash] = c.Size
		}
	}

	// cosa abbiamo già: i contenuti dei file locali (dall'ultima scansione;
	// best-effort, il pull verifica comunque tutto) e la blob cache stessa
	have := map[string]bool{}
	for _, ce := range LoadCache(e.CachePath) {
		have[ce.Hash] = true
		for _, c := range ce.Chunks {
			have[c.Hash] = true
		}
	}
	dir := e.blobCacheDir()
	if entries, err := os.ReadDir(dir); err == nil {
		for _, en := range entries {
			name := en.Name()
			if _, ok := wanted[name]; ok {
				have[name] = true
			} else {
				// blob di generazioni passate: non servirà più
				os.Remove(filepath.Join(dir, name))
			}
		}
	}

	var needs []need
	var totalB int64
	for h, s := range wanted {
		if !have[h] {
			needs = append(needs, need{h, s})
			totalB += s
		}
	}
	if len(needs) == 0 {
		return 0, nil
	}
	sort.Slice(needs, func(i, j int) bool { return needs[i].hash < needs[j].hash })
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return 0, err
	}

	st := PrefetchStatus{SpaceID: e.SpaceID, Total: len(needs), TotalBytes: totalB, Running: true}
	emit := func() {
		if report != nil {
			report(st)
		}
	}
	emit()
	for _, n := range needs {
		if ctx.Err() != nil {
			return st.Done, ctx.Err()
		}
		if err := e.prefetchBlob(ctx, n.hash, n.size); err != nil {
			st.Running, st.Err = false, err
			emit()
			return st.Done, err
		}
		st.Done++
		st.DoneBytes += n.size
		emit()
	}
	st.Running = false
	emit()
	return st.Done, nil
}

// prefetchBlob scarica un blob nella cache (decompresso e verificato).
func (e *Engine) prefetchBlob(ctx context.Context, hash string, size int64) error {
	body, _, err := e.Client.DownloadBlob(ctx, e.SpaceID, hash)
	if err != nil {
		return err
	}
	defer body.Close()
	err = writeVerified(e.blobCachePath(hash), hash, 0o644, func(w io.Writer) error {
		_, err := io.Copy(w, body)
		return err
	})
	if err != nil {
		return i18n.Errorf("prefetch del blob %s: %w", short(hash), err)
	}
	return nil
}
