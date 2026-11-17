// Package api espone lo store via HTTP (REST + SSE).
package api

import (
	"compress/gzip"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"minesync/server/internal/events"
	"minesync/server/internal/i18n"
	"minesync/server/internal/settings"
	"minesync/server/internal/store"
)

// Version è la versione dell'hub, iniettata al build con
// -ldflags "-X minesync/server/internal/api.Version=…".
var Version = "dev"

// MemberLookup risolve un IP della rete ZeroTier nel membro corrispondente
// (implementato da ztauth.Resolver; un finto nei test).
type MemberLookup interface {
	Lookup(ip string) (name string, admin bool, ok bool)
}

// limiti contro l'esaurimento di memoria e disco
const (
	maxJSONBody  = 32 << 20 // manifest compresi
	maxBlobBody  = 4 << 30  // un singolo blob caricato
	maxJarBytes  = 512 << 20
	maxReadBytes = 32 << 20 // file di config letti in RAM (usercache, stats…)
)

// errForbidden: operazione non permessa a questo utente (403).
var errForbidden = i18n.Errorf("operazione riservata all'admin")

// reqLang è la lingua della risposta: ?lang= (per EventSource, che non può
// mettere header), poi Accept-Language, poi la lingua dell'hub.
func reqLang(r *http.Request) i18n.Lang {
	if l, ok := i18n.Parse(r.URL.Query().Get("lang")); ok {
		return l
	}
	return i18n.FromAcceptLanguage(r.Header.Get("Accept-Language"), i18n.Default())
}

// Identity è chi sta facendo la richiesta: il nome è quello del membro
// sulla rete ZeroTier, admin arriva da MINESYNC_ADMINS.
type Identity struct {
	Name  string
	Admin bool
}

type Server struct {
	Store   *store.Store
	ZT      MemberLookup // autenticazione via rete ZeroTier (nil = nessuna)
	DevUser string       // MINESYNC_DEV_USER: identità admin fissa, SOLO da loopback
	Bus     *events.Bus
	Web     http.Handler // UI statica (può essere nil)
	Started time.Time
	DataDir string
	DLDir   string // directory dei binari client scaricabili (può non esistere)
	DNSZone string // zona del DNS interno (es. "internal"); "" se disattivo
	// AllowedHosts: nomi host ammessi oltre a IP, localhost, zona DNS e
	// MINESYNC_HOSTS (anti DNS-rebinding).
	AllowedHosts []string
	Settings     *settings.Store // impostazioni modificabili dalla web UI (nil = niente pagina)
	Telegram     TelegramBot     // bot per la prova e lo stato (può essere nil)

	testMu   sync.Mutex // rate limit dei messaggi di prova
	lastTest time.Time

	probing    sync.Map // spazi con un test di raggiungibilità già in corso
	worldCache sync.Map // dati mondo/giocatori/mod in cache per generazione
	icons      iconCache

	diskMu        sync.Mutex // avviso "disco pieno": al massimo uno l'ora
	lastDiskAlert time.Time
}

// diskAlertEvery: ogni quanto, al massimo, si ripete l'avviso di disco pieno.
const diskAlertEvery = time.Hour

// Handler costruisce il mux completo.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /api/v1/status", s.wrap(s.handleStatus, false))
	mux.HandleFunc("GET /api/v1/whoami", s.wrap(s.handleWhoami, false))
	mux.HandleFunc("GET /api/v1/events", s.wrapRaw(s.handleEvents, false))

	mux.HandleFunc("GET /api/v1/spaces", s.wrap(s.handleListSpaces, false))
	mux.HandleFunc("POST /api/v1/spaces", s.wrap(s.handleCreateSpace, true))
	mux.HandleFunc("GET /api/v1/spaces/{id}", s.wrap(s.handleGetSpace, false))
	mux.HandleFunc("PATCH /api/v1/spaces/{id}", s.wrap(s.handleUpdateSpace, true))
	mux.HandleFunc("DELETE /api/v1/spaces/{id}", s.wrap(s.handleDeleteSpace, true))

	mux.HandleFunc("GET /api/v1/spaces/{id}/manifest", s.wrap(s.handleManifest, false))
	mux.HandleFunc("GET /api/v1/spaces/{id}/stats", s.wrap(s.handleStats, false))
	mux.HandleFunc("GET /api/v1/spaces/{id}/world", s.wrap(s.handleWorld, false))
	mux.HandleFunc("GET /api/v1/spaces/{id}/players", s.wrap(s.handlePlayers, false))
	mux.HandleFunc("GET /api/v1/spaces/{id}/mods", s.wrap(s.handleMods, false))
	mux.HandleFunc("GET /api/v1/spaces/{id}/mods/{file}", s.wrap(s.handleModDetail, false))
	mux.HandleFunc("GET /api/v1/spaces/{id}/mods/{file}/icon", s.wrapRaw(s.handleModIcon, false))
	mux.HandleFunc("GET /api/v1/spaces/{id}/icon", s.wrapRaw(s.handleIcon, false))
	mux.HandleFunc("GET /api/v1/spaces/{id}/generations", s.wrap(s.handleGenerations, false))
	mux.HandleFunc("GET /api/v1/spaces/{id}/generations/{n}", s.wrap(s.handleGeneration, false))
	mux.HandleFunc("GET /api/v1/spaces/{id}/generations/{n}/zip", s.wrapRaw(s.handleGenZip, false))
	mux.HandleFunc("DELETE /api/v1/spaces/{id}/generations/{n}", s.wrap(s.handleDeleteGeneration, true))
	mux.HandleFunc("POST /api/v1/spaces/{id}/restore", s.wrap(s.handleRestore, true))
	mux.HandleFunc("POST /api/v1/spaces/{id}/restore-file", s.wrap(s.handleRestoreFile, true))
	mux.HandleFunc("POST /api/v1/spaces/{id}/gc", s.wrap(s.handleGC, true))

	mux.HandleFunc("GET /api/v1/spaces/{id}/blobs/{hash}", s.wrapRaw(s.handleGetBlob, false))
	mux.HandleFunc("POST /api/v1/spaces/{id}/push/begin", s.wrap(s.handlePushBegin, false))
	mux.HandleFunc("PUT /api/v1/spaces/{id}/push/{pushId}/blobs/{hash}", s.wrap(s.handlePushBlob, false))
	mux.HandleFunc("POST /api/v1/spaces/{id}/push/{pushId}/commit", s.wrap(s.handlePushCommit, false))

	mux.HandleFunc("POST /api/v1/spaces/{id}/lock", s.wrap(s.handleLockAcquire, false))
	mux.HandleFunc("POST /api/v1/spaces/{id}/lock/heartbeat", s.wrap(s.handleLockBeat, false))
	mux.HandleFunc("DELETE /api/v1/spaces/{id}/lock", s.wrap(s.handleLockRelease, false))

	mux.HandleFunc("GET /api/v1/settings", s.wrap(s.handleGetSettings, true))
	mux.HandleFunc("PUT /api/v1/settings/telegram", s.wrap(s.handlePutTelegram, true))
	mux.HandleFunc("POST /api/v1/settings/telegram/test", s.wrap(s.handleTestTelegram, true))

	// download client: PUBBLICO (i binari non sono un segreto)
	mux.HandleFunc("GET /dl", s.handleDLPage)
	mux.HandleFunc("GET /dl/{file}", s.handleDLFile)
	mux.HandleFunc("GET /api/v1/dl", s.wrap(s.handleDLList, false))

	if s.Web != nil {
		mux.Handle("/", s.Web)
	}
	return securityHeaders(s.guard(logMiddleware(mux)))
}

func logMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		if strings.HasPrefix(r.URL.Path, "/api/") && !strings.Contains(r.URL.RawQuery, "stream=1") {
			log.Printf("%s %s (%s)", r.Method, r.URL.Path, time.Since(start).Round(time.Millisecond))
		}
	})
}

type ctxHandler func(w http.ResponseWriter, r *http.Request, who Identity) (any, error)

// wrap: auth + JSON encoding + mappatura errori.
func (s *Server) wrap(h ctxHandler, needAdmin bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		who, ok := s.authenticate(r)
		if !ok {
			jsonError(w, r, http.StatusUnauthorized, "non autenticato: connettiti alla rete ZeroTier")
			return
		}
		if needAdmin && !who.Admin {
			jsonMsg(w, http.StatusForbidden, i18n.Localize(reqLang(r), errForbidden))
			return
		}
		out, err := h(w, r, who)
		if err != nil {
			s.writeError(w, r, err)
			return
		}
		if out != nil {
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(out)
		}
	}
}

// wrapRaw: auth ma risposta gestita dall'handler (blob, SSE).
func (s *Server) wrapRaw(h func(w http.ResponseWriter, r *http.Request, who Identity), needAdmin bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		who, ok := s.authenticate(r)
		if !ok {
			jsonError(w, r, http.StatusUnauthorized, "non autenticato: connettiti alla rete ZeroTier")
			return
		}
		if needAdmin && !who.Admin {
			jsonMsg(w, http.StatusForbidden, i18n.Localize(reqLang(r), errForbidden))
			return
		}
		h(w, r, who)
	}
}

// authenticate: la rete ZeroTier è l'autenticazione.
// L'IP del membro è la sua identità, garantita crittograficamente dalla
// rete. MINESYNC_DEV_USER vale solo per le connessioni da loopback.
func (s *Server) authenticate(r *http.Request) (Identity, bool) {
	ip := remoteIP(r)
	if s.DevUser != "" {
		if a := net.ParseIP(ip); a != nil && a.IsLoopback() {
			return Identity{Name: s.DevUser, Admin: true}, true
		}
	}
	if s.ZT == nil {
		return Identity{}, false
	}
	if name, admin, ok := s.ZT.Lookup(ip); ok {
		return Identity{Name: name, Admin: admin}, true
	}
	return Identity{}, false
}

// remoteIP è l'IP del chiamante (senza porta).
func remoteIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// writeError mappa l'errore sullo status HTTP e lo traduce nella lingua
// della richiesta: lo store crea errori i18n senza sapere chi li leggerà.
func (s *Server) writeError(w http.ResponseWriter, r *http.Request, err error) {
	lang := reqLang(r)
	var le *store.LockedError
	var md *store.MassDeleteError
	var mbe *http.MaxBytesError
	var sg *store.SpaceGoneError
	var sb *store.StaleBaseError
	var bp *store.BadPathError
	var df *store.DiskFullError
	switch {
	case errors.As(err, &le):
		jsonReply(w, http.StatusConflict, map[string]any{
			"error": le.Localize(lang), "code": "locked", "holder": le.Holder, "stale": le.IsStale,
		})
	case errors.As(err, &md):
		jsonReply(w, http.StatusConflict, map[string]any{
			"error": md.Localize(lang), "code": "mass_delete", "removed": md.Removed, "total": md.Total,
		})
	case errors.As(err, &sg):
		jsonReply(w, http.StatusNotFound, map[string]any{"error": sg.Localize(lang), "code": "space_gone"})
	case errors.As(err, &sb):
		jsonReply(w, http.StatusConflict, map[string]any{"error": sb.Localize(lang), "code": "stale_base"})
	case errors.As(err, &bp):
		jsonReply(w, http.StatusBadRequest, map[string]any{"error": bp.Localize(lang), "code": "bad_path", "path": bp.Path})
	case errors.As(err, &df):
		s.diskAlert(df)
		jsonReply(w, http.StatusInsufficientStorage, map[string]any{"error": df.Localize(lang), "code": "disk_full"})
	case errors.As(err, &mbe):
		jsonError(w, r, http.StatusRequestEntityTooLarge, "corpo della richiesta troppo grande")
	case errors.Is(err, errUpstream):
		jsonMsg(w, http.StatusBadGateway, i18n.Localize(lang, err))
	case errors.Is(err, errTooMany):
		jsonMsg(w, http.StatusTooManyRequests, i18n.Localize(lang, err))
	case errors.Is(err, errForbidden):
		jsonMsg(w, http.StatusForbidden, i18n.Localize(lang, err))
	case errors.Is(err, store.ErrNotFound):
		jsonMsg(w, http.StatusNotFound, i18n.Localize(lang, err))
	case errors.Is(err, store.ErrConflict):
		jsonMsg(w, http.StatusConflict, i18n.Localize(lang, err))
	case errors.Is(err, store.ErrBadRequest):
		jsonMsg(w, http.StatusBadRequest, i18n.Localize(lang, err))
	default:
		jsonMsg(w, http.StatusInternalServerError, i18n.Localize(lang, err))
	}
}

// diskAlert registra (log + evento, che il bot Telegram inoltra) che il
// disco dell'hub è sotto la soglia: al massimo una volta l'ora.
func (s *Server) diskAlert(df *store.DiskFullError) {
	s.diskMu.Lock()
	if !s.lastDiskAlert.IsZero() && time.Since(s.lastDiskAlert) < diskAlertEvery {
		s.diskMu.Unlock()
		return
	}
	s.lastDiskAlert = time.Now()
	s.diskMu.Unlock()
	free, need := store.FormatBytes(df.Free), store.FormatBytes(df.Need)
	log.Print(i18n.Lf("ATTENZIONE: disco dei dati quasi pieno (%s liberi, soglia %s): push, upload e lock sono rifiutati", free, need))
	if s.Bus != nil {
		s.Bus.Publish(events.Event{Type: "disk",
			Text: i18n.M("⚠ disco dell'hub quasi pieno: %s liberi (soglia %s), push e nuove sessioni sono sospesi", free, need),
			Data: map[string]any{"free": df.Free, "need": df.Need}})
	}
}

// jsonError risponde {"error": …} col messaggio id tradotto nella lingua
// della richiesta.
func jsonError(w http.ResponseWriter, r *http.Request, code int, id string) {
	jsonMsg(w, code, i18n.T(reqLang(r), id))
}

// jsonMsg risponde {"error": msg} con un testo già tradotto.
func jsonMsg(w http.ResponseWriter, code int, msg string) {
	jsonReply(w, code, map[string]string{"error": msg})
}

func jsonReply(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func decode[T any](r *http.Request) (T, error) {
	var v T
	body := io.LimitReader(r.Body, maxJSONBody)
	if lr, ok := r.Body.(*limitedReader); ok {
		body = lr // già limitato, con l'errore giusto
	}
	if err := json.NewDecoder(body).Decode(&v); err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			return v, mbe // 413, non "JSON non valido"
		}
		return v, i18n.Errorf("%w: body JSON non valido: %v", store.ErrBadRequest, err)
	}
	return v, nil
}

// limitedReader è io.LimitReader che, oltre il limite, fallisce con
// *http.MaxBytesError invece di troncare: per i corpi decompressi, dove
// troncare darebbe un "JSON non valido" fuorviante.
type limitedReader struct {
	r    io.Reader
	left int64
}

func (l *limitedReader) Read(p []byte) (int, error) {
	if l.left <= 0 {
		var one [1]byte
		if n, _ := l.r.Read(one[:]); n > 0 {
			return 0, &http.MaxBytesError{Limit: maxJSONBody}
		}
		return 0, io.EOF
	}
	if int64(len(p)) > l.left {
		p = p[:l.left]
	}
	n, err := l.r.Read(p)
	l.left -= int64(n)
	return n, err
}

func (l *limitedReader) Close() error { return nil }

// --- handlers ---

func (s *Server) handleStatus(_ http.ResponseWriter, _ *http.Request, _ Identity) (any, error) {
	spaces := s.Store.ListSpaces()
	out := map[string]any{
		"name": "minesync-hub", "version": Version,
		"go": runtime.Version(), "uptimeSec": int(time.Since(s.Started).Seconds()),
		"spaces": len(spaces), "time": time.Now().UTC(),
		"dnsZone": s.DNSZone, // "" se il DNS interno è disattivo
	}
	// spazio sul volume dei dati (assente se non misurabile)
	if free, total, err := s.Store.DiskSpace(); err == nil && total > 0 {
		out["diskFree"], out["diskTotal"] = free, total
		out["diskMinFree"] = s.Store.MinFreeBytes(total)
	}
	return out, nil
}

func (s *Server) handleWhoami(_ http.ResponseWriter, _ *http.Request, who Identity) (any, error) {
	return map[string]any{"name": who.Name, "admin": who.Admin}, nil
}

type spaceView struct {
	store.Space
	Head      int             `json:"head"`
	Lock      *store.LockInfo `json:"lock,omitempty"`
	Stale     bool            `json:"lockStale,omitempty"`
	DiskBytes int64           `json:"diskBytes,omitempty"`
}

func (s *Server) spaceView(id string) (spaceView, error) {
	meta, head, lk, err := s.Store.GetSpace(id)
	if err != nil {
		return spaceView{}, err
	}
	v := spaceView{Space: meta, Head: head, Lock: lk}
	if lk != nil {
		v.Stale = lk.Stale(time.Now())
	}
	return v, nil
}

func (s *Server) handleListSpaces(_ http.ResponseWriter, _ *http.Request, _ Identity) (any, error) {
	var out []spaceView
	for _, sp := range s.Store.ListSpaces() {
		v, err := s.spaceView(sp.ID)
		if err != nil {
			continue
		}
		out = append(out, v)
	}
	if out == nil {
		out = []spaceView{}
	}
	return out, nil
}

func (s *Server) handleCreateSpace(_ http.ResponseWriter, r *http.Request, who Identity) (any, error) {
	req, err := decode[struct {
		Name    string   `json:"name"`
		Profile string   `json:"profile"`
		Ignore  []string `json:"ignore"`
	}](r)
	if err != nil {
		return nil, err
	}
	sp, err := s.Store.CreateSpace(req.Name, req.Profile, req.Ignore)
	if err != nil {
		return nil, err
	}
	s.Bus.Publish(events.Event{Type: "space", Space: sp.ID, Actor: who.Name,
		Text: i18n.M("%s ha creato lo spazio «%s» (profilo %s)", who.Name, sp.Name, sp.Profile)})
	return sp, nil
}

func (s *Server) handleGetSpace(_ http.ResponseWriter, r *http.Request, _ Identity) (any, error) {
	v, err := s.spaceView(r.PathValue("id"))
	if err != nil {
		return nil, err
	}
	// solo nel dettaglio: quanto pesa l'archivio su disco
	if du, err := s.Store.DiskUsage(v.ID); err == nil {
		v.DiskBytes = du
	}
	return v, nil
}

func (s *Server) handleUpdateSpace(_ http.ResponseWriter, r *http.Request, who Identity) (any, error) {
	req, err := decode[struct {
		Name   *string  `json:"name"`
		Ignore []string `json:"ignore"`
	}](r)
	if err != nil {
		return nil, err
	}
	sp, err := s.Store.UpdateSpace(r.PathValue("id"), req.Name, req.Ignore)
	if err != nil {
		return nil, err
	}
	s.Bus.Publish(events.Event{Type: "space", Space: sp.ID, Actor: who.Name,
		Text: i18n.M("%s ha aggiornato le impostazioni di «%s»", who.Name, sp.Name)})
	return sp, nil
}

func (s *Server) handleDeleteSpace(_ http.ResponseWriter, r *http.Request, who Identity) (any, error) {
	id := r.PathValue("id")
	// lo store rifiuta l'eliminazione se qualcuno sta giocando (409)
	if err := s.Store.DeleteSpace(id); err != nil {
		return nil, err
	}
	s.Bus.Publish(events.Event{Type: "space", Space: id, Actor: who.Name,
		Text: i18n.M("%s ha eliminato lo spazio %s", who.Name, id),
		Data: map[string]any{"deleted": true}})
	return map[string]bool{"ok": true}, nil
}

func (s *Server) handleManifest(_ http.ResponseWriter, r *http.Request, _ Identity) (any, error) {
	id := r.PathValue("id")
	head, err := s.Store.Head(id)
	if err != nil {
		return nil, err
	}
	n := head
	if q := r.URL.Query().Get("gen"); q != "" {
		n, err = strconv.Atoi(q)
		if err != nil {
			return nil, i18n.Errorf("%w: gen non numerico", store.ErrBadRequest)
		}
	}
	m, digest, err := s.Store.ManifestDigestAt(id, n)
	if err != nil {
		return nil, err
	}
	return map[string]any{"gen": n, "head": head, "digest": digest, "files": m}, nil
}

func (s *Server) handleStats(_ http.ResponseWriter, r *http.Request, _ Identity) (any, error) {
	return s.Store.Stats(r.PathValue("id"))
}

func (s *Server) handleGenerations(_ http.ResponseWriter, r *http.Request, _ Identity) (any, error) {
	limit := 100
	if q := r.URL.Query().Get("limit"); q != "" {
		n, err := strconv.Atoi(q)
		if err != nil {
			return nil, i18n.Errorf("%w: limit non numerico", store.ErrBadRequest)
		}
		limit = n
	}
	gens, err := s.Store.Generations(r.PathValue("id"), limit)
	if err != nil {
		return nil, err
	}
	if gens == nil {
		gens = []store.GenSummary{}
	}
	return gens, nil
}

func (s *Server) handleGeneration(_ http.ResponseWriter, r *http.Request, _ Identity) (any, error) {
	n, err := strconv.Atoi(r.PathValue("n"))
	if err != nil {
		return nil, i18n.Errorf("%w: n non numerico", store.ErrBadRequest)
	}
	return s.Store.Generation(r.PathValue("id"), n)
}

func (s *Server) handleDeleteGeneration(_ http.ResponseWriter, r *http.Request, who Identity) (any, error) {
	id := r.PathValue("id")
	n, err := strconv.Atoi(r.PathValue("n"))
	if err != nil {
		return nil, i18n.Errorf("%w: n non numerico", store.ErrBadRequest)
	}
	if err := s.Store.DeleteGeneration(id, n); err != nil {
		return nil, err
	}
	s.Bus.Publish(events.Event{Type: "gc", Space: id, Actor: who.Name,
		Text: i18n.M("%s ha eliminato la versione #%d", who.Name, n)})
	return map[string]bool{"ok": true}, nil
}

func (s *Server) handleRestore(_ http.ResponseWriter, r *http.Request, who Identity) (any, error) {
	req, err := decode[struct {
		Gen int `json:"gen"`
	}](r)
	if err != nil {
		return nil, err
	}
	id := r.PathValue("id")
	// lo store rifiuta il restore se qualcuno sta giocando
	gen, err := s.Store.Restore(id, req.Gen, who.Name)
	if err != nil {
		return nil, err
	}
	s.Bus.Publish(events.Event{Type: "restore", Space: id, Actor: who.Name,
		Text: i18n.M("%s ha ripristinato la generazione %d (nuova: %d)", who.Name, req.Gen, gen.N),
		Data: map[string]any{"gen": gen.N, "restored": req.Gen}})
	return gen, nil
}

func (s *Server) handleRestoreFile(_ http.ResponseWriter, r *http.Request, who Identity) (any, error) {
	req, err := decode[struct {
		Path string `json:"path"`
		Gen  int    `json:"gen"` // 0 = scegli la versione integra più recente
	}](r)
	if err != nil {
		return nil, err
	}
	id := r.PathValue("id")
	gen, err := s.Store.RestoreFile(id, req.Path, req.Gen, who.Name)
	if err != nil {
		return nil, err
	}
	s.Bus.Publish(events.Event{Type: "restore", Space: id, Actor: who.Name,
		Text: i18n.M("%s ha ripristinato %s (versione integra, gen %d)", who.Name, req.Path, gen.N),
		Data: map[string]any{"gen": gen.N, "path": req.Path}})
	return gen, nil
}

func (s *Server) handleGC(_ http.ResponseWriter, r *http.Request, who Identity) (any, error) {
	keep := 20
	if q := r.URL.Query().Get("keep"); q != "" {
		n, err := strconv.Atoi(q)
		if err != nil || n < 1 {
			return nil, i18n.Errorf("%w: keep deve essere un intero ≥ 1", store.ErrBadRequest)
		}
		keep = n
	}
	id := r.PathValue("id")
	res, err := s.Store.GC(id, keep)
	if err != nil {
		return nil, err
	}
	s.Bus.Publish(events.Event{Type: "gc", Space: id, Actor: who.Name,
		Text: i18n.M("GC: %d generazioni potate, %d blob eliminati (%s MB liberati)",
			res.GenerationsPruned, res.BlobsDeleted, fmt.Sprintf("%.1f", float64(res.BytesFreed)/1e6))})
	return res, nil
}

// --- blob & push ---

// handleGetBlob serve un blob. Se su disco è già gzip e il client accetta
// gzip, i byte partono così come sono (zero ricompressione); altrimenti
// vengono decompressi al volo. L'hash è sempre del contenuto originale.
func (s *Server) handleGetBlob(w http.ResponseWriter, r *http.Request, _ Identity) {
	f, size, gzipped, err := s.Store.OpenBlobRaw(r.PathValue("id"), r.PathValue("hash"))
	if err != nil {
		s.writeError(w, r, err)
		return
	}
	defer f.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	if gzipped {
		if strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
			w.Header().Set("Content-Encoding", "gzip")
			w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
			io.Copy(w, f)
			return
		}
		zr, err := gzip.NewReader(f)
		if err != nil {
			s.writeError(w, r, err)
			return
		}
		defer zr.Close()
		io.Copy(w, zr) // lunghezza ignota: chunked
		return
	}
	w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
	io.Copy(w, f)
}

func (s *Server) handlePushBegin(w http.ResponseWriter, r *http.Request, who Identity) (any, error) {
	// il manifest può arrivare compresso (client ≥3.2): il limite vale sui
	// byte DECOMPRESSI, e anche quelli compressi hanno un tetto
	if strings.EqualFold(strings.TrimSpace(r.Header.Get("Content-Encoding")), "gzip") {
		zr, err := gzip.NewReader(http.MaxBytesReader(w, r.Body, maxJSONBody))
		if err != nil {
			return nil, i18n.Errorf("%w: gzip non valido: %v", store.ErrBadRequest, err)
		}
		defer zr.Close()
		r.Body = &limitedReader{r: zr, left: maxJSONBody}
	}
	req, err := decode[struct {
		Parent       int            `json:"parent"`
		ParentDigest string         `json:"parentDigest"` // identità della base (3.2+)
		Message      string         `json:"message"`
		Files        store.Manifest `json:"files"`
		Corrupt      []string       `json:"corrupt"`
		Session      string         `json:"session"` // sessione del lock tenuto dal chiamante
	}](r)
	if err != nil {
		return nil, err
	}
	q := r.URL.Query()
	// il push richiede il lock (owner + sessione); senza lock solo gli admin
	noLock := q.Get("nolock") == "1"
	allowMass := q.Get("allowMassDelete") == "1"
	if (noLock || allowMass) && !who.Admin {
		return nil, i18n.Errorf("%w: nolock e allowMassDelete", errForbidden)
	}
	pid, missing, err := s.Store.BeginPush(r.PathValue("id"), store.PushOptions{
		Author: who.Name, Message: req.Message, Parent: req.Parent, ParentDigest: req.ParentDigest,
		Files: req.Files, Corrupt: req.Corrupt,
		LockSession: req.Session, NoLock: noLock, AllowMassDelete: allowMass,
	})
	if err != nil {
		return nil, err
	}
	if missing == nil {
		missing = []string{}
	}
	return map[string]any{"pushId": pid, "missing": missing}, nil
}

func (s *Server) handlePushBlob(w http.ResponseWriter, r *http.Request, _ Identity) (any, error) {
	body := http.MaxBytesReader(w, r.Body, maxBlobBody)
	defer body.Close()
	gzipped := strings.Contains(r.Header.Get("Content-Encoding"), "gzip")
	n, err := s.Store.PushBlob(r.PathValue("id"), r.PathValue("pushId"), r.PathValue("hash"), body, gzipped)
	if err != nil {
		return nil, err
	}
	return map[string]any{"ok": true, "bytes": n}, nil
}

func (s *Server) handlePushCommit(_ http.ResponseWriter, r *http.Request, who Identity) (any, error) {
	id := r.PathValue("id")
	gen, replay, err := s.Store.CommitPush(id, r.PathValue("pushId"))
	if err != nil {
		return nil, err
	}
	if replay {
		return gen, nil // commit già fatto: la prima risposta si era persa
	}
	// la coda "— messaggio (+a ~c −r)" resta dopo il trattino lungo in
	// entrambe le lingue: web UI e TUI la tagliano lì
	msg := i18n.M("%s ha pushato la generazione %d — %s (+%d ~%d −%d)",
		who.Name, gen.N, gen.Message, gen.Stats.Added, gen.Stats.Changed, gen.Stats.Removed)
	if gen.Message == "" {
		msg = i18n.M("%s ha pushato la generazione %d — salvataggio (+%d ~%d −%d)",
			who.Name, gen.N, gen.Stats.Added, gen.Stats.Changed, gen.Stats.Removed)
	}
	s.Bus.Publish(events.Event{Type: "push", Space: id, Actor: who.Name, Text: msg,
		Data: map[string]any{"gen": gen.N}})
	return gen, nil
}

// --- lock ---

func (s *Server) handleLockAcquire(_ http.ResponseWriter, r *http.Request, who Identity) (any, error) {
	req, err := decode[struct {
		Info   map[string]string `json:"info"`
		TTLSec int               `json:"ttlSec"`
	}](r)
	if err != nil {
		return nil, err
	}
	id := r.PathValue("id")
	lk, tookOver, err := s.Store.AcquireLock(id, who.Name, req.Info, req.TTLSec)
	if err != nil {
		return nil, err
	}
	msg := i18n.M("%s ha preso il lock", who.Name)
	if tookOver != nil {
		msg = i18n.M("%s ha preso il lock (era stale di %s)", who.Name, tookOver.Owner)
	}
	s.Bus.Publish(events.Event{Type: "lock", Space: id, Actor: who.Name, Text: msg})
	return map[string]any{"session": lk.Session, "ttlSec": lk.TTLSec, "tookOver": tookOver}, nil
}

func (s *Server) handleLockBeat(_ http.ResponseWriter, r *http.Request, who Identity) (any, error) {
	req, err := decode[struct {
		Session string   `json:"session"`
		Players []string `json:"players"`
		Ready   bool     `json:"ready"`
	}](r)
	if err != nil {
		return nil, err
	}
	id := r.PathValue("id")
	// la sessione è l'autorità; il nome attuale aggiorna solo quello mostrato
	lk, err := s.Store.HeartbeatLock(id, req.Session, who.Name, req.Players, req.Ready)
	if err != nil {
		return nil, err
	}
	// server avviato: testa se la porta è raggiungibile dall'hub (prospettiva
	// dei giocatori). Primo test appena pronto, poi ogni 60s.
	if lk.Ready {
		if lk.Reachable == nil || time.Since(lk.ReachAt) > 60*time.Second {
			s.probeReachable(id, req.Session, remoteIP(r), lk.Info["port"])
		}
	}
	return map[string]any{"ok": true, "lastBeat": lk.LastBeat.UTC(), "reachable": lk.Reachable}, nil
}

// probeReachable prova a connettersi (TCP) al server Minecraft di chi hosta:
// l'hub sta sulla stessa rete ZeroTier dei giocatori, quindi il suo esito
// riflette quello che vedono loro. Si prova SOLO l'IP da cui arriva
// l'heartbeat (mai un host scelto dal client: niente port scan della LAN
// dell'hub), sulla porta dichiarata se valida. Uno per spazio alla volta.
func (s *Server) probeReachable(id, session, ip, port string) {
	port = strings.TrimSpace(port)
	if port == "" {
		port = "25565"
	}
	if p, err := strconv.Atoi(port); err != nil || p < 1 || p > 65535 {
		return
	}
	if net.ParseIP(ip) == nil {
		return
	}
	if _, busy := s.probing.LoadOrStore(id, true); busy {
		return
	}
	go func() {
		defer s.probing.Delete(id)
		conn, err := net.DialTimeout("tcp", net.JoinHostPort(ip, port), 5*time.Second)
		if conn != nil {
			conn.Close()
		}
		s.Store.SetReachable(id, session, err == nil)
	}()
}

func (s *Server) handleLockRelease(_ http.ResponseWriter, r *http.Request, who Identity) (any, error) {
	id := r.PathValue("id")
	askedForce := r.URL.Query().Get("force") == "1"
	session := r.URL.Query().Get("session")
	// force solo per gli admin; un lock stale lo libera chiunque anche senza
	force := askedForce && who.Admin
	removed, err := s.Store.ReleaseLock(id, session, force)
	if err != nil {
		if askedForce && !who.Admin && errors.Is(err, store.ErrConflict) {
			return nil, i18n.Errorf("%w: forzare il rilascio di un lock attivo", errForbidden)
		}
		return nil, err
	}
	if removed != nil {
		typ := "unlock"
		msg := i18n.M("%s ha rilasciato il lock", removed.Owner)
		if force && removed.Owner != who.Name {
			typ = "force"
			msg = i18n.M("⚠ %s ha FORZATO il rilascio del lock di %s", who.Name, removed.Owner)
		} else if removed.Owner != who.Name {
			msg = i18n.M("%s ha liberato il lock stale di %s", who.Name, removed.Owner)
		}
		s.Bus.Publish(events.Event{Type: typ, Space: id, Actor: who.Name, Text: msg})
	}
	return map[string]any{"ok": true, "removed": removed}, nil
}

// --- eventi ---

func (s *Server) handleEvents(w http.ResponseWriter, r *http.Request, _ Identity) {
	if r.URL.Query().Get("stream") != "1" {
		n := 100
		if q := r.URL.Query().Get("limit"); q != "" {
			if v, err := strconv.Atoi(q); err == nil {
				n = v
			}
		}
		lang := reqLang(r)
		out := s.Bus.Recent(n)
		for i := range out {
			out[i] = out[i].Localized(lang)
		}
		if out == nil {
			out = []events.Event{}
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(out)
		return
	}
	fl, ok := w.(http.Flusher)
	if !ok {
		jsonError(w, r, http.StatusInternalServerError, "streaming non supportato")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	lang := reqLang(r)
	ch := s.Bus.Subscribe()
	defer s.Bus.Unsubscribe(ch)
	fmt.Fprint(w, ": connesso\n\n")
	fl.Flush()
	keepalive := time.NewTicker(25 * time.Second)
	defer keepalive.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-keepalive.C:
			fmt.Fprint(w, ": ping\n\n")
			fl.Flush()
		case e, ok := <-ch:
			if !ok {
				return
			}
			b, _ := json.Marshal(e.Localized(lang))
			fmt.Fprintf(w, "data: %s\n\n", b)
			fl.Flush()
		}
	}
}
