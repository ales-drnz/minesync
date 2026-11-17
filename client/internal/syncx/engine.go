// Package syncx: engine di sincronizzazione HTTP (pull = checkout, push = commit).
package syncx

import (
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"minesync/client/internal/api"
)

const (
	workers  = 8 // trasferimenti in primo piano (pull, push finale e manuale)
	retries  = 2
	bufSize  = 1 << 20
	speedWin = 3 * time.Second
)

// Progress è lo stato corrente di un trasferimento, per la UI.
type Progress struct {
	Phase      string // "scan", "pull", "push", "commit", "done"
	TotalFiles int
	DoneFiles  int
	TotalBytes int64
	DoneBytes  int64
	Speed      float64  // byte/s (finestra mobile)
	Active     []string // file in volo
	Current    string   // ultimo file toccato
}

// Reporter riceve aggiornamenti di progresso (può essere nil).
type Reporter func(Progress)

// Engine esegue pull e push per uno spazio.
type Engine struct {
	Client    *api.Client
	SpaceID   string
	LocalPath string
	CachePath string
	Matcher   *Matcher
	Report    Reporter

	// AllowMassDelete: conferma esplicita per un push che cancella quasi
	// tutto (vedi MassDeleteError). Di default no.
	AllowMassDelete bool
	// AllowStaleBase: conferma esplicita per un push che non discende da
	// HEAD (vedi StaleBaseError). Di default no.
	AllowStaleBase bool
	// DiscardLocal: il pull scarta le modifiche locali non pushate invece di
	// rifiutarsi con DirtyLocalError (dopo averne fatto un backup in
	// BackupRoot). Di default no.
	DiscardLocal bool
	// LockSession: sessione del lock tenuto dal chiamante; il push la passa
	// all'hub, che lega il push a quel lock.
	LockSession string
	// Warn riceve gli avvisi non bloccanti (già tradotti): file saltati
	// perché illeggibili o con un nome non ammesso, permessi non applicabili
	// sul filesystem, ecc. Può essere nil.
	Warn func(msg string)

	// opMu serializza le operazioni pubbliche (Pull, Push, Snapshot,
	// PushSnapshot…): l'engine ha stato interno (meta, contatori di
	// progresso) e la sessione può avere un upload in background.
	opMu sync.Mutex

	chmodWarn sync.Once    // avviso "permessi non supportati" una volta sola
	upBps     atomic.Int64 // velocità di upload misurata (byte/s, 0 = ignota)

	mu       sync.Mutex
	active   map[string]struct{}
	done     int
	total    int
	doneB    int64
	totalB   int64
	phase    string
	lastRep  time.Time
	winStart time.Time
	winBytes int64
	winDone  bool
	speed    float64

	// meta della cache locale (cartella di provenienza e generazione di base)
	meta CacheMeta

	// delta sync: indice dei chunk disponibili nei file locali (costruito
	// dalla scansione a inizio Pull, sola lettura durante i download)
	localIdx map[string]localChunk
}

// localChunk indica dove trovare un chunk dentro un file locale esistente.
type localChunk struct {
	rel       string
	off, size int64
}

func (e *Engine) report(force bool) {
	if e.Report == nil {
		return
	}
	e.mu.Lock()
	now := time.Now()
	if !force && now.Sub(e.lastRep) < 80*time.Millisecond {
		e.mu.Unlock()
		return
	}
	e.lastRep = now
	el := now.Sub(e.winStart)
	if el > speedWin {
		e.speed = float64(e.winBytes) / el.Seconds()
		e.winStart, e.winBytes = now, 0
		e.winDone = true
	} else if !e.winDone && el > 300*time.Millisecond {
		// stima iniziale, prima che la finestra completa maturi
		e.speed = float64(e.winBytes) / el.Seconds()
	}
	act := make([]string, 0, len(e.active))
	for f := range e.active {
		act = append(act, f)
	}
	sort.Strings(act)
	cur := ""
	if len(act) > 0 {
		cur = act[0]
	}
	p := Progress{Phase: e.phase, TotalFiles: e.total, DoneFiles: e.done,
		TotalBytes: e.totalB, DoneBytes: atomic.LoadInt64(&e.doneB),
		Speed: e.speed, Active: act, Current: cur}
	e.mu.Unlock()
	e.Report(p)
}

func (e *Engine) setPhase(ph string) {
	e.mu.Lock()
	e.phase = ph
	e.winStart, e.winBytes = time.Now(), 0
	e.winDone = false
	e.speed = 0
	e.mu.Unlock()
	e.report(true)
}

// startTransfer azzera i contatori per una nuova fase di trasferimento.
func (e *Engine) startTransfer(phase string, files int, bytes int64) {
	e.mu.Lock()
	e.total, e.done = files, 0
	e.totalB = bytes
	atomic.StoreInt64(&e.doneB, 0)
	e.mu.Unlock()
	e.setPhase(phase)
}

func (e *Engine) addBytes(n int64) {
	atomic.AddInt64(&e.doneB, n)
	e.mu.Lock()
	e.winBytes += n
	e.mu.Unlock()
	e.report(false)
}

func (e *Engine) fileStart(rel string) {
	e.mu.Lock()
	e.active[rel] = struct{}{}
	e.mu.Unlock()
	e.report(false)
}

func (e *Engine) fileDone(rel string) {
	e.mu.Lock()
	delete(e.active, rel)
	e.done++
	e.mu.Unlock()
	e.report(false)
}

// warn inoltra un avviso al chiamante (se interessato).
func (e *Engine) warn(msg string) {
	if e.Warn != nil {
		e.Warn(msg)
	}
}

// ScanLocal produce manifest e cache correnti della cartella locale. I file
// illeggibili non compaiono nel manifest (vedi ScanResult.Unreadable): chi
// pusha conserva per loro la versione dell'hub.
func (e *Engine) ScanLocal() (api.Manifest, Cache, error) {
	res, err := e.scanLocal(scanOpts{})
	return res.Manifest, res.Cache, err
}

// scanLocal è ScanLocal con le opzioni della scansione (snapshot).
func (e *Engine) scanLocal(opt scanOpts) (ScanResult, error) {
	e.mu.Lock()
	e.active = map[string]struct{}{}
	e.mu.Unlock()
	e.setPhase("scan")
	prior, meta := LoadCacheMeta(e.CachePath, e.LocalPath)
	if v := e.upBps.Load(); v > 0 {
		meta.UpBps = v // misura più recente di quella su disco
	}
	e.meta = meta
	n := 0
	res, err := scanTree(e.LocalPath, e.Matcher, prior, func(rel string, hashed bool) {
		n++
		if hashed {
			e.mu.Lock()
			e.done = n
			e.mu.Unlock()
			e.report(false)
		}
	}, opt)
	if err != nil {
		return res, err
	}
	reportScanIssues(res, e.warn)
	return res, nil
}

// saveMeta registra la generazione di base del locale (numero e digest)
// insieme alla cache. Gli altri metadati (velocità di upload misurata) si
// conservano.
func (e *Engine) saveMeta(cache Cache, gen int, digest string) error {
	e.meta.Root, e.meta.Gen, e.meta.GenDigest = e.LocalPath, gen, digest
	if gen != genPulling {
		e.meta.PrevGen = 0
	}
	return SaveCacheMeta(e.CachePath, cache, e.meta)
}

func manifestsEqual(a, b api.Manifest) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		// anche il bit di esecuzione fa parte del contenuto: se cambia solo
		// quello e non lo si guarda, il push non parte mai e chi scarica si
		// ritrova start.sh o il java incluso non eseguibili
		if w, ok := b[k]; !ok || w.Hash != v.Hash || w.Exec != v.Exec {
			return false
		}
	}
	return true
}
