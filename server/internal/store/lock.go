package store

import (
	cryptorand "crypto/rand"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"time"

	"minesync/server/internal/i18n"
)

func cryptoRead(b []byte) (int, error) { return cryptorand.Read(b) }

// LockInfo è lo stato del lock di uno spazio.
//
// Gli istanti (Since, LastBeat, ReachAt) in memoria vengono da time.Now() così
// com'è, con la lettura monotona: i confronti di scadenza non risentono dei
// salti dell'orologio di sistema. Su disco e sull'API escono in UTC
// (MarshalJSON).
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

// Stale riporta se il lock ha superato il TTL senza heartbeat. now va
// passato com'è da time.Now() (MAI .UTC() o .Round(0)): così, se anche
// LastBeat viene da time.Now() in questo processo, il confronto usa l'orologio
// monotono e un salto dell'ora di sistema (NTP, ora sbagliata) non fa scadere
// né resuscitare i lock.
func (l *LockInfo) Stale(now time.Time) bool {
	return now.Sub(l.LastBeat) > time.Duration(l.TTLSec)*time.Second
}

// MarshalJSON serializza gli istanti in UTC (su disco e sull'API), mentre in
// memoria restano con la lettura monotona per i confronti.
func (l LockInfo) MarshalJSON() ([]byte, error) {
	type plain LockInfo // senza metodi: niente ricorsione
	c := plain(l)
	c.Since, c.LastBeat = c.Since.UTC(), c.LastBeat.UTC()
	if !c.ReachAt.IsZero() {
		c.ReachAt = c.ReachAt.UTC()
	}
	return json.Marshal(c)
}

// Action è il motivo del lock dichiarato dal client (info "action"): "play"
// per una sessione di gioco, "push" per un push manuale. I client fino alla
// 3.1 non lo mandano: in quel caso una sessione di gioco si riconosce dal
// campo "host" (""= sconosciuto).
func (l *LockInfo) Action() string {
	if a := l.Info["action"]; a != "" {
		return a
	}
	if l.Info["host"] != "" {
		return "play"
	}
	return ""
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
	if err := s.checkDisk(); err != nil {
		return nil, nil, err
	}
	now := time.Now()
	st.mu.Lock()
	defer st.mu.Unlock()
	if st.deleted {
		return nil, nil, i18n.Errorf("space %q: %w", id, ErrNotFound)
	}
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
		s.publishLockLocked(id, st)
		return nil, nil, err
	}
	return lk.Clone(), tookOver, nil
}

// HeartbeatLock rinnova il lock e aggiorna chi è in gioco.
// La session deve combaciare: è lei l'autorità, non il nome. owner è il nome
// attuale del chiamante ("" = invariato): se il membro è stato rinominato in
// ZTNET a sessione in corso, il nome mostrato si aggiorna. players==nil
// lascia l'elenco invariato. ready segnala che il server Minecraft è avviato
// (abilita il test porta). Uno spazio che non esiste più dà SpaceGoneError:
// il client smette di riprovare.
func (s *Store) HeartbeatLock(id, session, owner string, players []string, ready bool) (*LockInfo, error) {
	st, err := s.space(id)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return nil, &SpaceGoneError{ID: id}
		}
		return nil, err
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	if st.deleted {
		return nil, &SpaceGoneError{ID: id}
	}
	if st.lock == nil || st.lock.Session != session {
		return nil, i18n.Errorf("%w: lock non tuo o già rilasciato", ErrConflict)
	}
	st.lock.Ready = ready
	now := time.Now()
	// statistiche: nell'intervallo dall'ultimo battito erano online i giocatori
	// del battito PRECEDENTE; delta oltre il TTL = client sparito, non conta.
	// Un delta negativo (orologio tornato indietro su un lock riletto da
	// disco, senza lettura monotona) vale zero.
	delta := max(now.Sub(st.lock.LastBeat), 0)
	if delta <= time.Duration(st.lock.TTLSec)*time.Second {
		s.accrueStatsLocked(id, st, st.lock.Owner, st.lock.Players, delta, now)
	}
	if owner != "" {
		st.lock.Owner = owner
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
	if st.deleted || st.lock == nil {
		return nil, nil
	}
	if !force && st.lock.Session != session {
		// un lock stale può essere liberato da chiunque anche senza force
		if !st.lock.Stale(time.Now()) {
			return nil, i18n.Errorf("%w: il lock appartiene a %s", ErrConflict, st.lock.Owner)
		}
	}
	removed := st.lock.Redacted()
	// sessione conclusa: se il lock era stale, la fine vera è l'ultimo battito
	until := time.Now()
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
	if st.deleted || st.lock == nil || st.lock.Session != session {
		return nil // lock cambiato nel frattempo: esito obsoleto, si scarta
	}
	st.lock.Reachable = &reachable
	st.lock.ReachAt = time.Now()
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

// LockSnapshot restituisce il lock corrente (redatto) SENZA prendere il mutex
// dello spazio: legge l'istantanea aggiornata a ogni cambio del lock. È per i
// lettori frequenti che non devono mai aspettare un commit o un GC (il DNS
// interno). exists=false se lo spazio non esiste.
func (s *Store) LockSnapshot(id string) (lk *LockInfo, exists bool) {
	v, ok := s.lockSnap.Load(id)
	if !ok {
		return nil, false
	}
	if l := v.(lockSnap).lk; l != nil {
		return l.Clone(), true
	}
	return nil, true
}

// lockSnap è un valore dell'istantanea: lk nil = spazio senza lock.
type lockSnap struct{ lk *LockInfo }

// publishLockLocked aggiorna l'istantanea del lock (mutex dello spazio tenuto).
func (s *Store) publishLockLocked(id string, st *spaceState) {
	if st.deleted {
		return // l'id potrebbe già essere di uno spazio ricreato
	}
	var lk *LockInfo
	if st.lock != nil {
		lk = st.lock.Redacted()
	}
	s.lockSnap.Store(id, lockSnap{lk})
}

// persistLock salva il lock su disco e ne aggiorna l'istantanea: ogni cambio
// del lock passa da qui.
func (s *Store) persistLock(id string, st *spaceState) error {
	s.publishLockLocked(id, st)
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
