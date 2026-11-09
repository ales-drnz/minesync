// Package store è il cuore dell'hub: spaces, blob content-addressed (SHA-256),
// generazioni immutabili e lock arbitrati in memoria con persistenza su disco.
//
// Layout su disco (root = /data):
//
//	spaces/<id>/space.json
//	spaces/<id>/HEAD
//	spaces/<id>/generations/<n>.json
//	spaces/<id>/blobs/<hh>/<hash>
//	spaces/<id>/lock.json
//
// Ogni scrittura passa da writeAtomic (temp + fsync + rename + fsync dir).
package store

import (
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"minesync/server/internal/i18n"
)

// Chunk è un pezzo di un file grande (delta sync): un normale blob.
type Chunk struct {
	Hash string `json:"h"`
	Size int64  `json:"s"`
}

// FileMeta descrive un file dentro un manifest. Se Chunks è valorizzato il
// file viaggia a pezzi: Hash resta quello dell'INTERO contenuto (per diff e
// verifica), ma i blob sull'hub sono i chunk — il blob "intero" non esiste.
type FileMeta struct {
	Hash   string  `json:"h"`
	Size   int64   `json:"s"`
	Exec   bool    `json:"x,omitempty"`
	Chunks []Chunk `json:"c,omitempty"`
}

// Manifest mappa percorsi relativi (separatore /) ai loro metadati.
type Manifest map[string]FileMeta

// Stats riassume una generazione rispetto alla precedente.
type Stats struct {
	Files   int   `json:"files"`
	Bytes   int64 `json:"bytes"`
	Added   int   `json:"added"`
	Changed int   `json:"changed"`
	Removed int   `json:"removed"`
}

// Generation è un commit immutabile.
type Generation struct {
	N       int       `json:"n"`
	Parent  int       `json:"parent"` // 0 = nessun genitore
	Author  string    `json:"author"`
	Message string    `json:"message"`
	TS      time.Time `json:"ts"`
	Restore int       `json:"restore,omitempty"` // se >0, è un restore di quella generazione
	Files   Manifest  `json:"files"`
	Stats   Stats     `json:"stats"`
	Corrupt []string  `json:"corrupt,omitempty"` // region danneggiati introdotti qui
}

// GenSummary è una voce della storia senza il manifest completo.
type GenSummary struct {
	N       int       `json:"n"`
	Parent  int       `json:"parent"`
	Author  string    `json:"author"`
	Message string    `json:"message"`
	TS      time.Time `json:"ts"`
	Restore int       `json:"restore,omitempty"`
	Stats   Stats     `json:"stats"`
	Corrupt []string  `json:"corrupt,omitempty"`
}

// Summary restituisce la generazione senza manifest.
func (g Generation) Summary() GenSummary {
	return GenSummary{N: g.N, Parent: g.Parent, Author: g.Author, Message: g.Message,
		TS: g.TS, Restore: g.Restore, Stats: g.Stats, Corrupt: g.Corrupt}
}

// Space è la configurazione di uno spazio sincronizzato.
type Space struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Profile   string    `json:"profile"` // "minecraft" | "generic"
	Ignore    []string  `json:"ignore"`
	CreatedAt time.Time `json:"createdAt"`
}

const (
	DefaultLockTTLSec = 90
	MaxLockTTLSec     = 600 // tetto al TTL chiesto dal client
	pushSessionTTL    = 2 * time.Hour
	maxPushesPerUser  = 4 // sessioni di push aperte per utente
	committedKeep     = 64
	committedTTL      = 3 * time.Hour

	// protezione dai push che svuotano il mondo (C4)
	massDeleteMinFiles = 20
	massDeleteRatio    = 0.5
)

// DefaultIgnore restituisce le esclusioni di default per un profilo.
func DefaultIgnore(profile string) []string {
	switch profile {
	case "minecraft":
		return []string{
			// diagnostica e roba rigenerata a ogni avvio
			"logs/**", "crash-reports/**", "debug/**", "spark/**",
			"hs_err_pid*.log", "replay_pid*.log", "*.hprof",
			"usercache.json", "usernamecache.json",
			// lock del mondo: copiarlo fra macchine fa credere al server
			// che il mondo sia già aperto altrove
			"session.lock", "**/session.lock", "*.lock",
			// cache dei loader: si rigenerano, e contengono jar rimappati
			// validi solo per quella macchina
			".fabric/**", ".mixin.out/**", ".cache/**",
			// backup automatici dei mod di backup: sincronizzarli moltiplica
			// per N lo spazio dell'hub senza dare niente in cambio
			"backups/**", "simplebackups/**", "ftbbackups/**", "ftbbackups2/**",
			"aroma1997/**", "world_backup*/**",
			// NOTA: libraries/, versions/ e i runtime inclusi NON si escludono.
			// Sembrerebbe sensato (sono pesanti e riscaricabili), ma su
			// Forge e NeoForge libraries/ la crea l'installer, non il primo
			// avvio: senza, il run.sh del pack non parte proprio. Sono jar
			// indipendenti dal sistema operativo e la deduplica li carica una
			// volta sola, quindi si sincronizzano.
			// spazzatura di sistema
			".DS_Store", "**/.DS_Store", "._*", "Thumbs.db", "desktop.ini",
			".Spotlight-V100/**", ".Trashes/**", "$RECYCLE.BIN/**",
			// artefatti di MineSync e del versionamento
			".minesync*", "*.minesyncpart", ".git/**",
		}
	default:
		return []string{".minesync*", "*.minesyncpart", ".git/**", ".DS_Store", "**/.DS_Store"}
	}
}

var (
	// Gli errori dello store sono i18n: si traducono al bordo HTTP con la
	// lingua della richiesta (i18n.Localize), Error() usa quella dell'hub.
	ErrNotFound   = i18n.Errorf("non trovato")
	ErrConflict   = i18n.Errorf("conflitto")
	ErrLocked     = i18n.Errorf("spazio lockato")
	ErrBadRequest = i18n.Errorf("richiesta non valida")
)

// LockedError trasporta i dettagli del titolare del lock (Holder nil = il
// lock non c'è più).
type LockedError struct {
	Holder  *LockInfo
	IsStale bool
}

// Localize: il messaggio nella lingua l. In inglese contiene sempre "lock":
// i client lo usano per riconoscere un lock perso.
func (e *LockedError) Localize(l i18n.Lang) string {
	if e.Holder == nil {
		return i18n.T(l, "il lock non è più tuo: riacquisiscilo prima di pushare")
	}
	return i18n.Tf(l, "lockato da %s", e.Holder.Owner)
}
func (e *LockedError) Error() string { return e.Localize(i18n.Default()) }
func (e *LockedError) Unwrap() error { return ErrLocked }

// MassDeleteError: il push eliminerebbe troppi file di HEAD in un colpo solo.
type MassDeleteError struct {
	Removed, Total int
}

func (e *MassDeleteError) Localize(l i18n.Lang) string {
	return i18n.Tf(l, "il push eliminerebbe %d file su %d: rifiutato per sicurezza (un admin può forzarlo)", e.Removed, e.Total)
}
func (e *MassDeleteError) Error() string { return e.Localize(i18n.Default()) }
func (e *MassDeleteError) Unwrap() error { return ErrConflict }

// Store gestisce tutti gli spazi sotto una root.
type Store struct {
	root string

	// KeepLast: quante generazioni conservare comunque. La retention
	// automatica dopo ogni push non tocca mai le generazioni più giovani di
	// 24 ore né l'ultima di ciascuno degli ultimi 7 giorni (0 = nessuna
	// potatura automatica).
	KeepLast int

	mu     sync.Mutex
	spaces map[string]*spaceState
}

type spaceState struct {
	mu        sync.Mutex
	meta      Space
	head      int
	lock      *LockInfo
	pushes    map[string]*pushSession
	committed []committedPush   // ultimi commit, per l'idempotenza (C3)
	genTS     map[int]time.Time // cache dei timestamp (retention)
	deleted   bool              // spazio eliminato: niente più scritture

	lastRetention time.Time // ultima retention automatica (throttle)

	stats      *SpaceStats // caricate pigramente da stats.json
	statsSaved time.Time   // ultimo flush su disco (throttle)
}

type pushSession struct {
	ID          string
	Author      string
	Message     string
	Parent      int
	Files       Manifest
	Corrupt     []string
	LockSession string // sessione di lock a cui è legato ("" = push senza lock)
	Created     time.Time
	LastActive  time.Time       // scadenza calcolata da qui (R17)
	blobs       map[string]bool // blob che il manifest richiede
}

type committedPush struct {
	id  string
	gen GenSummary
	at  time.Time
}

// Open carica (o inizializza) uno store sulla directory root.
func Open(root string) (*Store, error) {
	if err := os.MkdirAll(filepath.Join(root, "spaces"), 0o775); err != nil {
		return nil, err
	}
	s := &Store{root: root, spaces: map[string]*spaceState{}}
	entries, err := os.ReadDir(filepath.Join(root, "spaces"))
	if err != nil {
		return nil, err
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		name := e.Name()
		if strings.HasPrefix(name, ".deleted-") {
			// eliminazione interrotta da un riavvio: si completa ora
			os.RemoveAll(filepath.Join(root, "spaces", name))
			continue
		}
		if _, err := os.Stat(filepath.Join(s.spaceDir(name), "space.json")); err != nil {
			log.Print(i18n.Lf("store: ATTENZIONE, %s non ha space.json: ignorata", s.spaceDir(name)))
			continue
		}
		st, err := s.loadSpace(name)
		if err != nil {
			return nil, i18n.Errorf("space %s: %w", name, err)
		}
		s.spaces[name] = st
	}
	return s, nil
}

func (s *Store) loadSpace(id string) (*spaceState, error) {
	dir := s.spaceDir(id)
	var meta Space
	if err := readJSON(filepath.Join(dir, "space.json"), &meta); err != nil {
		return nil, err
	}
	st := &spaceState{meta: meta, pushes: map[string]*pushSession{}, genTS: map[int]time.Time{}}
	head, err := s.readHead(id)
	if err != nil {
		head, err = s.rebuildHead(id, err)
		if err != nil {
			return nil, err
		}
	}
	st.head = head
	var lk LockInfo
	if err := readJSON(filepath.Join(dir, "lock.json"), &lk); err == nil && lk.Owner != "" {
		st.lock = &lk
	}
	return st, nil
}

// readHead legge HEAD e verifica che punti a una generazione leggibile.
func (s *Store) readHead(id string) (int, error) {
	b, err := os.ReadFile(filepath.Join(s.spaceDir(id), "HEAD"))
	if err != nil {
		return 0, err
	}
	n, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil || n < 0 {
		return 0, i18n.Errorf("HEAD illeggibile (%q)", strings.TrimSpace(string(b)))
	}
	if n > 0 {
		if _, err := s.loadGen(id, n); err != nil {
			return 0, i18n.Errorf("HEAD=%d ma la generazione non è leggibile: %w", n, err)
		}
	}
	return n, nil
}

// rebuildHead ricostruisce HEAD dalla generazione valida più alta su disco.
func (s *Store) rebuildHead(id string, cause error) (int, error) {
	ns, err := s.genNumbers(id)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return 0, err
	}
	head := 0
	for i := len(ns) - 1; i >= 0; i-- {
		if _, err := s.loadGen(id, ns[i]); err == nil {
			head = ns[i]
			break
		}
	}
	log.Print(i18n.Lf("store: ATTENZIONE, spazio %s: %v → HEAD ricostruito a %d", id, cause, head))
	if err := writeFileAtomic(filepath.Join(s.spaceDir(id), "HEAD"), []byte(strconv.Itoa(head))); err != nil {
		return 0, err
	}
	return head, nil
}

func (s *Store) spaceDir(id string) string { return filepath.Join(s.root, "spaces", id) }

func (s *Store) space(id string) (*spaceState, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	st, ok := s.spaces[id]
	if !ok {
		return nil, i18n.Errorf("space %q: %w", id, ErrNotFound)
	}
	return st, nil
}

var slugRe = regexp.MustCompile(`[^a-z0-9-]+`)

// Slug normalizza un nome in un id valido.
func Slug(name string) string {
	s := strings.ToLower(strings.TrimSpace(name))
	s = slugRe.ReplaceAllString(s, "-")
	s = strings.Trim(s, "-")
	if s == "" {
		s = "space"
	}
	return s
}

// CreateSpace crea un nuovo spazio vuoto.
func (s *Store) CreateSpace(name, profile string, ignore []string) (Space, error) {
	if profile == "" {
		profile = "generic"
	}
	if name == "" {
		return Space{}, i18n.Errorf("%w: nome mancante", ErrBadRequest)
	}
	id := Slug(name)
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.spaces[id]; exists {
		return Space{}, i18n.Errorf("space %q: %w", id, ErrConflict)
	}
	if ignore == nil {
		ignore = DefaultIgnore(profile)
	}
	meta := Space{ID: id, Name: name, Profile: profile, Ignore: ignore, CreatedAt: time.Now().UTC()}
	dir := s.spaceDir(id)
	for _, sub := range []string{"generations", "blobs"} {
		if err := os.MkdirAll(filepath.Join(dir, sub), 0o775); err != nil {
			return Space{}, err
		}
	}
	if err := writeFileAtomic(filepath.Join(dir, "HEAD"), []byte("0")); err != nil {
		return Space{}, err
	}
	// space.json per ultimo: è il marcatore "spazio completo" per Open
	if err := writeJSON(filepath.Join(dir, "space.json"), meta); err != nil {
		return Space{}, err
	}
	s.spaces[id] = &spaceState{meta: meta, pushes: map[string]*pushSession{}, genTS: map[int]time.Time{}}
	return meta, nil
}

// ListSpaces restituisce gli spazi in ordine alfabetico.
func (s *Store) ListSpaces() []Space {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Space, 0, len(s.spaces))
	for _, st := range s.spaces {
		st.mu.Lock()
		out = append(out, st.meta)
		st.mu.Unlock()
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// GetSpace restituisce metadati, HEAD e lock corrente.
func (s *Store) GetSpace(id string) (Space, int, *LockInfo, error) {
	st, err := s.space(id)
	if err != nil {
		return Space{}, 0, nil, err
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	var lk *LockInfo
	if st.lock != nil {
		lk = st.lock.Redacted()
	}
	return st.meta, st.head, lk, nil
}

// UpdateSpace modifica nome e/o ignore patterns.
func (s *Store) UpdateSpace(id string, name *string, ignore []string) (Space, error) {
	st, err := s.space(id)
	if err != nil {
		return Space{}, err
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	meta := st.meta
	if name != nil && *name != "" {
		meta.Name = *name
	}
	if ignore != nil {
		meta.Ignore = ignore
	}
	if err := writeJSON(filepath.Join(s.spaceDir(id), "space.json"), meta); err != nil {
		return Space{}, err
	}
	st.meta = meta
	return st.meta, nil
}

// DeleteSpace elimina uno spazio e tutti i suoi dati. La directory viene
// prima rinominata (atomico) e poi cancellata: un upload concorrente non può
// ricrearla, perché nessuna scrittura fa MkdirAll dentro uno spazio.
func (s *Store) DeleteSpace(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	st, ok := s.spaces[id]
	if !ok {
		return i18n.Errorf("space %q: %w", id, ErrNotFound)
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	trash := filepath.Join(s.root, "spaces", ".deleted-"+id+"-"+randomID())
	if err := os.Rename(s.spaceDir(id), trash); err != nil {
		return err
	}
	syncDir(filepath.Join(s.root, "spaces"))
	st.deleted = true
	st.pushes = map[string]*pushSession{}
	delete(s.spaces, id)
	if err := os.RemoveAll(trash); err != nil {
		log.Print(i18n.Lf("store: pulizia di %s incompleta: %v (riprovo al riavvio)", trash, err))
	}
	return nil
}

// Head restituisce la generazione corrente (0 = spazio vuoto).
func (s *Store) Head(id string) (int, error) {
	st, err := s.space(id)
	if err != nil {
		return 0, err
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	return st.head, nil
}

// --- Generazioni ---

func (s *Store) genPath(id string, n int) string {
	return filepath.Join(s.spaceDir(id), "generations", strconv.Itoa(n)+".json")
}

// loadGen è l'unico lettore di generazioni: ErrNotFound se il file non c'è,
// errore esplicito se è illeggibile.
func (s *Store) loadGen(id string, n int) (Generation, error) {
	if n <= 0 {
		return Generation{}, i18n.Errorf("generazione %d: %w", n, ErrNotFound)
	}
	var g Generation
	if err := readJSON(s.genPath(id, n), &g); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return Generation{}, i18n.Errorf("generazione %d: %w", n, ErrNotFound)
		}
		return Generation{}, i18n.Errorf("generazione %d illeggibile: %w", n, err)
	}
	return g, nil
}

// manifest restituisce il manifest della generazione n (vuoto se n==0).
func (s *Store) manifest(id string, n int) (Manifest, error) {
	if n == 0 {
		return Manifest{}, nil
	}
	g, err := s.loadGen(id, n)
	if err != nil {
		return nil, err
	}
	return g.Files, nil
}

// genNumbers elenca (in ordine crescente) le generazioni presenti su disco.
func (s *Store) genNumbers(id string) ([]int, error) {
	entries, err := os.ReadDir(filepath.Join(s.spaceDir(id), "generations"))
	if err != nil {
		return nil, err
	}
	var out []int
	for _, e := range entries {
		name, ok := strings.CutSuffix(e.Name(), ".json")
		if !ok {
			continue
		}
		if n, err := strconv.Atoi(name); err == nil && n > 0 {
			out = append(out, n)
		}
	}
	sort.Ints(out)
	return out, nil
}

// Generation carica una generazione completa (manifest incluso).
func (s *Store) Generation(id string, n int) (Generation, error) {
	if _, err := s.space(id); err != nil {
		return Generation{}, err
	}
	return s.loadGen(id, n)
}

// ManifestAt restituisce il manifest della generazione n (o vuoto se n==0).
func (s *Store) ManifestAt(id string, n int) (Manifest, error) {
	if _, err := s.space(id); err != nil {
		return nil, err
	}
	return s.manifest(id, n)
}

// Generations restituisce la storia (senza manifest), dalla più recente.
func (s *Store) Generations(id string, limit int) ([]GenSummary, error) {
	st, err := s.space(id)
	if err != nil {
		return nil, err
	}
	st.mu.Lock()
	head := st.head
	st.mu.Unlock()
	var out []GenSummary
	for n := head; n > 0 && (limit <= 0 || len(out) < limit); n-- {
		g, err := s.loadGen(id, n)
		if err != nil {
			if errors.Is(err, ErrNotFound) {
				continue // generazione potata dal GC
			}
			return nil, err
		}
		out = append(out, g.Summary())
	}
	return out, nil
}

// --- Blob ---
//
// A riposo un blob può essere in due formati: piatto (`<hash>`, storico) o
// gzip (`<hash>.gz`, dai client ≥1.7 che caricano già compresso). L'hash è
// SEMPRE quello del contenuto NON compresso: il protocollo non cambia, cambia
// solo come i byte stanno su disco e in transito.

func (s *Store) blobPath(id, hash string) string {
	return filepath.Join(s.spaceDir(id), "blobs", hash[:2], hash)
}

func (s *Store) blobPathGz(id, hash string) string {
	return s.blobPath(id, hash) + ".gz"
}

// HasBlob controlla la presenza di un blob (in qualunque formato).
func (s *Store) HasBlob(id, hash string) bool {
	if !validHash(hash) {
		return false
	}
	if _, err := os.Stat(s.blobPath(id, hash)); err == nil {
		return true
	}
	_, err := os.Stat(s.blobPathGz(id, hash))
	return err == nil
}

// OpenBlobRaw apre un blob nel formato in cui è salvato: gzipped riporta se i
// byte restituiti sono compressi (size è la dimensione su disco). Così l'API
// può servire il file com'è, senza ricomprimere, ai client che parlano gzip.
func (s *Store) OpenBlobRaw(id, hash string) (f *os.File, size int64, gzipped bool, err error) {
	if _, err := s.space(id); err != nil {
		return nil, 0, false, err
	}
	if !validHash(hash) {
		return nil, 0, false, i18n.Errorf("%w: hash non valido", ErrBadRequest)
	}
	file, err := os.Open(s.blobPath(id, hash))
	if errors.Is(err, os.ErrNotExist) {
		file, err = os.Open(s.blobPathGz(id, hash))
		gzipped = true
	}
	if errors.Is(err, os.ErrNotExist) {
		return nil, 0, false, i18n.Errorf("blob %s: %w", hash[:12], ErrNotFound)
	}
	if err != nil {
		return nil, 0, false, err
	}
	fi, err := file.Stat()
	if err != nil {
		file.Close()
		return nil, 0, false, err
	}
	return file, fi.Size(), gzipped, nil
}

// OpenBlob apre un blob restituendo SEMPRE il contenuto decompresso
// (per usi interni: zip, icona). size è la dimensione su disco, indicativa.
func (s *Store) OpenBlob(id, hash string) (io.ReadCloser, int64, error) {
	f, size, gzipped, err := s.OpenBlobRaw(id, hash)
	if err != nil {
		return nil, 0, err
	}
	if !gzipped {
		return f, size, nil
	}
	zr, err := gzip.NewReader(f)
	if err != nil {
		f.Close()
		return nil, 0, err
	}
	return &gzipBlobReader{zr: zr, f: f}, size, nil
}

type gzipBlobReader struct {
	zr *gzip.Reader
	f  io.Closer
}

func (g *gzipBlobReader) Read(p []byte) (int, error) { return g.zr.Read(p) }
func (g *gzipBlobReader) Close() error {
	g.zr.Close()
	return g.f.Close()
}

// OpenPath apre un file per percorso nella generazione HEAD (nil se assente).
// Comodo per leggere i file di configurazione del mondo (level.dat, ecc.).
func (s *Store) OpenPath(id, path string) (io.ReadCloser, bool, error) {
	fm, ok, err := s.HeadFile(id, path)
	if err != nil || !ok {
		return nil, false, err
	}
	rc, err := s.OpenFile(id, fm)
	return rc, true, err
}

// HeadFile restituisce i metadati di un percorso nella generazione HEAD.
func (s *Store) HeadFile(id, path string) (FileMeta, bool, error) {
	head, err := s.Head(id)
	if err != nil {
		return FileMeta{}, false, err
	}
	m, err := s.manifest(id, head)
	if err != nil {
		return FileMeta{}, false, err
	}
	fm, ok := m[path]
	return fm, ok, nil
}

// OpenFile apre il contenuto COMPLETO di un file di un manifest, assemblando
// i chunk in sequenza se il file è spezzato (per zip, icona e simili).
func (s *Store) OpenFile(id string, fm FileMeta) (io.ReadCloser, error) {
	if len(fm.Chunks) == 0 {
		rc, _, err := s.OpenBlob(id, fm.Hash)
		return rc, err
	}
	return &chunkChain{store: s, id: id, chunks: fm.Chunks}, nil
}

// FileReaderAt è il contenuto di un file con accesso casuale (per leggere
// solo le voci che servono di un jar senza caricarlo in RAM).
type FileReaderAt interface {
	io.ReaderAt
	io.Closer
	Size() int64
}

type osReaderAt struct {
	*os.File
	size   int64
	remove bool
}

func (o *osReaderAt) Size() int64 { return o.size }
func (o *osReaderAt) Close() error {
	err := o.File.Close()
	if o.remove {
		os.Remove(o.File.Name())
	}
	return err
}

// OpenFileAt apre un file di un manifest con accesso casuale. Un blob piatto
// non spezzato si legge direttamente da disco; gli altri (gzip, chunk) vengono
// prima decompressi in un temporaneo, entro maxSize byte.
func (s *Store) OpenFileAt(id string, fm FileMeta, maxSize int64) (FileReaderAt, error) {
	if fm.Size > maxSize {
		return nil, i18n.Errorf("%w: file troppo grande (%d byte)", ErrBadRequest, fm.Size)
	}
	if len(fm.Chunks) == 0 {
		f, size, gzipped, err := s.OpenBlobRaw(id, fm.Hash)
		if err != nil {
			return nil, err
		}
		if !gzipped {
			return &osReaderAt{File: f, size: size}, nil
		}
		f.Close()
	}
	rc, err := s.OpenFile(id, fm)
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	tmp, err := os.CreateTemp("", "minesync-file-*")
	if err != nil {
		return nil, err
	}
	n, err := io.Copy(tmp, io.LimitReader(rc, maxSize+1))
	if err == nil && n > maxSize {
		err = i18n.Errorf("%w: file troppo grande", ErrBadRequest)
	}
	if err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return nil, err
	}
	return &osReaderAt{File: tmp, size: n, remove: true}, nil
}

// chunkChain legge una sequenza di chunk come un unico stream,
// aprendo ogni blob solo quando serve.
type chunkChain struct {
	store  *Store
	id     string
	chunks []Chunk
	cur    io.ReadCloser
}

func (c *chunkChain) Read(p []byte) (int, error) {
	for {
		if c.cur == nil {
			if len(c.chunks) == 0 {
				return 0, io.EOF
			}
			rc, _, err := c.store.OpenBlob(c.id, c.chunks[0].Hash)
			if err != nil {
				return 0, err
			}
			c.cur, c.chunks = rc, c.chunks[1:]
		}
		n, err := c.cur.Read(p)
		if err == io.EOF {
			c.cur.Close()
			c.cur = nil
			if n > 0 {
				return n, nil
			}
			continue
		}
		return n, err
	}
}

func (c *chunkChain) Close() error {
	if c.cur != nil {
		return c.cur.Close()
	}
	return nil
}

// PutBlob scrive un blob verificando che i byte corrispondano all'hash
// dichiarato. Con gzipped=true il corpo arriva compresso: si salva com'è
// (formato .gz) e si verifica l'hash del contenuto decompresso.
// Scrittura atomica e durevole; se il blob esiste già è un no-op.
func (s *Store) PutBlob(id, hash string, r io.Reader, gzipped bool) (int64, error) {
	if _, err := s.space(id); err != nil {
		return 0, err
	}
	if !validHash(hash) {
		return 0, i18n.Errorf("%w: hash non valido", ErrBadRequest)
	}
	if s.HasBlob(id, hash) {
		n, _ := io.Copy(io.Discard, r) // scarta ma consuma la richiesta
		return n, nil
	}
	dst := s.blobPath(id, hash)
	if gzipped {
		dst = s.blobPathGz(id, hash)
	}
	// Mkdir (non MkdirAll): se lo spazio è stato eliminato nel frattempo
	// l'upload fallisce invece di ricrearne la directory.
	if err := os.Mkdir(filepath.Dir(dst), 0o775); err != nil && !errors.Is(err, os.ErrExist) {
		return 0, err
	}
	var n int64
	err := writeAtomic(dst, func(w io.Writer) error {
		h := sha256.New()
		var err error
		if gzipped {
			// su disco vanno i byte compressi; nell'hash quelli originali
			zr, zerr := gzip.NewReader(io.TeeReader(r, w))
			if zerr != nil {
				return i18n.Errorf("%w: gzip non valido: %v", ErrBadRequest, zerr)
			}
			if _, err = io.Copy(h, zr); err == nil {
				err = zr.Close()
			}
			n = -1 // i byte "logici" li sa solo il client; non servono a nessuno qui
		} else {
			n, err = io.Copy(io.MultiWriter(w, h), r)
		}
		if err != nil {
			return err
		}
		if got := hex.EncodeToString(h.Sum(nil)); got != hash {
			return i18n.Errorf("%w: hash non combacia (dichiarato %s, reale %s)", ErrBadRequest, hash[:12], got[:12])
		}
		return nil
	})
	return n, err
}

// PushBlob carica un blob nell'ambito di una sessione di push: la sessione
// deve esistere e il blob deve essere tra quelli del suo manifest. Ogni
// upload rinnova la scadenza della sessione.
func (s *Store) PushBlob(id, pushID, hash string, r io.Reader, gzipped bool) (int64, error) {
	st, err := s.space(id)
	if err != nil {
		return 0, err
	}
	st.mu.Lock()
	ps, ok := st.pushes[pushID]
	if ok && !st.deleted {
		ps.LastActive = time.Now()
	}
	deleted := st.deleted
	st.mu.Unlock()
	if !ok || deleted {
		return 0, i18n.Errorf("push %s: %w", pushID, ErrNotFound)
	}
	if !ps.blobs[hash] {
		return 0, i18n.Errorf("%w: blob %.12s non richiesto da questo push", ErrBadRequest, hash)
	}
	n, err := s.PutBlob(id, hash, r, gzipped)
	st.mu.Lock()
	ps.LastActive = time.Now()
	st.mu.Unlock()
	return n, err
}

func validHash(h string) bool {
	if len(h) != 64 {
		return false
	}
	_, err := hex.DecodeString(h)
	return err == nil
}

// --- Push (begin → upload blob → commit) ---

// PushOptions descrive un push proposto.
type PushOptions struct {
	Author  string
	Message string
	Parent  int
	Files   Manifest
	Corrupt []string // region file che il client ha rilevato danneggiati

	// LockSession: sessione del lock che il chiamante tiene. Obbligatoria
	// salvo NoLock (che l'API concede solo agli admin).
	LockSession string
	NoLock      bool
	// AllowMassDelete disattiva il blocco dei push che svuotano HEAD (admin).
	AllowMassDelete bool
}

// BeginPush valida il manifest proposto e apre una sessione di push.
// Restituisce l'id della sessione e l'elenco degli hash mancanti.
func (s *Store) BeginPush(id string, o PushOptions) (string, []string, error) {
	st, err := s.space(id)
	if err != nil {
		return "", nil, err
	}
	if err := validateManifest(o.Files); err != nil {
		return "", nil, err
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	if !o.NoLock {
		if err := st.checkLockLocked(o.Author, o.LockSession); err != nil {
			return "", nil, err
		}
	}
	if o.Parent != st.head {
		return "", nil, i18n.Errorf("%w: parent %d ma HEAD è %d (qualcuno ha pushato prima di te: fai pull)", ErrConflict, o.Parent, st.head)
	}
	if !o.AllowMassDelete {
		prev, err := s.manifest(id, st.head)
		if err != nil {
			return "", nil, err
		}
		if len(prev) >= massDeleteMinFiles {
			removed := 0
			for p := range prev {
				if _, ok := o.Files[p]; !ok {
					removed++
				}
			}
			if float64(removed) > massDeleteRatio*float64(len(prev)) {
				return "", nil, &MassDeleteError{Removed: removed, Total: len(prev)}
			}
		}
	}

	now := time.Now()
	st.expirePushesLocked(now)
	// tetto alle sessioni aperte per utente: si sacrifica la più vecchia
	var mine []*pushSession
	for _, ps := range st.pushes {
		if ps.Author == o.Author {
			mine = append(mine, ps)
		}
	}
	if len(mine) >= maxPushesPerUser {
		sort.Slice(mine, func(i, j int) bool { return mine[i].LastActive.Before(mine[j].LastActive) })
		for _, ps := range mine[:len(mine)-maxPushesPerUser+1] {
			delete(st.pushes, ps.ID)
		}
	}

	ps := &pushSession{ID: randomID(), Author: o.Author, Message: o.Message,
		Parent: o.Parent, Files: o.Files, Corrupt: o.Corrupt, Created: now, LastActive: now,
		blobs: map[string]bool{}}
	if !o.NoLock {
		ps.LockSession = o.LockSession
	}
	var missing []string
	for _, fm := range o.Files {
		for _, h := range blobsOf(fm) {
			if ps.blobs[h] {
				continue
			}
			ps.blobs[h] = true
			if !s.HasBlob(id, h) {
				missing = append(missing, h)
			}
		}
	}
	st.pushes[ps.ID] = ps
	sort.Strings(missing)
	return ps.ID, missing, nil
}

func validateManifest(files Manifest) error {
	for p, fm := range files {
		if !validPath(p) {
			return i18n.Errorf("%w: percorso non valido %q", ErrBadRequest, p)
		}
		if !validHash(fm.Hash) {
			return i18n.Errorf("%w: hash non valido per %q", ErrBadRequest, p)
		}
		var sum int64
		for _, c := range fm.Chunks {
			if !validHash(c.Hash) || c.Size <= 0 {
				return i18n.Errorf("%w: chunk non valido per %q", ErrBadRequest, p)
			}
			sum += c.Size
		}
		if len(fm.Chunks) > 0 && sum != fm.Size {
			return i18n.Errorf("%w: chunk di %q non coprono il file (%d ≠ %d)", ErrBadRequest, p, sum, fm.Size)
		}
	}
	return nil
}

// checkLockLocked verifica che owner tenga il lock con quella sessione.
func (st *spaceState) checkLockLocked(owner, session string) error {
	if st.lock == nil {
		return &LockedError{}
	}
	if st.lock.Owner != owner || session == "" || st.lock.Session != session {
		return &LockedError{Holder: st.lock.Redacted(), IsStale: st.lock.Stale(time.Now().UTC())}
	}
	return nil
}

// expirePushesLocked chiude le sessioni inattive da più di pushSessionTTL.
func (st *spaceState) expirePushesLocked(now time.Time) {
	for k, ps := range st.pushes {
		if now.Sub(ps.LastActive) > pushSessionTTL {
			delete(st.pushes, k)
		}
	}
}

// blobsOf elenca i blob che materializzano un file: i chunk se è spezzato,
// l'hash intero altrimenti.
func blobsOf(fm FileMeta) []string {
	if len(fm.Chunks) == 0 {
		return []string{fm.Hash}
	}
	out := make([]string, len(fm.Chunks))
	for i, c := range fm.Chunks {
		out[i] = c.Hash
	}
	return out
}

// checkBlobs verifica che tutti i blob di un manifest siano presenti.
func (s *Store) checkBlobs(id string, files Manifest, hint string) error {
	for p, fm := range files {
		for _, h := range blobsOf(fm) {
			if !s.HasBlob(id, h) {
				return i18n.Errorf("%w: blob mancante per %q (%.12s)%s", ErrBadRequest, p, h, hint)
			}
		}
	}
	return nil
}

// CommitPush finalizza una sessione: verifica lock e blob, CAS su HEAD,
// scrive la generazione. Un commit già riuscito con lo stesso pushID
// restituisce di nuovo lo stesso risultato (idempotenza: la risposta del
// primo tentativo può essersi persa per strada).
// replayed=true segnala che il commit era già avvenuto (niente nuovo evento).
func (s *Store) CommitPush(id, pushID string) (gen GenSummary, replayed bool, err error) {
	st, err := s.space(id)
	if err != nil {
		return GenSummary{}, false, err
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	ps, ok := st.pushes[pushID]
	if !ok {
		for _, c := range st.committed {
			if c.id == pushID {
				return c.gen, true, nil
			}
		}
		return GenSummary{}, false, i18n.Errorf("push %s: %w", pushID, ErrNotFound)
	}
	if ps.LockSession != "" {
		if err := st.checkLockLocked(ps.Author, ps.LockSession); err != nil {
			delete(st.pushes, pushID)
			return GenSummary{}, false, err
		}
	}
	if ps.Parent != st.head {
		delete(st.pushes, pushID)
		return GenSummary{}, false, i18n.Errorf("%w: HEAD avanzato durante il push", ErrConflict)
	}
	if err := s.checkBlobs(id, ps.Files, ""); err != nil {
		return GenSummary{}, false, err
	}
	gen, err = s.newGenLocked(id, st, Generation{
		Author: ps.Author, Message: ps.Message, Files: ps.Files, Corrupt: ps.Corrupt,
	})
	if err != nil {
		return GenSummary{}, false, err
	}
	delete(st.pushes, pushID)
	now := time.Now()
	st.committed = append(st.committed, committedPush{id: pushID, gen: gen, at: now})
	for len(st.committed) > 0 && (len(st.committed) > committedKeep || now.Sub(st.committed[0].at) > committedTTL) {
		st.committed = st.committed[1:]
	}
	return gen, false, nil
}

// CheckBlobs verifica che tutti i blob di un manifest siano presenti
// (ErrConflict altrimenti): per l'export, prima di mandare un solo byte.
func (s *Store) CheckBlobs(id string, files Manifest) error {
	if _, err := s.space(id); err != nil {
		return err
	}
	if err := s.checkBlobs(id, files, ""); err != nil {
		return i18n.Errorf("%w: %v", ErrConflict, err)
	}
	return nil
}

// newGenLocked scrive la generazione successiva a HEAD con il contenuto di g
// (numero, genitore, data e statistiche li calcola lei), avanza HEAD e
// applica la retention automatica. Unico punto in cui nasce una generazione.
func (s *Store) newGenLocked(id string, st *spaceState, g Generation) (GenSummary, error) {
	prev, err := s.manifest(id, st.head)
	if err != nil {
		return GenSummary{}, err
	}
	g.N, g.Parent, g.TS = st.head+1, st.head, time.Now().UTC()
	g.Stats = diffStats(prev, g.Files)
	if err := writeJSON(s.genPath(id, g.N), g); err != nil {
		return GenSummary{}, err
	}
	if err := writeFileAtomic(filepath.Join(s.spaceDir(id), "HEAD"), []byte(strconv.Itoa(g.N))); err != nil {
		return GenSummary{}, err
	}
	st.head = g.N
	st.genTS[g.N] = g.TS
	// retention: rilegge tutti i manifest, quindi al massimo una volta l'ora
	if now := time.Now(); s.KeepLast > 0 && now.Sub(st.lastRetention) > retentionEvery {
		st.lastRetention = now
		if _, err := s.retentionLocked(id, st, now); err != nil {
			log.Print(i18n.Lf("store: retention di %s saltata: %v", id, err))
		}
	}
	return g.Summary(), nil
}

// liveLockLocked rifiuta le operazioni distruttive mentre qualcuno gioca.
func (st *spaceState) liveLockLocked() error {
	if st.lock != nil && !st.lock.Stale(time.Now().UTC()) {
		return &LockedError{Holder: st.lock.Redacted()}
	}
	return nil
}

// Restore crea una nuova generazione con il contenuto di una generazione
// passata. Rifiutato se qualcuno sta giocando.
func (s *Store) Restore(id string, n int, author string) (GenSummary, error) {
	st, err := s.space(id)
	if err != nil {
		return GenSummary{}, err
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	if err := st.liveLockLocked(); err != nil {
		return GenSummary{}, err
	}
	src, err := s.loadGen(id, n)
	if err != nil {
		return GenSummary{}, err
	}
	if err := s.checkBlobs(id, src.Files, " (generazione potata?)"); err != nil {
		return GenSummary{}, err
	}
	return s.newGenLocked(id, st, Generation{
		Author: author, Message: fmt.Sprintf("restore della generazione %d", n),
		Restore: n, Files: src.Files,
	})
}

// RestoreFile crea una nuova generazione uguale a HEAD ma con un singolo file
// riportato alla versione di fromGen: il recupero chirurgico di un region file
// danneggiato senza toccare il resto del mondo. Con fromGen<=0 sceglie da sé
// la generazione integra più recente in cui quel file era sano.
func (s *Store) RestoreFile(id, path string, fromGen int, author string) (GenSummary, error) {
	st, err := s.space(id)
	if err != nil {
		return GenSummary{}, err
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	if err := st.liveLockLocked(); err != nil {
		return GenSummary{}, err
	}
	head, err := s.manifest(id, st.head)
	if err != nil {
		return GenSummary{}, err
	}
	cur, ok := head[path]
	if !ok {
		return GenSummary{}, i18n.Errorf("%w: %q non è in HEAD", ErrBadRequest, path)
	}
	if fromGen <= 0 {
		if fromGen = s.lastCleanGen(id, st.head, path, cur.Hash); fromGen == 0 {
			return GenSummary{}, i18n.Errorf("%w: nessuna versione integra di %q nella storia", ErrNotFound, path)
		}
	}
	src, err := s.manifest(id, fromGen)
	if err != nil {
		return GenSummary{}, err
	}
	fm, ok := src[path]
	if !ok {
		return GenSummary{}, i18n.Errorf("%w: %q non esiste nella generazione %d", ErrBadRequest, path, fromGen)
	}
	if err := s.checkBlobs(id, Manifest{path: fm}, " (versione potata?)"); err != nil {
		return GenSummary{}, err
	}
	next := make(Manifest, len(head))
	for p, m := range head {
		next[p] = m
	}
	next[path] = fm
	return s.newGenLocked(id, st, Generation{
		Author: author, Message: fmt.Sprintf("ripristino di %s dalla generazione %d", path, fromGen),
		Files: next,
	})
}

// lastCleanGen trova la generazione più recente (sotto head) in cui path
// esiste, ha un contenuto diverso da curHash e non è tra i corrotti.
func (s *Store) lastCleanGen(id string, head int, path, curHash string) int {
	for n := head - 1; n > 0; n-- {
		g, err := s.loadGen(id, n)
		if err != nil {
			continue // potata dal GC
		}
		fm, ok := g.Files[path]
		if !ok || fm.Hash == curHash {
			continue
		}
		flagged := false
		for _, c := range g.Corrupt {
			if c == path {
				flagged = true
				break
			}
		}
		if !flagged && s.checkBlobs(id, Manifest{path: fm}, "") == nil {
			return n
		}
	}
	return 0
}

func diffStats(prev, next Manifest) Stats {
	st := Stats{Files: len(next)}
	for p, fm := range next {
		st.Bytes += fm.Size
		old, ok := prev[p]
		switch {
		case !ok:
			st.Added++
		case old.Hash != fm.Hash:
			st.Changed++
		}
	}
	for p := range prev {
		if _, ok := next[p]; !ok {
			st.Removed++
		}
	}
	return st
}

// validPath rifiuta percorsi assoluti, traversal e separatori Windows.
func validPath(p string) bool {
	if p == "" || strings.HasPrefix(p, "/") || strings.Contains(p, "\\") {
		return false
	}
	for _, seg := range strings.Split(p, "/") {
		if seg == "" || seg == "." || seg == ".." {
			return false
		}
	}
	return true
}

// genTime restituisce il timestamp di una generazione (con cache).
func (s *Store) genTime(id string, st *spaceState, n int) (time.Time, error) {
	if ts, ok := st.genTS[n]; ok {
		return ts, nil
	}
	b, err := os.ReadFile(s.genPath(id, n))
	if err != nil {
		return time.Time{}, i18n.Errorf("generazione %d illeggibile: %w", n, err)
	}
	var g struct {
		TS time.Time `json:"ts"`
	}
	if err := json.Unmarshal(b, &g); err != nil {
		return time.Time{}, i18n.Errorf("generazione %d illeggibile: %w", n, err)
	}
	st.genTS[n] = g.TS
	return g.TS, nil
}

func randomID() string {
	b := make([]byte, 8)
	if _, err := cryptoRead(b); err != nil {
		return strconv.FormatInt(time.Now().UnixNano(), 36)
	}
	return hex.EncodeToString(b)
}
