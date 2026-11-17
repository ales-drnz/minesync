package api

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"minesync/server/internal/store"
)

func gz(t *testing.T, v any) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	if err := json.NewEncoder(zw).Encode(v); err != nil {
		t.Fatal(err)
	}
	zw.Close()
	return &buf
}

type codeReply struct {
	Error string `json:"error"`
	Code  string `json:"code"`
	Path  string `json:"path"`
}

// C1 + C6: digest nel manifest e nei riepiloghi; push/begin compresso;
// parentDigest sbagliato → 409 stale_base.
func TestDigestAndGzipPushHTTP(t *testing.T) {
	h := newHub(t)
	id := h.createSpace("Mondo")
	sess := h.lock(id, ipMember)
	content := []byte("level.dat")
	files := map[string]store.FileMeta{"world/level.dat": {Hash: sha(content), Size: int64(len(content))}}

	man := decodeJSON[map[string]any](t, h.do("GET", "/api/v1/spaces/"+id+"/manifest", nil))
	d0, _ := man["digest"].(string)
	if len(d0) != 64 {
		t.Fatalf("manifest della gen 0 senza digest: %v", man)
	}

	body := map[string]any{"parent": 0, "parentDigest": d0, "files": files, "session": sess}
	w := h.do("POST", "/api/v1/spaces/"+id+"/push/begin", gz(t, body), header("Content-Encoding", "gzip"))
	if w.Code != 200 {
		t.Fatalf("begin compresso: %d %s", w.Code, w.Body.String())
	}
	br := decodeJSON[struct {
		PushID  string   `json:"pushId"`
		Missing []string `json:"missing"`
	}](t, w)
	h.do("PUT", fmt.Sprintf("/api/v1/spaces/%s/push/%s/blobs/%s", id, br.PushID, br.Missing[0]), rawBody(content))
	w = h.do("POST", fmt.Sprintf("/api/v1/spaces/%s/push/%s/commit", id, br.PushID), jsonBody(struct{}{}))
	g := decodeJSON[store.GenSummary](t, w)
	if w.Code != 200 || len(g.Digest) != 64 {
		t.Fatalf("commit senza digest: %d %s", w.Code, w.Body.String())
	}
	man = decodeJSON[map[string]any](t, h.do("GET", "/api/v1/spaces/"+id+"/manifest?gen=1", nil))
	if man["digest"] != g.Digest {
		t.Fatalf("digest del manifest %v ≠ commit %s", man["digest"], g.Digest)
	}
	gens := decodeJSON[[]store.GenSummary](t, h.do("GET", "/api/v1/spaces/"+id+"/generations", nil))
	if len(gens) != 1 || gens[0].Digest != g.Digest {
		t.Fatalf("storia senza digest: %+v", gens)
	}

	// base con lo stesso numero ma un'altra storia
	body = map[string]any{"parent": 1, "parentDigest": strings.Repeat("ab", 32), "files": files, "session": sess}
	w = h.do("POST", "/api/v1/spaces/"+id+"/push/begin", jsonBody(body))
	if r := decodeJSON[codeReply](t, w); w.Code != 409 || r.Code != "stale_base" || r.Error == "" {
		t.Fatalf("stale_base: %d %s", w.Code, w.Body.String())
	}
	// in inglese, localizzato
	w = h.do("POST", "/api/v1/spaces/"+id+"/push/begin", jsonBody(body), header("Accept-Language", "en"))
	if r := decodeJSON[codeReply](t, w); !strings.Contains(r.Error, "generation 1") {
		t.Fatalf("stale_base non localizzato: %s", w.Body.String())
	}

	// gzip non valido: 400; decompresso oltre il limite: 413
	w = h.do("POST", "/api/v1/spaces/"+id+"/push/begin", rawBody([]byte("non gzip")), header("Content-Encoding", "gzip"))
	if w.Code != 400 {
		t.Fatalf("gzip rotto: %d", w.Code)
	}
	var big bytes.Buffer
	zw := gzip.NewWriter(&big)
	zw.Write([]byte(`{"files":{"`))
	zw.Write(bytes.Repeat([]byte("a"), maxJSONBody+10))
	zw.Close()
	w = h.do("POST", "/api/v1/spaces/"+id+"/push/begin", &big, header("Content-Encoding", "gzip"))
	if w.Code != 413 {
		t.Fatalf("bomba gzip: %d %s", w.Code, w.Body.String())
	}
}

// C5: nomi non validi su Windows → 400 bad_path col percorso.
func TestBadPathHTTP(t *testing.T) {
	h := newHub(t)
	id := h.createSpace("Mondo")
	sess := h.lock(id, ipMember)
	m := store.FileMeta{Hash: strings.Repeat("a", 64), Size: 1}
	for _, files := range []map[string]store.FileMeta{
		{"world/aux.dat": m},
		{"Config/x": m, "config/x": m},
	} {
		w := h.do("POST", "/api/v1/spaces/"+id+"/push/begin",
			jsonBody(map[string]any{"parent": 0, "files": files, "session": sess}))
		r := decodeJSON[codeReply](t, w)
		if w.Code != 400 || r.Code != "bad_path" || r.Path == "" || !strings.Contains(r.Error, r.Path) {
			t.Fatalf("bad_path: %d %s", w.Code, w.Body.String())
		}
	}
}

// Punto 3: niente eliminazione con un lock vivo; heartbeat su spazio
// eliminato → 404 space_gone.
func TestDeleteSpaceAndSpaceGoneHTTP(t *testing.T) {
	h := newHub(t)
	id := h.createSpace("Mondo")
	w := h.do("POST", "/api/v1/spaces/"+id+"/lock", jsonBody(map[string]any{"ttlSec": 1}))
	sess := decodeJSON[map[string]any](t, w)["session"].(string)
	w = h.do("DELETE", "/api/v1/spaces/"+id, nil, from(ipAdmin))
	if r := decodeJSON[codeReply](t, w); w.Code != 409 || r.Code != "locked" {
		t.Fatalf("eliminazione con lock vivo: %d %s", w.Code, w.Body.String())
	}
	time.Sleep(1100 * time.Millisecond)
	if w := h.do("DELETE", "/api/v1/spaces/"+id, nil, from(ipAdmin)); w.Code != 200 {
		t.Fatalf("eliminazione: %d %s", w.Code, w.Body.String())
	}
	w = h.do("POST", "/api/v1/spaces/"+id+"/lock/heartbeat", jsonBody(map[string]any{"session": sess}))
	if r := decodeJSON[codeReply](t, w); w.Code != 404 || r.Code != "space_gone" || r.Error == "" {
		t.Fatalf("heartbeat su spazio eliminato: %d %s", w.Code, w.Body.String())
	}
}

// C3: heartbeat con la sessione giusta ma dal membro rinominato.
func TestHeartbeatAfterRenameHTTP(t *testing.T) {
	h := newHub(t)
	id := h.createSpace("Mondo")
	sess := h.lock(id, ipMember)
	h.srv.ZT = fakeZT{ipMember: {Name: "stefano"}}
	w := h.do("POST", "/api/v1/spaces/"+id+"/lock/heartbeat", jsonBody(map[string]any{"session": sess}))
	if w.Code != 200 {
		t.Fatalf("heartbeat dopo il rinomino: %d %s", w.Code, w.Body.String())
	}
	if lb, _ := decodeJSON[map[string]any](t, w)["lastBeat"].(string); !strings.HasSuffix(lb, "Z") {
		t.Fatalf("lastBeat non in UTC: %q", lb)
	}
	if lk, _ := h.srv.Store.CurrentLock(id); lk.Owner != "stefano" {
		t.Fatalf("owner mostrato %q", lk.Owner)
	}
}

// C4: disco pieno → 507 disk_full, un solo avviso l'ora; lo stato mostra lo spazio.
func TestDiskFullHTTP(t *testing.T) {
	h := newHub(t)
	id := h.createSpace("Mondo")
	st := h.srv.Store
	st.DiskGuard = true
	st.SetDiskStat(func(string) (uint64, uint64, error) { return 100 << 20, 100 << 30, nil })
	status := decodeJSON[map[string]any](t, h.do("GET", "/api/v1/status", nil))
	if status["diskFree"] != float64(100<<20) || status["diskTotal"] != float64(100<<30) {
		t.Fatalf("status senza spazio disco: %v", status)
	}
	for i := 0; i < 3; i++ {
		w := h.do("POST", "/api/v1/spaces/"+id+"/lock", jsonBody(map[string]any{"ttlSec": 90}))
		if r := decodeJSON[codeReply](t, w); w.Code != 507 || r.Code != "disk_full" || r.Error == "" {
			t.Fatalf("lock con disco pieno: %d %s", w.Code, w.Body.String())
		}
	}
	n := 0
	for _, e := range h.srv.Bus.Recent(100) {
		if e.Type == "disk" {
			n++
		}
	}
	if n != 1 {
		t.Fatalf("avvisi di disco pieno: %d, atteso 1", n)
	}
}
