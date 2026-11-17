package syncx

import (
	"context"
	"encoding/binary"
	"hash/fnv"
	"io/fs"
	"path/filepath"
	"strings"
	"time"
)

// Quiesce aspetta che la cartella smetta di cambiare: (dimensione, data) di
// tutti i file sincronizzati identiche per `stable` di fila, controllando
// ogni `poll`, al massimo per `maxWait`. Serve dopo la conferma di
// salvataggio: diversi mod (Cobblemon, CobbleDollars, i dati alla radice
// come legendary-monuments-data/) scrivono anche in save-off, e fotografare
// la cartella mentre lo fanno significa rileggere file a metà.
//
// Restituisce true se la cartella si è fermata, false se è scaduto il tempo
// (o il contesto): si procede comunque, la lettura dello snapshot rilegge i
// file che cambiano sotto i piedi.
func (e *Engine) Quiesce(ctx context.Context, stable, maxWait, poll time.Duration) bool {
	deadline := time.Now().Add(maxWait)
	last := e.fingerprint()
	since := time.Now()
	t := time.NewTicker(poll)
	defer t.Stop()
	for {
		if time.Since(since) >= stable {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		select {
		case <-ctx.Done():
			return false
		case <-t.C:
		}
		if fp := e.fingerprint(); fp != last {
			last, since = fp, time.Now()
		}
	}
}

// fingerprint riassume (percorso, dimensione, data) di tutti i file non
// esclusi: basta lo stat, nessuna lettura.
func (e *Engine) fingerprint() uint64 {
	h := fnv.New64a()
	var buf [16]byte
	filepath.WalkDir(e.LocalPath, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil // illeggibile o sparito: lo vedrà la scansione
		}
		rel, rerr := filepath.Rel(e.LocalPath, p)
		if rerr != nil || rel == "." {
			return nil
		}
		rel = filepath.ToSlash(rel)
		if d.IsDir() {
			if e.Matcher.MatchDir(rel) {
				return filepath.SkipDir
			}
			return nil
		}
		if e.Matcher.Match(rel) || strings.HasSuffix(rel, partSuffix) {
			return nil
		}
		info, ierr := d.Info()
		if ierr != nil {
			return nil
		}
		h.Write([]byte(rel))
		binary.LittleEndian.PutUint64(buf[:8], uint64(info.Size()))
		binary.LittleEndian.PutUint64(buf[8:], uint64(info.ModTime().UnixNano()))
		h.Write(buf[:])
		return nil
	})
	return h.Sum64()
}
