// Package ztauth: autenticazione automatica via rete ZeroTier.
//
// Il modello di fiducia è la rete ZeroTier: gli IP della rete ZeroTier sono
// garantiti crittograficamente dalla rete stessa, quindi "arrivi da un IP
// membro" = "sei quel membro". L'hub interroga l'API di ZTNET per mappare
// IP → nome membro, con una cache breve aggiornata in background.
package ztauth

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"minesync/server/internal/i18n"
)

type member struct {
	Name string
	ID   string // node-ID ZeroTier (10 hex)
}

const (
	defaultTTL = 30 * time.Second // dopo quanto si rinfresca la cache
	retryEvery = 5 * time.Second  // tra due tentativi falliti
	// DefaultGrace: per quanto, con ZTNET irraggiungibile, si continuano a
	// riconoscere i membri dell'ultimo elenco scaricato (MINESYNC_ZTNET_GRACE).
	DefaultGrace = 24 * time.Hour
)

type Resolver struct {
	admins map[string]bool // identità admin (nome membro O node-ID, lowercase)
	ttl    time.Duration
	// fetch scarica la mappa IP → membro (sostituibile nei test).
	fetch func() (map[string]member, error)

	mu         sync.Mutex // MAI tenuto durante una richiesta HTTP
	byIP       map[string]member
	fetched    time.Time     // ultimo aggiornamento riuscito
	lastTry    time.Time     // ultimo tentativo (anche fallito)
	refreshing chan struct{} // non nil mentre un aggiornamento è in corso
	grace      time.Duration // validità dell'ultimo elenco con ZTNET giù (≤0 = illimitata)
	down       bool          // ZTNET irraggiungibile (per loggarlo una volta sola)
}

// New crea il resolver; restituisce nil se la configurazione è incompleta
// (senza ZeroTier nessuno è autenticato, salvo MINESYNC_DEV_USER da loopback).
func New(url, token, networkID string, admins []string) *Resolver {
	if url == "" || token == "" || networkID == "" {
		return nil
	}
	hc := &http.Client{Timeout: 8 * time.Second}
	base := strings.TrimRight(url, "/")
	r := newResolver(admins, func() (map[string]member, error) {
		return fetchMembers(hc, base, token, networkID)
	})
	return r
}

func newResolver(admins []string, fetch func() (map[string]member, error)) *Resolver {
	am := map[string]bool{}
	for _, a := range admins {
		a = strings.ToLower(strings.TrimSpace(a))
		if a != "" {
			am[a] = true
		}
	}
	return &Resolver{admins: am, ttl: defaultTTL, fetch: fetch, byIP: map[string]member{}, grace: DefaultGrace}
}

// SetGrace fissa per quanto, con ZTNET irraggiungibile, valgono ancora i
// membri dell'ultimo elenco scaricato (≤0 = senza limite).
func (r *Resolver) SetGrace(d time.Duration) {
	if r == nil {
		return
	}
	r.mu.Lock()
	r.grace = d
	r.mu.Unlock()
}

// Lookup risolve un IP in (nome, admin). ok=false se l'IP non è un membro.
// L'admin si riconosce per nome membro O per node-ID (MINESYNC_ADMINS).
// Aspetta ZTNET solo al primo uso (elenco mai scaricato); poi risponde sempre
// dalla cache, che si rinfresca in background. Se ZTNET non risponde si
// continua con l'ultimo elenco noto (un membro sparisce solo quando un
// aggiornamento RIUSCITO lo dice), fino al limite di grace: un ZTNET giù non
// deve chiudere fuori tutti.
func (r *Resolver) Lookup(ip string) (name string, admin bool, ok bool) {
	if r == nil {
		return "", false, false
	}
	r.mu.Lock()
	switch {
	case r.fetched.IsZero():
		ch := r.refreshLocked()
		r.mu.Unlock()
		if ch != nil {
			<-ch
		}
		r.mu.Lock()
	case time.Since(r.fetched) > r.ttl:
		r.refreshLocked() // in background: si risponde con la cache
	}
	defer r.mu.Unlock()
	if r.fetched.IsZero() {
		return "", false, false // mai riuscito a sapere chi è membro
	}
	if r.grace > 0 && time.Since(r.fetched) > r.grace {
		return "", false, false // ZTNET giù da troppo: meglio negare
	}
	m, ok := r.byIP[ip]
	if !ok {
		return "", false, false
	}
	admin = r.admins[strings.ToLower(m.Name)] || r.admins[strings.ToLower(m.ID)]
	return m.Name, admin, true
}

// refreshLocked avvia (se non già in corso e non appena fallito) un
// aggiornamento in background e ne restituisce il canale di completamento.
func (r *Resolver) refreshLocked() chan struct{} {
	if r.refreshing != nil {
		return r.refreshing
	}
	if time.Since(r.lastTry) < retryEvery {
		return nil
	}
	ch := make(chan struct{})
	r.refreshing, r.lastTry = ch, time.Now()
	go func() {
		fresh, err := r.fetch()
		r.mu.Lock()
		switch {
		case err == nil:
			if r.down {
				log.Print(i18n.Lf("ztauth: ZTNET di nuovo raggiungibile (%d indirizzi membri)", len(fresh)))
			}
			r.byIP, r.fetched, r.down = fresh, time.Now(), false
		case !r.down:
			// una volta sola, non a ogni tentativo
			r.down = true
			log.Print(i18n.Lf("ztauth: ZTNET irraggiungibile (%v): continuo a riconoscere i membri già noti (%d indirizzi)", err, len(r.byIP)))
		}
		r.refreshing = nil
		r.mu.Unlock()
		close(ch)
	}()
	return ch
}

func fetchMembers(hc *http.Client, base, token, networkID string) (map[string]member, error) {
	req, err := http.NewRequest("GET", fmt.Sprintf("%s/api/v1/network/%s/member", base, networkID), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("x-ztnet-auth", token)
	res, err := hc.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return nil, fmt.Errorf("ztnet HTTP %d", res.StatusCode)
	}
	var members []struct {
		ID            string   `json:"id"`
		Address       string   `json:"address"`
		NodeID        any      `json:"nodeId"`
		Name          string   `json:"name"`
		Authorized    *bool    `json:"authorized"`
		IPAssignments []string `json:"ipAssignments"`
	}
	if err := json.NewDecoder(io.LimitReader(res.Body, 8<<20)).Decode(&members); err != nil {
		return nil, err
	}
	out := map[string]member{}
	for _, m := range members {
		if m.Authorized != nil && !*m.Authorized {
			continue
		}
		id := strings.ToLower(m.ID)
		if id == "" {
			id = strings.ToLower(m.Address)
		}
		name := m.Name
		if name == "" {
			name = id
		}
		if name == "" {
			continue
		}
		for _, ip := range m.IPAssignments {
			out[ip] = member{Name: name, ID: id}
		}
	}
	return out, nil
}
