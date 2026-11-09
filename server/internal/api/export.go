package api

import (
	"archive/zip"
	"fmt"
	"io"
	"log"
	"net/http"
	"sort"
	"strconv"
	"strings"

	"minesync/server/internal/i18n"
)

// alreadyCompressed: estensioni che non guadagnano nulla da un'altra passata
// di deflate (i .mca hanno i chunk già zlib, i .dat sono NBT gzip, ecc.).
// La stessa lista vive nel client (syncx): tienile allineate.
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

// handleGenZip streamma una generazione come archivio zip: il backup offline
// che si scarica dalla web UI. I file già compressi entrano in modalità
// Store (niente deflate inutile), gli altri vengono compressi.
func (s *Server) handleGenZip(w http.ResponseWriter, r *http.Request, tok Identity) {
	id := r.PathValue("id")
	n, err := strconv.Atoi(r.PathValue("n"))
	if err != nil {
		jsonError(w, r, http.StatusBadRequest, "n non numerico")
		return
	}
	gen, err := s.Store.Generation(id, n)
	if err != nil {
		s.writeError(w, r, err)
		return
	}
	// prima di mandare un solo byte: tutti i blob devono esserci, altrimenti
	// 409 invece di uno zip incompleto che sembra valido
	if err := s.Store.CheckBlobs(id, gen.Files); err != nil {
		s.writeError(w, r, err)
		return
	}
	name := fmt.Sprintf("%s-gen%d.zip", id, n)
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)

	zw := zip.NewWriter(w)
	// ordine stabile: gli zip parziali (connessione caduta) restano leggibili
	paths := make([]string, 0, len(gen.Files))
	for p := range gen.Files {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	for _, p := range paths {
		fm := gen.Files[p]
		hdr := &zip.FileHeader{Name: p, Modified: gen.TS, Method: zip.Deflate}
		if alreadyCompressed(p) {
			hdr.Method = zip.Store
		}
		fw, err := zw.CreateHeader(hdr)
		if err != nil {
			abortZip(id, n, err)
		}
		blob, err := s.Store.OpenFile(id, fm) // assembla i chunk se serve
		if err != nil {
			abortZip(id, n, err) // blob sparito sotto i nostri piedi
		}
		_, cerr := io.Copy(fw, blob)
		blob.Close()
		if cerr != nil {
			abortZip(id, n, cerr)
		}
	}
	if err := zw.Close(); err != nil {
		abortZip(id, n, err)
	}
}

// abortZip interrompe la risposta SENZA chiudere lo zip: la connessione
// cade a metà (niente chunk finale), così il browser segnala il download
// fallito invece di salvare un archivio troncato ma "valido".
func abortZip(id string, n int, err error) {
	log.Print(i18n.Lf("export %s gen %d interrotto: %v", id, n, err))
	panic(http.ErrAbortHandler)
}

// handleIcon serve il server-icon.png della generazione corrente (l'avatar
// delle card nella web UI). ETag = hash del blob: il browser lo riscarica
// solo quando l'icona cambia davvero.
func (s *Server) handleIcon(w http.ResponseWriter, r *http.Request, _ Identity) {
	id := r.PathValue("id")
	head, err := s.Store.Head(id)
	if err != nil {
		s.writeError(w, r, err)
		return
	}
	m, err := s.Store.ManifestAt(id, head)
	if err != nil {
		s.writeError(w, r, err)
		return
	}
	fm, ok := m["server-icon.png"]
	if !ok {
		jsonError(w, r, http.StatusNotFound, "nessuna icona")
		return
	}
	etag := `"` + fm.Hash[:16] + `"`
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	blob, err := s.Store.OpenFile(id, fm)
	if err != nil {
		s.writeError(w, r, err)
		return
	}
	defer blob.Close()
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", "no-cache") // rivalida con l'ETag
	io.Copy(w, blob)
}
