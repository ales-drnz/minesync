package store

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"minesync/server/internal/i18n"
)

// --- Errori con codice per l'API ---

// SpaceGoneError: lo spazio non esiste più (eliminato). Per l'heartbeat:
// il client smette di riprovare (404, code "space_gone").
type SpaceGoneError struct{ ID string }

func (e *SpaceGoneError) Localize(l i18n.Lang) string {
	return i18n.Tf(l, "lo spazio %s non esiste più (eliminato dall'hub): la sessione è finita", e.ID)
}
func (e *SpaceGoneError) Error() string { return e.Localize(i18n.Default()) }
func (e *SpaceGoneError) Unwrap() error { return ErrNotFound }

// StaleBaseError: il push dichiara una generazione genitore che sull'hub non
// esiste più o ha un contenuto diverso (hub ripristinato da backup, spazio
// ricreato): il numero coincide ma la storia no (409, code "stale_base").
type StaleBaseError struct{ Parent int }

func (e *StaleBaseError) Localize(l i18n.Lang) string {
	return i18n.Tf(l, "la generazione %d da cui parte il tuo push non è quella dell'hub (hub ripristinato o spazio ricreato): scarica prima la versione dell'hub", e.Parent)
}
func (e *StaleBaseError) Error() string { return e.Localize(i18n.Default()) }
func (e *StaleBaseError) Unwrap() error { return ErrConflict }

// BadPathError: un percorso del manifest non è valido o non è
// rappresentabile su Windows (400, code "bad_path"). Dup, se valorizzato, è il
// percorso con cui Path coincide ignorando maiuscole e minuscole.
type BadPathError struct {
	Path string
	Dup  string
}

func (e *BadPathError) Localize(l i18n.Lang) string {
	if e.Dup != "" {
		return i18n.Tf(l, "percorso %q duplicato di %q a meno di maiuscole/minuscole: su Windows sarebbero lo stesso file", e.Path, e.Dup)
	}
	return i18n.Tf(l, "percorso non valido (o non valido su Windows): %q", e.Path)
}
func (e *BadPathError) Error() string { return e.Localize(i18n.Default()) }
func (e *BadPathError) Unwrap() error { return ErrBadRequest }

// DiskFullError: il volume dei dati dell'hub è sotto la soglia minima di
// spazio libero (507, code "disk_full").
type DiskFullError struct{ Free, Need uint64 }

func (e *DiskFullError) Localize(l i18n.Lang) string {
	return i18n.Tf(l, "l'hub ha il disco pieno: %s liberi, ne servono almeno %s. Avvisa chi gestisce l'hub", FormatBytes(e.Free), FormatBytes(e.Need))
}
func (e *DiskFullError) Error() string { return e.Localize(i18n.Default()) }

// FormatBytes rende una quantità di byte leggibile ("1.5 GiB").
func FormatBytes(b uint64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := uint64(unit), 0
	for n := b / unit; n >= unit && exp < 4; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(b)/float64(div), "KMGTP"[exp])
}

// --- Spazio su disco ---

const (
	minFreeFloor = 1 << 30 // soglia minima assoluta: 1 GiB
	minFreeRatio = 0.02    // o il 2% del volume, se maggiore
)

// DiskSpace restituisce lo spazio libero (per chi non è root) e totale del
// volume dei dati.
func (s *Store) DiskSpace() (free, total uint64, err error) {
	return s.statfs(s.root)
}

// SetDiskStat sostituisce la misura del volume (per i test degli altri
// pacchetti: simulare un disco pieno).
func (s *Store) SetDiskStat(f func(path string) (free, total uint64, err error)) { s.statfs = f }

// MinFreeBytes è la soglia sotto cui l'hub rifiuta le scritture: MinFree se
// impostato, altrimenti max(1 GiB, 2% del volume).
func (s *Store) MinFreeBytes(total uint64) uint64 {
	if s.MinFree > 0 {
		return s.MinFree
	}
	return max(minFreeFloor, uint64(float64(total)*minFreeRatio))
}

// checkDisk rifiuta una scrittura se il volume è sotto la soglia. Se lo
// spazio non si riesce a misurare non blocca niente.
func (s *Store) checkDisk() error {
	if !s.DiskGuard {
		return nil
	}
	free, total, err := s.statfs(s.root)
	if err != nil || total == 0 {
		return nil
	}
	if need := s.MinFreeBytes(total); free < need {
		return &DiskFullError{Free: free, Need: need}
	}
	return nil
}

// ParseBytes legge una dimensione come "5GiB", "500MB", "1073741824".
func ParseBytes(v string) (uint64, error) {
	v = strings.TrimSpace(v)
	i := len(v)
	for i > 0 && (v[i-1] < '0' || v[i-1] > '9') {
		i--
	}
	var n float64
	if _, err := fmt.Sscanf(v[:i], "%g", &n); err != nil || n < 0 {
		return 0, i18n.Errorf("dimensione non valida: %q", v)
	}
	mult := map[string]float64{
		"": 1, "b": 1,
		"k": 1 << 10, "kb": 1e3, "kib": 1 << 10,
		"m": 1 << 20, "mb": 1e6, "mib": 1 << 20,
		"g": 1 << 30, "gb": 1e9, "gib": 1 << 30,
		"t": 1 << 40, "tb": 1e12, "tib": 1 << 40,
	}[strings.ToLower(strings.TrimSpace(v[i:]))]
	if mult == 0 {
		return 0, i18n.Errorf("unità non valida: %q", v)
	}
	return uint64(n * mult), nil
}

// --- Identità delle generazioni (digest) ---

// canonicalFiles è l'UNICA codifica canonica di un manifest: JSON compatto,
// chiavi ordinate (encoding/json ordina le mappe), senza escape HTML, senza
// newline finale. Un manifest nil vale come vuoto.
func canonicalFiles(files Manifest) []byte {
	if files == nil {
		files = Manifest{}
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(files) // map[string]struct di stringhe e numeri: non fallisce
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n"))
}

// ManifestDigest è l'identità del contenuto di una generazione: SHA-256 in
// esadecimale minuscolo della codifica canonica del manifest. Due generazioni
// con lo stesso numero ma storie diverse (hub ripristinato, spazio ricreato)
// hanno digest diversi.
func ManifestDigest(files Manifest) string {
	h := sha256.Sum256(canonicalFiles(files))
	return hex.EncodeToString(h[:])
}

// digestCache ricorda il digest delle generazioni vecchie (scritte senza)
// per percorso, finché il file non cambia.
type digestCache struct {
	mu sync.Mutex
	m  map[string]digestEntry
}

type digestEntry struct {
	mod    time.Time
	size   int64
	digest string
}

func (c *digestCache) get(path string, fi os.FileInfo, files Manifest) string {
	c.mu.Lock()
	e, ok := c.m[path]
	c.mu.Unlock()
	if ok && e.size == fi.Size() && e.mod.Equal(fi.ModTime()) {
		return e.digest
	}
	d := ManifestDigest(files)
	c.mu.Lock()
	if c.m == nil {
		c.m = map[string]digestEntry{}
	}
	c.m[path] = digestEntry{mod: fi.ModTime(), size: fi.Size(), digest: d}
	c.mu.Unlock()
	return d
}

// --- Percorsi validi su ogni sistema ---

// validPath rifiuta percorsi assoluti, traversal, separatori Windows e nomi
// che Windows non sa rappresentare: un mondo deve potersi scaricare su
// qualunque PC del gruppo.
func validPath(p string) bool {
	if p == "" || strings.HasPrefix(p, "/") || strings.Contains(p, "\\") {
		return false
	}
	for _, seg := range strings.Split(p, "/") {
		if seg == "" || seg == "." || seg == ".." || !windowsSafeName(seg) {
			return false
		}
	}
	return true
}

// windowsSafeName: niente caratteri <>:"/\|?* né di controllo, niente nomi
// riservati (CON, PRN, AUX, NUL, COM1-9, LPT1-9, anche con estensione,
// maiuscole o minuscole), niente punto o spazio finale.
func windowsSafeName(seg string) bool {
	for _, r := range seg {
		if r < 0x20 || strings.ContainsRune(`<>:"/\|?*`, r) {
			return false
		}
	}
	if strings.HasSuffix(seg, ".") || strings.HasSuffix(seg, " ") {
		return false
	}
	base, _, _ := strings.Cut(seg, ".")
	switch b := strings.ToUpper(base); b {
	case "CON", "PRN", "AUX", "NUL":
		return false
	default:
		if len(b) == 4 && (strings.HasPrefix(b, "COM") || strings.HasPrefix(b, "LPT")) && b[3] >= '1' && b[3] <= '9' {
			return false
		}
	}
	return true
}

// checkPaths verifica tutti i percorsi in ordine: il primo non valido, o il
// primo che ne duplica uno precedente ignorando maiuscole e minuscole, dà
// BadPathError.
func checkPaths(files Manifest) error {
	paths := make([]string, 0, len(files))
	for p := range files {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	seen := make(map[string]string, len(paths))
	for _, p := range paths {
		if !validPath(p) {
			return &BadPathError{Path: p}
		}
		k := strings.ToLower(p)
		if first, dup := seen[k]; dup {
			return &BadPathError{Path: p, Dup: first}
		}
		seen[k] = p
	}
	return nil
}
