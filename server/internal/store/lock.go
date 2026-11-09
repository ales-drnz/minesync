package store

import (
	cryptorand "crypto/rand"
	"os"
	"path/filepath"
	"slices"
	"time"

	"minesync/server/internal/i18n"
)

func cryptoRead(b []byte) (int, error) { return cryptorand.Read(b) }

// LockInfo è lo stato del lock di uno spazio.
type LockInfo struct {
	Owner    string            `json:"owner"`
	Session  string            `json:"session"`
	Since    time.Time         `json:"since"`
	LastBeat time.Time         `json:"lastBeat"`
	TTLSec   int               `json:"ttlSec"`
	Info     map[string]string `json:"info,omitempty"`
	Players  []string          `json:"players,omitempty"` // chi è in gioco, dall'heartbeat
	Ready    bool              `json:"ready,omitempty"`   // server Minecraft avviato
	// Reachable: esito del test di raggiungibilità porta fatto dall'hub
	// (nil = non ancora testato). ReachAt è quando è stato misurato.
	Reachable *bool     `json:"reachable,omitempty"`
	ReachAt   time.Time `json:"reachAt,omitempty"`
}

// Stale riporta se il lock ha superato il TTL senza heartbeat.
func (l *LockInfo) Stale(now time.Time) bool {
	return now.Sub(l.LastBeat) > time.Duration(l.TTLSec)*time.Second
}

// Clone restituisce una copia profonda (mappe e slice non condivise): ciò
// che esce dallo store non deve mai essere toccato dagli heartbeat.
func (l *LockInfo) Clone() *LockInfo {
	c := *l
	if l.Info != nil {
		c.Info = make(map[string]string, len(l.Info))
		for k, v := range l.Info {
			c.Info[k] = v
		}
	}
	c.Players = slices.Clone(l.Players)
	if l.Reachable != nil {
		r := *l.Reachable
		c.Reachable = &r
	}
	return &c
}

// Redacted restituisce una copia senza il session segreto (per mostrarla ad altri).
func (l *LockInfo) Redacted() *LockInfo {
	c := l.Clone()
	c.Session = ""
	return c
}

// AcquireLock prende il lock di uno spazio. Se il lock corrente è stale viene
// rimpiazzato automaticamente (e il chiamante lo scopre da tookOver).
// Se è vivo, restituisce LockedError con i dettagli del titolare.
func (s *Store) AcquireLock(id, owner string, info map[string]string, ttlSec int) (lk *LockInfo, tookOver *LockInfo, err error) {
	st, err := s.space(id)
	if err != nil {
		return nil, nil, err
	}
	if ttlSec <= 0 {
		ttlSec = DefaultLockTTLSec
	}
	ttlSec = min(ttlSec, MaxLockTTLSec)
	now := time.Now().UTC()
	st.mu.Lock()
	defer st.mu.Unlock()
	if st.lock != nil {
		if !st.lock.Stale(now) {
			return nil, nil, &LockedError{Holder: st.lock.Redacted()}
		}
		tookOver = st.lock.Redacted()
		// la sessione stale si chiude all'ultimo battito ricevuto
		s.closeSessionLocked(id, st, st.lock.Owner, st.lock.Since, st.lock.LastBeat)
	}
	lk = &LockInfo{
		Owner: owner, Session: randomID(), Since: now, LastBeat: now,
		TTLSec: ttlSec, Info: info,
	}
	prev := st.lock
	st.lock = lk
	if err := s.persistLock(id, st); err != nil {
		st.lock = prev
		return nil, nil, err
	}
	return lk.Clone(), tookOver, nil
}

// HeartbeatLock rinnova il lock e aggiorna chi è in gioco.
// Session deve combaciare. players==nil lascia l'elenco invariato.
// ready segnala che il server Minecraft è avviato (abilita il test porta).
func (s *Store) HeartbeatLock(id, session string, players []string, ready bool) (*LockInfo, error) {
	st, err := s.space(id)
	if err != nil {
		return nil, err
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	if st.lock == nil || st.lock.Session != session {
		return nil, i18n.Errorf("%w: lock non tuo o già rilasciato", ErrConflict)
	}
	st.lock.Ready = ready
	now := time.Now().UTC()
	// statistiche: nell'intervallo dall'ultimo battito erano online i giocatori
	// del battito PRECEDENTE; delta oltre il TTL = client sparito, non conta
	if delta := now.Sub(st.lock.LastBeat); delta <= time.Duration(st.lock.TTLSec)*time.Second {
		s.accrueStatsLocked(id, st, st.lock.Owner, st.lock.Players, delta, now)
	}
	st.lock.LastBeat = now
	if players != nil {
		st.lock.Players = players
	}
	if err := s.persistLock(id, st); err != nil {
		return nil, err
	}
	return st.lock.Clone(), nil
}

// ReleaseLock rilascia il lock. Con force=true ignora la session (audit e
// permessi a carico del chiamante: l'API lo concede solo agli admin). Un lock
// stale può essere liberato da chiunque. Restituisce il lock rimosso, o nil.
func (s *Store) ReleaseLock(id, session string, force bool) (*LockInfo, error) {
	st, err := s.space(id)
	if err != nil {
		return nil, err
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	if st.lock == nil {
		return nil, nil
	}
	if !force && st.lock.Session != session {
		// un lock stale può essere liberato da chiunque anche senza force
		if !st.lock.Stale(time.Now().UTC()) {
			return nil, i18n.Errorf("%w: il lock appartiene a %s", ErrConflict, st.lock.Owner)
		}
	}
	removed := st.lock.Redacted()
	// sessione conclusa: se il lock era stale, la fine vera è l'ultimo battito
	until := time.Now().UTC()
	if st.lock.Stale(until) {
		until = st.lock.LastBeat
	}
	s.closeSessionLocked(id, st, st.lock.Owner, st.lock.Since, until)
	st.lock = nil
	if err := s.persistLock(id, st); err != nil {
		return nil, err
	}
	return removed, nil
}

// SetReachable registra l'esito del test di raggiungibilità porta, solo se il
// lock è ancora quello della sessione indicata.
func (s *Store) SetReachable(id, session string, reachable bool) error {
	st, err := s.space(id)
	if err != nil {
		return err
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	if st.lock == nil || st.lock.Session != session {
		return nil // lock cambiato nel frattempo: esito obsoleto, si scarta
	}
	st.lock.Reachable = &reachable
	st.lock.ReachAt = time.Now().UTC()
	return s.persistLock(id, st)
}

// CurrentLock restituisce il lock corrente (redatto), o nil.
func (s *Store) CurrentLock(id string) (*LockInfo, error) {
	st, err := s.space(id)
	if err != nil {
		return nil, err
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	if st.lock == nil {
		return nil, nil
	}
	return st.lock.Redacted(), nil
}

func (s *Store) persistLock(id string, st *spaceState) error {
	path := filepath.Join(s.spaceDir(id), "lock.json")
	if st.lock == nil {
		err := os.Remove(path)
		if err != nil && !os.IsNotExist(err) {
			return err
		}
		return nil
	}
	return writeJSON(path, st.lock)
}
