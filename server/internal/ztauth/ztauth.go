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
	maxStale   = 5 * time.Minute  // oltre, con ztnet giù, si nega l'accesso
	retryEvery = 5 * time.Second  // tra due tentativi falliti
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
	return &Resolver{admins: am, ttl: defaultTTL, fetch: fetch, byIP: map[string]member{}}
}

// Lookup risolve un IP in (nome, admin). ok=false se l'IP non è un membro.
// L'admin si riconosce per nome membro O per node-ID (MINESYNC_ADMINS).
// Con una cache valida risponde subito (e la rinfresca in background se
// vecchia); aspetta ztnet solo se la cache è vuota o troppo vecchia.
func (r *Resolver) Lookup(ip string) (name string, admin bool, ok bool) {
	if r == nil {
		return "", false, false
	}
	r.mu.Lock()
	age := time.Since(r.fetched)
	if age > r.ttl {
		ch := r.refreshLocked()
		if r.fetched.IsZero() || age > maxStale {
			r.mu.Unlock()
			if ch != nil {
				<-ch
			}
			r.mu.Lock()
		}
	}
	defer r.mu.Unlock()
	if r.fetched.IsZero() || time.Since(r.fetched) > maxStale {
		return "", false, false // ztnet irraggiungibile da troppo: meglio negare
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
		if err == nil {
			r.byIP, r.fetched = fresh, time.Now()
		} else {
			log.Print(i18n.Lf("ztauth: aggiornamento membri fallito: %v", err))
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
