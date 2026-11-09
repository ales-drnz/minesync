package api

import (
	"encoding/json"
	"strings"
	"testing"

	"minesync/server/internal/events"
)

// Gli errori dell'API seguono Accept-Language; senza, la lingua dell'hub.
func TestErrorsLocalized(t *testing.T) {
	h := newHub(t)
	w := h.do("GET", "/api/v1/whoami", nil, from("192.168.9.9"), header("Accept-Language", "en-US,en;q=0.9"))
	if got := decodeJSON[map[string]string](t, w)["error"]; got != "not authenticated: connect to the ZeroTier network" {
		t.Fatalf("401 EN: %q", got)
	}
	w = h.do("GET", "/api/v1/whoami", nil, from("192.168.9.9"))
	if got := decodeJSON[map[string]string](t, w)["error"]; !strings.HasPrefix(got, "non autenticato") {
		t.Fatalf("401 IT (default): %q", got)
	}
	// errore dello store con wrapping (%w) e lingua per richiesta
	id := h.createSpace("Mondo")
	w = h.do("GET", "/api/v1/spaces/"+id+"/generations/99", nil, header("Accept-Language", "en"))
	if got := decodeJSON[map[string]string](t, w)["error"]; w.Code != 404 || got != "generation 99: not found" {
		t.Fatalf("404 EN: %d %q", w.Code, got)
	}
	w = h.do("GET", "/api/v1/spaces/"+id+"/generations/99", nil, header("Accept-Language", "it-IT"))
	if got := decodeJSON[map[string]string](t, w)["error"]; got != "generazione 99: non trovato" {
		t.Fatalf("404 IT: %q", got)
	}
	// LockedError: messaggio tradotto, campi invariati
	h.lock(id, ipOther)
	w = h.do("POST", "/api/v1/spaces/"+id+"/lock", jsonBody(map[string]any{}), header("Accept-Language", "en"))
	body := decodeJSON[map[string]any](t, w)
	if w.Code != 409 || body["error"] != "locked by bob" || body["holder"] == nil {
		t.Fatalf("lock EN: %d %v", w.Code, body)
	}
	// guard
	w = h.do("POST", "/api/v1/spaces", nil, noMineSyncHeader(), header("Accept-Language", "en"))
	if got := decodeJSON[map[string]string](t, w)["error"]; got != "missing X-MineSync header" {
		t.Fatalf("guard EN: %q", got)
	}
}

// Gli eventi portano key/args e msg nella lingua della richiesta.
func TestEventsLocalized(t *testing.T) {
	h := newHub(t)
	id := h.createSpace("Mondo")
	h.lock(id, ipMember)
	w := h.do("GET", "/api/v1/events?limit=1", nil, header("Accept-Language", "en"))
	var evs []events.Event
	if err := json.Unmarshal(w.Body.Bytes(), &evs); err != nil || len(evs) != 1 {
		t.Fatalf("eventi: %s", w.Body.String())
	}
	if evs[0].Msg != "steve took the lock" || evs[0].Text == nil || evs[0].Key != "%s ha preso il lock" {
		t.Fatalf("evento EN: %+v", evs[0])
	}
	w = h.do("GET", "/api/v1/events?limit=1&lang=it", nil, header("Accept-Language", "en"))
	if !strings.Contains(w.Body.String(), `"msg":"steve ha preso il lock"`) {
		t.Fatalf("evento IT (?lang): %s", w.Body.String())
	}
	// il log su disco tiene il testo italiano (compatibilità), riletto e
	// reso in inglese anche coi numeri passati da JSON
	bus := events.NewBus(h.srv.DataDir + "/events.jsonl")
	all := bus.Recent(0)
	if all[len(all)-1].Msg != "steve ha preso il lock" {
		t.Fatalf("msg salvato: %q", all[len(all)-1].Msg)
	}
}

func TestDLPageLocalized(t *testing.T) {
	h := newHub(t)
	w := h.do("GET", "/dl", nil, header("Accept-Language", "en-GB,it;q=0.5"))
	b := w.Body.String()
	if !strings.Contains(b, `<html lang="en">`) || !strings.Contains(b, "Download MineSync") ||
		!strings.Contains(b, "No binaries available on the hub.") || strings.Contains(b, "Scarica") {
		t.Fatalf("/dl EN:\n%s", b)
	}
	w = h.do("GET", "/dl", nil, header("Accept-Language", "it"))
	if b := w.Body.String(); !strings.Contains(b, `<html lang="it">`) || !strings.Contains(b, "Scarica MineSync") {
		t.Fatalf("/dl IT:\n%s", b)
	}
}
