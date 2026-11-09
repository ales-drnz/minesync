// Statistiche di gioco per spazio, accumulate dagli heartbeat del lock:
// ore per giocatore, ore di hosting e ultime sessioni. Persistite in
// spaces/<id>/stats.json (scrittura throttled: al massimo una al minuto,
// più il flush a fine sessione).
package store

import (
	"log"
	"path/filepath"
	"slices"
	"time"

	"minesync/server/internal/i18n"
)

// PlayerStat è il tempo accumulato da un giocatore (o host).
type PlayerStat struct {
	Seconds  int64     `json:"seconds"`
	LastSeen time.Time `json:"lastSeen"`
}

// SessionStat è una sessione di hosting conclusa.
type SessionStat struct {
	Owner string    `json:"owner"`
	Since time.Time `json:"since"`
	Until time.Time `json:"until"`
}

// SpaceStats raccoglie le statistiche di uno spazio.
type SpaceStats struct {
	Players  map[string]PlayerStat `json:"players"`  // tempo in gioco per giocatore
	Hosts    map[string]PlayerStat `json:"hosts"`    // tempo di hosting per membro
	Sessions []SessionStat         `json:"sessions"` // ultime sessioni concluse
}

const (
	statsKeepSessions = 40
	statsWriteEvery   = time.Minute
)

func (s *Store) statsPath(id string) string {
	return filepath.Join(s.spaceDir(id), "stats.json")
}

// statsLocked carica (e memorizza) le stats di uno spazio; lock già tenuto.
func (s *Store) statsLocked(id string, st *spaceState) *SpaceStats {
	if st.stats == nil {
		var ss SpaceStats
		_ = readJSON(s.statsPath(id), &ss)
		if ss.Players == nil {
			ss.Players = map[string]PlayerStat{}
		}
		if ss.Hosts == nil {
			ss.Hosts = map[string]PlayerStat{}
		}
		st.stats = &ss
	}
	return st.stats
}

// Stats restituisce le statistiche correnti di uno spazio.
func (s *Store) Stats(id string) (SpaceStats, error) {
	st, err := s.space(id)
	if err != nil {
		return SpaceStats{}, err
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	return s.statsLocked(id, st).clone(), nil
}

// clone copia in profondità: l'heartbeat scrive le mappe sotto st.mu mentre
// l'API le serializza fuori lock.
func (ss *SpaceStats) clone() SpaceStats {
	c := SpaceStats{
		Players:  make(map[string]PlayerStat, len(ss.Players)),
		Hosts:    make(map[string]PlayerStat, len(ss.Hosts)),
		Sessions: slices.Clone(ss.Sessions),
	}
	for k, v := range ss.Players {
		c.Players[k] = v
	}
	for k, v := range ss.Hosts {
		c.Hosts[k] = v
	}
	return c
}

// accrueStatsLocked aggiunge delta di tempo a host e giocatori online.
// Chiamata dall'heartbeat: delta è il tempo trascorso dall'ultimo battito,
// players chi era in gioco in quell'intervallo.
func (s *Store) accrueStatsLocked(id string, st *spaceState, owner string, players []string, delta time.Duration, now time.Time) {
	if delta <= 0 {
		return
	}
	ss := s.statsLocked(id, st)
	sec := int64(delta.Seconds())
	h := ss.Hosts[owner]
	h.Seconds += sec
	h.LastSeen = now
	ss.Hosts[owner] = h
	for _, p := range players {
		ps := ss.Players[p]
		ps.Seconds += sec
		ps.LastSeen = now
		ss.Players[p] = ps
	}
	if now.Sub(st.statsSaved) > statsWriteEvery {
		s.saveStatsLocked(id, st)
	}
}

// closeSessionLocked registra una sessione conclusa e forza il flush.
func (s *Store) closeSessionLocked(id string, st *spaceState, owner string, since, until time.Time) {
	if since.IsZero() || until.Sub(since) < time.Minute {
		return // sessioni lampo: rumore, non storia
	}
	ss := s.statsLocked(id, st)
	ss.Sessions = append(ss.Sessions, SessionStat{Owner: owner, Since: since, Until: until})
	if len(ss.Sessions) > statsKeepSessions {
		ss.Sessions = ss.Sessions[len(ss.Sessions)-statsKeepSessions:]
	}
	s.saveStatsLocked(id, st)
}

// Flush salva su disco le statistiche in sospeso di tutti gli spazi e
// aspetta che finiscano le operazioni in corso (prende ogni lock di spazio):
// da chiamare allo spegnimento dell'hub.
func (s *Store) Flush() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for id, st := range s.spaces {
		st.mu.Lock()
		if st.stats != nil && !st.deleted {
			if err := writeJSON(s.statsPath(id), st.stats); err != nil {
				log.Print(i18n.Lf("store: statistiche di %s non salvate: %v", id, err))
			}
		}
		st.mu.Unlock()
	}
}

func (s *Store) saveStatsLocked(id string, st *spaceState) {
	if st.stats == nil {
		return
	}
	// se la scrittura fallisce si riprova al prossimo giro
	if err := writeJSON(s.statsPath(id), st.stats); err == nil {
		st.statsSaved = time.Now()
	}
}
