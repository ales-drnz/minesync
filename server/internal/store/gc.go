package store

import (
	"log"
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
)

// GC pota le generazioni oltre keepLast ed elimina i blob orfani
// (operazione esplicita dell'admin: niente protezioni a tempo).
func (s *Store) GC(id string, keepLast int) (GCResult, error) {
	st, err := s.space(id)
	if err != nil {
		return GCResult{}, err
	}
	if keepLast < 1 {
		return GCResult{}, i18n.Errorf("%w: keep deve essere ≥ 1", ErrBadRequest)
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	ns, err := s.genNumbers(id)
	if err != nil {
		return GCResult{}, err
	}
	cutoff := st.head - keepLast + 1
	var del []int
	for _, n := range ns {
		if n < cutoff {
			del = append(del, n)
		}
	}
	return s.pruneLocked(id, st, ns, del)
}

// DeleteGeneration elimina una singola generazione (mai HEAD) e i blob
// che restano orfani.
func (s *Store) DeleteGeneration(id string, n int) error {
	st, err := s.space(id)
	if err != nil {
		return err
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	if n == st.head {
		return i18n.Errorf("%w: non puoi eliminare la versione corrente (HEAD)", ErrBadRequest)
	}
	if _, err := os.Stat(s.genPath(id, n)); err != nil {
		return i18n.Errorf("generazione %d: %w", n, ErrNotFound)
	}
	ns, err := s.genNumbers(id)
	if err != nil {
		return err
	}
	_, err = s.pruneLocked(id, st, ns, []int{n})
	return err
}

// retentionLocked è la potatura automatica dopo ogni nuova generazione.
// Conserva sempre: le ultime KeepLast, quelle più giovani di 24 ore e la più
// recente di ciascuno degli ultimi 7 giorni di calendario. Così una raffica
// di push (anche vuoti) non può cancellare la storia.
func (s *Store) retentionLocked(id string, st *spaceState, now time.Time) (GCResult, error) {
	ns, err := s.genNumbers(id)
	if err != nil || len(ns) <= s.KeepLast {
		return GCResult{}, err
	}
	keep := map[int]bool{st.head: true}
	for _, n := range ns[len(ns)-s.KeepLast:] {
		keep[n] = true
	}
	today := now.In(time.Local)
	firstDay := time.Date(today.Year(), today.Month(), today.Day()-(retentionDays-1), 0, 0, 0, 0, time.Local)
	dayRep := map[string]int{}
	for _, n := range ns {
		ts, err := s.genTime(id, st, n)
		if err != nil {
			return GCResult{}, err // età ignota: meglio non toccare niente
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
	return s.pruneLocked(id, st, ns, del)
}

// pruneLocked elimina le generazioni del e poi i blob non più referenziati.
// Prima di toccare qualunque cosa legge TUTTE le generazioni: se anche una
// sola è illeggibile si ferma senza eliminare niente (i suoi blob
// risulterebbero orfani e verrebbero cancellati). Sono referenziati anche i
// blob delle sessioni di push aperte, e i blob più recenti della sessione
// aperta più vecchia non si toccano (upload in corso).
func (s *Store) pruneLocked(id string, st *spaceState, all, del []int) (GCResult, error) {
	var res GCResult
	drop := map[int]bool{}
	for _, n := range del {
		drop[n] = true
	}
	referenced := map[string]bool{}
	for _, n := range all {
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
	st.expirePushesLocked(time.Now())
	var oldestPush time.Time
	for _, ps := range st.pushes {
		for h := range ps.blobs {
			referenced[h] = true
		}
		if oldestPush.IsZero() || ps.Created.Before(oldestPush) {
			oldestPush = ps.Created
		}
	}

	for _, n := range del {
		if err := os.Remove(s.genPath(id, n)); err != nil && !os.IsNotExist(err) {
			return res, err
		}
		delete(st.genTS, n)
		res.GenerationsPruned++
	}
	res.GenerationsKept = len(all) - len(del)
	if len(del) > 0 {
		syncDir(filepath.Join(s.spaceDir(id), "generations"))
	}
	res.BlobsDeleted, res.BytesFreed = s.sweepBlobs(id, referenced, oldestPush)
	return res, nil
}

// sweepBlobs elimina i blob fuori da referenced (e più vecchi di notAfter,
// se valorizzato) e i temporanei orfani di vecchie scritture interrotte.
func (s *Store) sweepBlobs(id string, referenced map[string]bool, notAfter time.Time) (deleted int, freed int64) {
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
		if !notAfter.IsZero() && !info.ModTime().Before(notAfter) {
			return nil // forse appena caricato da un push in corso
		}
		size := info.Size()
		if os.Remove(path) == nil {
			deleted++
			freed += size
		}
		return nil
	})
	return deleted, freed
}

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
