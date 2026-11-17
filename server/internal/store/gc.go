package store

import (
	"log"
	"maps"
	"os"
	"path/filepath"
	"strings"
	"time"

	"minesync/server/internal/i18n"
)

// GCResult riassume una passata di pulizia.
type GCResult struct {
	GenerationsPruned int   `json:"generationsPruned"`
	BlobsDeleted      int   `json:"blobsDeleted"`
	BytesFreed        int64 `json:"bytesFreed"`
	GenerationsKept   int   `json:"generationsKept"`
}

const (
	retentionMinAge = 24 * time.Hour // la retention automatica non tocca le più giovani
	retentionDays   = 7              // e tiene almeno una generazione per giorno
	tmpMaxAge       = 24 * time.Hour // temporanei orfani (crash a metà scrittura)
	retentionEvery  = time.Hour      // la retention automatica gira al più ogni ora
	sweepBatch      = 256            // blob eliminati per ogni presa del mutex
)

// La pulizia (retention automatica, GC dell'admin, eliminazione di una
// generazione) è costosa: rilegge tutti i manifest e percorre tutti i blob.
// Per non fermare heartbeat, commit e DNS si fa quasi tutta FUORI dal mutex
// dello spazio, con uno schema "marca e ricontrolla":
//
//  1. sotto il mutex (veloce): si prende lo slot di pulizia dello spazio
//     (st.gc, uno alla volta) e si fotografa HEAD;
//  2. fuori: si leggono tutte le generazioni e si calcola l'insieme dei blob
//     referenziati (se una sola è illeggibile ci si ferma senza toccare
//     niente: i suoi blob sembrerebbero orfani);
//  3. sotto il mutex: si eliminano i file delle generazioni scelte;
//  4. fuori: si percorre la cartella dei blob e si raccolgono i candidati;
//  5. sotto il mutex, a lotti: ogni candidato si RICONTROLLA contro ciò che
//     è cambiato nel frattempo — i blob delle generazioni scritte durante la
//     pulizia (newGenLocked li annota in st.gc.extra) e quelli dei push
//     aperti — e solo allora si elimina.
//
// Qualunque nuova referenza a un blob nasce sotto il mutex (BeginPush,
// newGenLocked), quindi il ricontrollo del punto 5 la vede sempre.

// gcRun è una pulizia in corso su uno spazio.
type gcRun struct {
	extra map[string]bool // blob delle generazioni scritte durante la pulizia
}

var errGCBusy = i18n.Errorf("%w: pulizia già in corso su questo spazio, riprova tra poco", ErrConflict)

// startGCLocked prende lo slot di pulizia (il chiamante ha verificato che
// sia libero).
func (st *spaceState) startGCLocked() *gcRun {
	st.gc = &gcRun{extra: map[string]bool{}}
	return st.gc
}

// endGC libera lo slot di pulizia.
func (st *spaceState) endGC(run *gcRun) {
	st.mu.Lock()
	if st.gc == run {
		st.gc = nil
	}
	st.mu.Unlock()
}

// acquireGC prende lo slot di pulizia: errGCBusy se un'altra è in corso.
// check, se non nil, gira sotto il mutex prima di prenderlo (head = HEAD).
func (s *Store) acquireGC(id string, check func(st *spaceState) error) (*spaceState, *gcRun, int, error) {
	st, err := s.space(id)
	if err != nil {
		return nil, nil, 0, err
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	if st.deleted {
		return nil, nil, 0, i18n.Errorf("space %q: %w", id, ErrNotFound)
	}
	if check != nil {
		if err := check(st); err != nil {
			return nil, nil, 0, err
		}
	}
	if st.gc != nil {
		return nil, nil, 0, errGCBusy
	}
	return st, st.startGCLocked(), st.head, nil
}

// GC pota le generazioni oltre keepLast ed elimina i blob orfani
// (operazione esplicita dell'admin: niente protezioni a tempo).
func (s *Store) GC(id string, keepLast int) (GCResult, error) {
	if keepLast < 1 {
		return GCResult{}, i18n.Errorf("%w: keep deve essere ≥ 1", ErrBadRequest)
	}
	st, run, head, err := s.acquireGC(id, nil)
	if err != nil {
		return GCResult{}, err
	}
	defer st.endGC(run)
	ns, err := s.genNumbers(id)
	if err != nil {
		return GCResult{}, err
	}
	cutoff := head - keepLast + 1
	var del []int
	for _, n := range ns {
		if n < cutoff {
			del = append(del, n)
		}
	}
	return s.prune(id, st, run, ns, del)
}

// DeleteGeneration elimina una singola generazione (mai HEAD) e i blob
// che restano orfani.
func (s *Store) DeleteGeneration(id string, n int) error {
	st, run, _, err := s.acquireGC(id, func(st *spaceState) error {
		if n == st.head {
			return i18n.Errorf("%w: non puoi eliminare la versione corrente (HEAD)", ErrBadRequest)
		}
		if _, err := os.Stat(s.genPath(id, n)); err != nil {
			return i18n.Errorf("generazione %d: %w", n, ErrNotFound)
		}
		return nil
	})
	if err != nil {
		return err
	}
	defer st.endGC(run)
	ns, err := s.genNumbers(id)
	if err != nil {
		return err
	}
	_, err = s.prune(id, st, run, ns, []int{n})
	return err
}

// RunRetention esegue subito la retention automatica di uno spazio (lo
// slot di pulizia deve essere libero).
func (s *Store) RunRetention(id string, now time.Time) (GCResult, error) {
	st, run, _, err := s.acquireGC(id, nil)
	if err != nil {
		return GCResult{}, err
	}
	return s.retention(id, st, run, now)
}

// retention è la potatura automatica dopo le nuove generazioni (gira in
// background, con lo slot run già preso: lo libera lei).
// Conserva sempre: le ultime KeepLast, quelle più giovani di 24 ore e la più
// recente di ciascuno degli ultimi 7 giorni di calendario. Così una raffica
// di push (anche vuoti) non può cancellare la storia.
func (s *Store) retention(id string, st *spaceState, run *gcRun, now time.Time) (GCResult, error) {
	defer st.endGC(run)
	st.mu.Lock()
	head := st.head
	cached := maps.Clone(st.genTS)
	st.mu.Unlock()

	ns, err := s.genNumbers(id)
	if err != nil || len(ns) <= s.KeepLast {
		return GCResult{}, err
	}
	keep := map[int]bool{head: true}
	for _, n := range ns[len(ns)-s.KeepLast:] {
		keep[n] = true
	}
	today := now.In(time.Local)
	firstDay := time.Date(today.Year(), today.Month(), today.Day()-(retentionDays-1), 0, 0, 0, 0, time.Local)
	dayRep := map[string]int{}
	fresh := map[int]time.Time{}
	for _, n := range ns {
		if n > head {
			keep[n] = true // nata dopo la fotografia: giovanissima
			continue
		}
		ts, ok := cached[n]
		if !ok {
			if s.closing.Load() {
				return GCResult{}, nil
			}
			if ts, err = s.readGenTime(id, n); err != nil {
				return GCResult{}, err // età ignota: meglio non toccare niente
			}
			fresh[n] = ts
		}
		if now.Sub(ts) < retentionMinAge {
			keep[n] = true
		}
		if lt := ts.In(time.Local); !lt.Before(firstDay) {
			day := lt.Format("2006-01-02")
			if n > dayRep[day] {
				dayRep[day] = n
			}
		}
	}
	if len(fresh) > 0 {
		st.mu.Lock()
		maps.Copy(st.genTS, fresh)
		st.mu.Unlock()
	}
	for _, n := range dayRep {
		keep[n] = true
	}
	var del []int
	for _, n := range ns {
		if !keep[n] {
			del = append(del, n)
		}
	}
	if len(del) == 0 {
		return GCResult{GenerationsKept: len(ns)}, nil
	}
	return s.prune(id, st, run, ns, del)
}

// gcTestHook è chiamata tra le fasi della pulizia, FUORI dal mutex: i test
// la usano per fare commit e push concorrenti nei momenti critici.
var gcTestHook = func(phase string) {}

// sweepCand è un blob candidato all'eliminazione.
type sweepCand struct {
	path, hash string
	size       int64
	mod        time.Time
}

// prune elimina le generazioni del e poi i blob non più referenziati, con lo
// slot di pulizia run tenuto e SENZA il mutex dello spazio (lo prende solo
// per i passi brevi). Vedi lo schema in cima al file.
func (s *Store) prune(id string, st *spaceState, run *gcRun, all, del []int) (GCResult, error) {
	var res GCResult
	drop := map[int]bool{}
	for _, n := range del {
		drop[n] = true
	}
	// 2. referenziati dalle generazioni che restano (fuori lock)
	referenced := map[string]bool{}
	for _, n := range all {
		if s.closing.Load() {
			return res, nil
		}
		g, err := s.loadGen(id, n)
		if err != nil {
			log.Print(i18n.Lf("store: GC di %s annullato: %v", id, err))
			return res, i18n.Errorf("GC annullato, nessun file eliminato: %w", err)
		}
		if drop[n] {
			continue
		}
		for _, fm := range g.Files {
			for _, h := range blobsOf(fm) {
				referenced[h] = true
			}
		}
	}

	gcTestHook("referenced")

	// 3. via le generazioni (sotto lock: HEAD non si tocca mai)
	st.mu.Lock()
	if st.deleted {
		st.mu.Unlock()
		return res, nil
	}
	for _, n := range del {
		if n == st.head {
			continue
		}
		if err := os.Remove(s.genPath(id, n)); err != nil && !os.IsNotExist(err) {
			st.mu.Unlock()
			return res, err
		}
		delete(st.genTS, n)
		res.GenerationsPruned++
	}
	st.mu.Unlock()
	res.GenerationsKept = len(all) - res.GenerationsPruned
	if res.GenerationsPruned > 0 {
		syncDir(filepath.Join(s.spaceDir(id), "generations"))
	}

	// 4. candidati (fuori lock)
	cands := s.sweepCandidates(id, referenced)

	gcTestHook("candidates")

	// 5. ricontrollo ed eliminazione, a lotti sotto lock
	for i := 0; i < len(cands) && !s.closing.Load(); i += sweepBatch {
		batch := cands[i:min(i+sweepBatch, len(cands))]
		st.mu.Lock()
		if st.deleted {
			st.mu.Unlock()
			break
		}
		st.expirePushesLocked(time.Now())
		var oldestPush time.Time
		for _, ps := range st.pushes {
			if oldestPush.IsZero() || ps.Created.Before(oldestPush) {
				oldestPush = ps.Created
			}
		}
		for _, c := range batch {
			if run.extra[c.hash] || st.pushReferencesLocked(c.hash) {
				continue
			}
			if !oldestPush.IsZero() && !c.mod.Before(oldestPush) {
				continue // forse appena caricato da un push in corso
			}
			if os.Remove(c.path) == nil {
				res.BlobsDeleted++
				res.BytesFreed += c.size
			}
		}
		st.mu.Unlock()
	}
	return res, nil
}

// pushReferencesLocked: il blob è richiesto da un push aperto.
func (st *spaceState) pushReferencesLocked(h string) bool {
	for _, ps := range st.pushes {
		if ps.blobs[h] {
			return true
		}
	}
	return false
}

// sweepCandidates percorre i blob (fuori lock) e restituisce quelli fuori
// da referenced; intanto elimina i temporanei orfani di vecchie scritture
// interrotte (più vecchi di un giorno: nessuna scrittura dura tanto).
func (s *Store) sweepCandidates(id string, referenced map[string]bool) []sweepCand {
	var out []sweepCand
	blobRoot := filepath.Join(s.spaceDir(id), "blobs")
	filepath.Walk(blobRoot, func(path string, info os.FileInfo, err error) error {
		if err != nil || info == nil || info.IsDir() {
			return nil
		}
		base := filepath.Base(path)
		if strings.HasPrefix(base, ".tmp-") {
			if time.Since(info.ModTime()) > tmpMaxAge {
				os.Remove(path)
			}
			return nil
		}
		// i blob possono essere piatti (<hash>) o compressi (<hash>.gz)
		hash := strings.TrimSuffix(base, ".gz")
		if !validHash(hash) || referenced[hash] {
			return nil
		}
		out = append(out, sweepCand{path: path, hash: hash, size: info.Size(), mod: info.ModTime()})
		return nil
	})
	return out
}

// waitGC aspetta le pulizie in background (test e spegnimento).
func (s *Store) waitGC() { s.gcWG.Wait() }

// DiskUsage calcola i byte occupati da uno spazio su disco.
func (s *Store) DiskUsage(id string) (int64, error) {
	if _, err := s.space(id); err != nil {
		return 0, err
	}
	var total int64
	err := filepath.Walk(s.spaceDir(id), func(_ string, info os.FileInfo, err error) error {
		if err == nil && info != nil && !info.IsDir() {
			total += info.Size()
		}
		return nil
	})
	return total, err
}
