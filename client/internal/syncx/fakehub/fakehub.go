// Package fakehub: hub MineSync finto, in memoria, per i test del client
// (syncx, session). Implementa il sottoinsieme di API usato da pull, push e
// lock, con ganci per simulare i guasti (risposte perse, blob che falliscono,
// trasferimenti fermi).
package fakehub

import (
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync"
	"time"

	"minesync/client/internal/api"
)

// Hub è lo stato del finto hub (uno spazio qualunque: l'id è ignorato).
type Hub struct {
	Srv *httptest.Server

	mu        sync.Mutex
	head      int
	gens      map[int]api.Manifest
	blobs     map[string][]byte
	pushes    map[string]pendingPush
	committed map[string]api.GenSummary
	nextPush  int
	lockSess  string

	// Ganci per i guasti (da impostare sotto Lock/Unlock o prima dell'uso).
	DropCommitResponses int             // commit eseguiti ma risposta troncata
	NonIdempotentCommit bool            // hub vecchio: pushId già usato → 404
	FailPushBegin       bool            // push/begin risponde 503
	FailBlobs           map[string]bool // GET di questi blob → 500
	StallBlobs          bool            // GET dei blob: header e poi silenzio

	// Osservazioni.
	MissingHeader int // richieste senza X-MineSync
	PushBegins    int // chiamate a push/begin
	Commits       int // commit effettivi (generazioni create da push)
	LastSession   string
}

type pendingPush struct {
	parent int
	files  api.Manifest
}

// New avvia il finto hub (chiuso da t.Cleanup a cura del chiamante: Close).
func New() *Hub {
	h := &Hub{
		gens:      map[int]api.Manifest{0: {}},
		blobs:     map[string][]byte{},
		pushes:    map[string]pendingPush{},
		committed: map[string]api.GenSummary{},
		FailBlobs: map[string]bool{},
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/spaces/{id}/manifest", h.manifest)
	mux.HandleFunc("GET /api/v1/spaces/{id}/blobs/{hash}", h.getBlob)
	mux.HandleFunc("POST /api/v1/spaces/{id}/push/begin", h.pushBegin)
	mux.HandleFunc("PUT /api/v1/spaces/{id}/push/{pid}/blobs/{hash}", h.putBlob)
	mux.HandleFunc("POST /api/v1/spaces/{id}/push/{pid}/commit", h.commit)
	mux.HandleFunc("POST /api/v1/spaces/{id}/lock", h.lock)
	mux.HandleFunc("POST /api/v1/spaces/{id}/lock/heartbeat", h.heartbeat)
	mux.HandleFunc("DELETE /api/v1/spaces/{id}/lock", h.release)
	h.Srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-MineSync") == "" {
			h.mu.Lock()
			h.MissingHeader++
			h.mu.Unlock()
		}
		mux.ServeHTTP(w, r)
	}))
	return h
}

// URL dell'hub.
func (h *Hub) URL() string { return h.Srv.URL }

// Close spegne il server.
func (h *Hub) Close() { h.Srv.Close() }

// Lock/Unlock proteggono i ganci se cambiati mentre il client lavora.
func (h *Hub) Lock()   { h.mu.Lock() }
func (h *Hub) Unlock() { h.mu.Unlock() }

// Head è la generazione corrente.
func (h *Hub) Head() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.head
}

// Files restituisce il contenuto della generazione n (percorso → byte).
func (h *Hub) Files(n int) map[string][]byte {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := map[string][]byte{}
	for rel, fm := range h.gens[n] {
		out[rel] = h.blobs[fm.Hash]
	}
	return out
}

// Hash: SHA-256 esadecimale.
func Hash(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

// Commit crea direttamente una nuova generazione con questi contenuti (come
// se avesse pushato qualcun altro). Restituisce il numero della generazione.
func (h *Hub) Commit(files map[string][]byte) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	m := api.Manifest{}
	for rel, b := range files {
		hs := Hash(b)
		h.blobs[hs] = b
		m[rel] = api.FileMeta{Hash: hs, Size: int64(len(b))}
	}
	h.head++
	h.gens[h.head] = m
	return h.head
}

// SetRawManifest forza HEAD a un manifest arbitrario (anche malevolo).
func (h *Hub) SetRawManifest(m api.Manifest) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.head++
	h.gens[h.head] = m
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func errJSON(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func (h *Hub) manifest(w http.ResponseWriter, r *http.Request) {
	h.mu.Lock()
	defer h.mu.Unlock()
	n := h.head
	if g := r.URL.Query().Get("gen"); g != "" {
		n, _ = strconv.Atoi(g)
	}
	m, ok := h.gens[n]
	if !ok {
		errJSON(w, 404, "generazione inesistente")
		return
	}
	writeJSON(w, 200, api.ManifestResp{Gen: n, Head: h.head, Files: m})
}

func (h *Hub) getBlob(w http.ResponseWriter, r *http.Request) {
	hash := r.PathValue("hash")
	h.mu.Lock()
	b, ok := h.blobs[hash]
	fail, stall := h.FailBlobs[hash], h.StallBlobs
	h.mu.Unlock()
	switch {
	case fail:
		errJSON(w, 500, "blob illeggibile")
		return
	case !ok:
		errJSON(w, 404, "blob inesistente")
		return
	case stall:
		w.Header().Set("Content-Type", "application/octet-stream")
		w.WriteHeader(200)
		if len(b) > 0 {
			w.Write(b[:1])
		}
		w.(http.Flusher).Flush()
		select {
		case <-r.Context().Done():
		case <-time.After(10 * time.Second):
		}
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Write(b)
}

func (h *Hub) pushBegin(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Parent  int          `json:"parent"`
		Files   api.Manifest `json:"files"`
		Session string       `json:"session"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		errJSON(w, 400, err.Error())
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.PushBegins++
	h.LastSession = req.Session
	if h.FailPushBegin {
		errJSON(w, 503, "hub in manutenzione")
		return
	}
	if req.Parent != h.head {
		errJSON(w, 409, fmt.Sprintf("conflitto: parent %d ma HEAD è %d", req.Parent, h.head))
		return
	}
	h.nextPush++
	pid := fmt.Sprintf("p%d", h.nextPush)
	h.pushes[pid] = pendingPush{parent: req.Parent, files: req.Files}
	missing := []string{}
	seen := map[string]bool{}
	for _, need := range required(req.Files) {
		if _, ok := h.blobs[need]; !ok && !seen[need] {
			seen[need] = true
			missing = append(missing, need)
		}
	}
	writeJSON(w, 200, map[string]any{"pushId": pid, "missing": missing})
}

func required(m api.Manifest) []string {
	var out []string
	for _, fm := range m {
		if len(fm.Chunks) == 0 {
			out = append(out, fm.Hash)
			continue
		}
		for _, c := range fm.Chunks {
			out = append(out, c.Hash)
		}
	}
	return out
}

func (h *Hub) putBlob(w http.ResponseWriter, r *http.Request) {
	var body io.Reader = r.Body
	if r.Header.Get("Content-Encoding") == "gzip" {
		zr, err := gzip.NewReader(r.Body)
		if err != nil {
			errJSON(w, 400, err.Error())
			return
		}
		body = zr
	}
	b, err := io.ReadAll(body)
	if err != nil {
		errJSON(w, 400, err.Error())
		return
	}
	if Hash(b) != r.PathValue("hash") {
		errJSON(w, 400, "hash non combacia")
		return
	}
	h.mu.Lock()
	h.blobs[r.PathValue("hash")] = b
	h.mu.Unlock()
	w.WriteHeader(204)
}

func (h *Hub) commit(w http.ResponseWriter, r *http.Request) {
	pid := r.PathValue("pid")
	h.mu.Lock()
	if g, ok := h.committed[pid]; ok && !h.NonIdempotentCommit {
		h.mu.Unlock()
		writeJSON(w, 200, g)
		return
	}
	p, ok := h.pushes[pid]
	if !ok {
		h.mu.Unlock()
		errJSON(w, 404, "push inesistente")
		return
	}
	if p.parent != h.head {
		h.mu.Unlock()
		errJSON(w, 409, "conflitto: HEAD avanzato durante il push")
		return
	}
	for _, need := range required(p.files) {
		if _, ok := h.blobs[need]; !ok {
			h.mu.Unlock()
			errJSON(w, 400, "blob mancante "+need)
			return
		}
	}
	h.head++
	h.gens[h.head] = p.files
	delete(h.pushes, pid)
	g := api.GenSummary{N: h.head, Parent: p.parent, TS: time.Now()}
	h.committed[pid] = g
	h.Commits++
	drop := h.DropCommitResponses > 0
	if drop {
		h.DropCommitResponses--
	}
	h.mu.Unlock()
	if drop {
		// commit fatto, risposta persa: si chiude la connessione senza
		// rispondere
		if hj, ok := w.(http.Hijacker); ok {
			if c, _, err := hj.Hijack(); err == nil {
				c.Close()
				return
			}
		}
		panic(http.ErrAbortHandler)
	}
	writeJSON(w, 200, g)
}

func (h *Hub) lock(w http.ResponseWriter, _ *http.Request) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.lockSess != "" {
		errJSON(w, 409, "lock tenuto da altri")
		return
	}
	h.lockSess = fmt.Sprintf("s%d", time.Now().UnixNano())
	writeJSON(w, 200, api.LockAcquireResp{Session: h.lockSess, TTLSec: 90})
}

// StealLock simula un altro client che forza il lock.
func (h *Hub) StealLock() {
	h.mu.Lock()
	h.lockSess = "rubato"
	h.mu.Unlock()
}

func (h *Hub) heartbeat(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Session string `json:"session"`
	}
	json.NewDecoder(r.Body).Decode(&req)
	h.mu.Lock()
	defer h.mu.Unlock()
	if req.Session == "" || req.Session != h.lockSess {
		errJSON(w, 409, "conflitto: lock non tuo o già rilasciato")
		return
	}
	writeJSON(w, 200, api.HeartbeatResp{})
}

func (h *Hub) release(w http.ResponseWriter, r *http.Request) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if s := r.URL.Query().Get("session"); s != h.lockSess && r.URL.Query().Get("force") != "1" {
		errJSON(w, 409, "conflitto: lock non tuo")
		return
	}
	h.lockSess = ""
	w.WriteHeader(204)
}
