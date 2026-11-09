package api

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"minesync/server/internal/events"
	"minesync/server/internal/store"
)

// fakeZT: IP → membro, senza ztnet.
type fakeZT map[string]Identity

func (f fakeZT) Lookup(ip string) (string, bool, bool) {
	id, ok := f[ip]
	return id.Name, id.Admin, ok
}

const (
	ipAdmin  = "10.0.0.1"
	ipMember = "10.0.0.2"
	ipOther  = "10.0.0.3"
)

type testHub struct {
	t   *testing.T
	srv *Server
	h   http.Handler
}

func newHub(t *testing.T) *testHub {
	t.Helper()
	dir := t.TempDir()
	st, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	srv := &Server{
		Store: st, Bus: events.NewBus(filepath.Join(dir, "events.jsonl")),
		ZT: fakeZT{
			ipAdmin:  {Name: "alex", Admin: true},
			ipMember: {Name: "steve"},
			ipOther:  {Name: "bob"},
		},
		Started: time.Now(), DataDir: dir, DLDir: filepath.Join(dir, "dl"), DNSZone: "internal",
	}
	return &testHub{t: t, srv: srv, h: srv.Handler()}
}

type reqOpt func(*http.Request)

func header(k, v string) reqOpt { return func(r *http.Request) { r.Header.Set(k, v) } }
func host(h string) reqOpt      { return func(r *http.Request) { r.Host = h } }
func noMineSyncHeader() reqOpt  { return func(r *http.Request) { r.Header.Del("X-MineSync") } }
func from(ip string) reqOpt {
	return func(r *http.Request) { r.RemoteAddr = net.JoinHostPort(ip, "40000") }
}
func rawBody(b []byte) io.Reader          { return bytes.NewReader(b) }
func jsonBody(v any) io.Reader            { b, _ := json.Marshal(v); return bytes.NewReader(b) }
func (h *testHub) srvStore() *store.Store { return h.srv.Store }

// do esegue una richiesta (di default: da un membro, con Host IP e header).
func (h *testHub) do(method, path string, body io.Reader, opts ...reqOpt) *httptest.ResponseRecorder {
	h.t.Helper()
	r := httptest.NewRequest(method, path, body)
	r.RemoteAddr = ipMember + ":40000"
	r.Host = "10.0.0.100:8084"
	r.Header.Set("X-MineSync", "test")
	for _, o := range opts {
		o(r)
	}
	w := httptest.NewRecorder()
	h.h.ServeHTTP(w, r)
	return w
}

func decodeJSON[T any](t *testing.T, w *httptest.ResponseRecorder) T {
	t.Helper()
	var v T
	if err := json.Unmarshal(w.Body.Bytes(), &v); err != nil {
		t.Fatalf("risposta non JSON (%d): %s", w.Code, w.Body.String())
	}
	return v
}

func sha(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

// --- C1: anti-CSRF / anti-DNS-rebinding ---

func TestGuardCSRF(t *testing.T) {
	h := newHub(t)
	cases := []struct {
		name   string
		method string
		path   string
		opts   []reqOpt
		want   int
	}{
		{"mutazione senza header", "POST", "/api/v1/spaces", []reqOpt{from(ipAdmin), noMineSyncHeader()}, 403},
		{"mutazione con header", "POST", "/api/v1/spaces", []reqOpt{from(ipAdmin)}, 200},
		{"GET senza header", "GET", "/api/v1/status", []reqOpt{noMineSyncHeader()}, 200},
		{"cross-site", "GET", "/api/v1/status", []reqOpt{header("Sec-Fetch-Site", "cross-site")}, 403},
		{"same-origin", "GET", "/api/v1/status", []reqOpt{header("Sec-Fetch-Site", "same-origin")}, 200},
		{"host estraneo api", "GET", "/api/v1/status", []reqOpt{host("evil.example.com")}, 403},
		{"host estraneo dl", "GET", "/dl", []reqOpt{host("evil.example.com:8084")}, 403},
		{"host vuoto", "GET", "/api/v1/status", []reqOpt{host("")}, 403},
		{"IPv4 letterale", "GET", "/api/v1/status", []reqOpt{host("192.168.1.10")}, 200},
		{"IPv6 letterale", "GET", "/api/v1/status", []reqOpt{host("[fd00::1]:8084")}, 200},
		{"localhost", "GET", "/api/v1/status", []reqOpt{host("localhost:8084")}, 200},
		{"*.localhost", "GET", "/api/v1/status", []reqOpt{host("hub.localhost")}, 200},
		{"zona DNS", "GET", "/api/v1/status", []reqOpt{host("hub.internal:8084")}, 200},
		{"zona finta", "GET", "/api/v1/status", []reqOpt{host("hubinternal")}, 403},
	}
	for _, c := range cases {
		body := io.Reader(nil)
		if c.method == "POST" {
			body = jsonBody(map[string]string{"name": "s-" + strings.ReplaceAll(c.name, " ", "")})
		}
		w := h.do(c.method, c.path, body, c.opts...)
		if w.Code != c.want {
			t.Errorf("%s: %d (atteso %d) %s", c.name, w.Code, c.want, w.Body.String())
		}
	}
}

func TestGuardMinesyncHostsEnv(t *testing.T) {
	t.Setenv("MINESYNC_HOSTS", " Hub.Example.Lan ,myhub")
	h := newHub(t)
	for hst, want := range map[string]int{
		"hub.example.lan":      200,
		"HUB.EXAMPLE.LAN:8084": 200,
		"myhub:8084":           200,
		"altro.lan":            403,
	} {
		if w := h.do("GET", "/api/v1/status", nil, host(hst)); w.Code != want {
			t.Errorf("host %q: %d (atteso %d)", hst, w.Code, want)
		}
	}
}

// S13
func TestSecurityHeaders(t *testing.T) {
	h := newHub(t)
	w := h.do("GET", "/api/v1/status", nil)
	if w.Header().Get("X-Content-Type-Options") != "nosniff" ||
		w.Header().Get("X-Frame-Options") != "DENY" ||
		!strings.Contains(w.Header().Get("Content-Security-Policy"), "frame-ancestors 'none'") {
		t.Fatalf("intestazioni di sicurezza mancanti: %v", w.Header())
	}
	// anche sui 403 del guard
	w = h.do("GET", "/api/v1/status", nil, host("evil.com"))
	if w.Header().Get("X-Frame-Options") != "DENY" {
		t.Fatal("intestazioni mancanti sul 403")
	}
}

// S8: MINESYNC_DEV_USER vale solo da loopback.
func TestDevUserLoopbackOnly(t *testing.T) {
	h := newHub(t)
	h.srv.DevUser = "dev"
	h.srv.ZT = nil
	w := h.do("GET", "/api/v1/whoami", nil, from("127.0.0.1"))
	if w.Code != 200 || decodeJSON[map[string]any](t, w)["name"] != "dev" {
		t.Fatalf("dev da loopback: %d %s", w.Code, w.Body.String())
	}
	if w := h.do("GET", "/api/v1/whoami", nil, from("10.0.0.50")); w.Code != 401 {
		t.Fatalf("dev da IP remoto: %d", w.Code)
	}
	if w := h.do("GET", "/api/v1/whoami", nil, from("::1")); w.Code != 200 {
		t.Fatalf("dev da ::1: %d", w.Code)
	}
}

// --- push via HTTP: C2, C3, C4 ---

func (h *testHub) createSpace(name string) string {
	w := h.do("POST", "/api/v1/spaces", jsonBody(map[string]string{"name": name}), from(ipAdmin))
	if w.Code != 200 {
		h.t.Fatalf("create: %d %s", w.Code, w.Body.String())
	}
	return decodeJSON[store.Space](h.t, w).ID
}

func (h *testHub) lock(id, ip string) string {
	w := h.do("POST", "/api/v1/spaces/"+id+"/lock", jsonBody(map[string]any{"ttlSec": 90}), from(ip))
	if w.Code != 200 {
		h.t.Fatalf("lock: %d %s", w.Code, w.Body.String())
	}
	return decodeJSON[map[string]any](h.t, w)["session"].(string)
}

func TestPushFlowHTTP(t *testing.T) {
	h := newHub(t)
	id := h.createSpace("Mondo")
	content := []byte("level.dat")
	files := map[string]store.FileMeta{"world/level.dat": {Hash: sha(content), Size: int64(len(content))}}
	begin := func(session, query, ip string) *httptest.ResponseRecorder {
		return h.do("POST", "/api/v1/spaces/"+id+"/push/begin"+query,
			jsonBody(map[string]any{"parent": 0, "files": files, "session": session}), from(ip))
	}

	// senza lock: 409; nolock da non admin: 403
	if w := begin("", "", ipMember); w.Code != 409 {
		t.Fatalf("push senza lock: %d %s", w.Code, w.Body.String())
	}
	if w := begin("", "?nolock=1", ipMember); w.Code != 403 {
		t.Fatalf("nolock da membro: %d", w.Code)
	}
	sess := h.lock(id, ipMember)
	if w := begin("sbagliata", "", ipMember); w.Code != 409 {
		t.Fatalf("sessione sbagliata: %d", w.Code)
	}
	w := begin(sess, "", ipMember)
	if w.Code != 200 {
		t.Fatalf("begin: %d %s", w.Code, w.Body.String())
	}
	br := decodeJSON[struct {
		PushID  string   `json:"pushId"`
		Missing []string `json:"missing"`
	}](t, w)
	if len(br.Missing) != 1 {
		t.Fatalf("missing: %v", br.Missing)
	}
	// upload senza header X-MineSync: rifiutato dal guard
	blobURL := fmt.Sprintf("/api/v1/spaces/%s/push/%s/blobs/%s", id, br.PushID, br.Missing[0])
	if w := h.do("PUT", blobURL, rawBody(content), noMineSyncHeader()); w.Code != 403 {
		t.Fatalf("upload senza header: %d", w.Code)
	}
	if w := h.do("PUT", blobURL, rawBody(content)); w.Code != 200 {
		t.Fatalf("upload: %d %s", w.Code, w.Body.String())
	}
	// push sconosciuto: 404
	if w := h.do("PUT", fmt.Sprintf("/api/v1/spaces/%s/push/nope/blobs/%s", id, br.Missing[0]), rawBody(content)); w.Code != 404 {
		t.Fatalf("upload su push sconosciuto: %d", w.Code)
	}
	commitURL := fmt.Sprintf("/api/v1/spaces/%s/push/%s/commit", id, br.PushID)
	w1 := h.do("POST", commitURL, jsonBody(struct{}{}))
	if w1.Code != 200 {
		t.Fatalf("commit: %d %s", w1.Code, w1.Body.String())
	}
	// C3: secondo commit → stessa risposta, nessun nuovo evento
	nEvents := len(h.srv.Bus.Recent(100))
	w2 := h.do("POST", commitURL, jsonBody(struct{}{}))
	if w2.Code != 200 {
		t.Fatalf("commit ripetuto: %d %s", w2.Code, w2.Body.String())
	}
	g1, g2 := decodeJSON[store.GenSummary](t, w1), decodeJSON[store.GenSummary](t, w2)
	if g1.N != 1 || g1.N != g2.N || !g1.TS.Equal(g2.TS) {
		t.Fatalf("commit non idempotente: %+v vs %+v", g1, g2)
	}
	if len(h.srv.Bus.Recent(100)) != nEvents {
		t.Fatal("il commit ripetuto ha pubblicato un altro evento")
	}
	if strings.Contains(w1.Body.String(), `"files":{`) {
		t.Fatal("la risposta del commit include il manifest")
	}
}

func TestMassDeleteHTTP(t *testing.T) {
	h := newHub(t)
	id := h.createSpace("Mondo")
	sess := h.lock(id, ipAdmin)
	files := map[string]store.FileMeta{}
	var blobs [][]byte
	for i := 0; i < 25; i++ {
		b := []byte(fmt.Sprintf("file %d", i))
		blobs = append(blobs, b)
		files[fmt.Sprintf("f%d", i)] = store.FileMeta{Hash: sha(b), Size: int64(len(b))}
	}
	w := h.do("POST", "/api/v1/spaces/"+id+"/push/begin",
		jsonBody(map[string]any{"parent": 0, "files": files, "session": sess}), from(ipAdmin))
	br := decodeJSON[map[string]any](t, w)
	pid := br["pushId"].(string)
	for _, b := range blobs {
		h.do("PUT", fmt.Sprintf("/api/v1/spaces/%s/push/%s/blobs/%s", id, pid, sha(b)), rawBody(b), from(ipAdmin))
	}
	if w := h.do("POST", "/api/v1/spaces/"+id+"/push/"+pid+"/commit", jsonBody(struct{}{}), from(ipAdmin)); w.Code != 200 {
		t.Fatalf("commit: %d %s", w.Code, w.Body.String())
	}
	empty := map[string]any{"parent": 1, "files": map[string]any{}, "session": sess}
	w = h.do("POST", "/api/v1/spaces/"+id+"/push/begin", jsonBody(empty), from(ipAdmin))
	if w.Code != 409 || decodeJSON[map[string]any](t, w)["code"] != "mass_delete" {
		t.Fatalf("mass delete: %d %s", w.Code, w.Body.String())
	}
	if w := h.do("POST", "/api/v1/spaces/"+id+"/push/begin?allowMassDelete=1", jsonBody(empty), from(ipAdmin)); w.Code != 200 {
		t.Fatalf("allowMassDelete admin: %d %s", w.Code, w.Body.String())
	}
	if w := h.do("POST", "/api/v1/spaces/"+id+"/push/begin?allowMassDelete=1", jsonBody(empty), from(ipMember)); w.Code != 403 {
		t.Fatalf("allowMassDelete da membro: %d", w.Code)
	}
}

// D14
func TestGCKeepValidation(t *testing.T) {
	h := newHub(t)
	id := h.createSpace("Mondo")
	for _, q := range []string{"abc", "0", "-3", ""} {
		w := h.do("POST", "/api/v1/spaces/"+id+"/gc?keep="+q, nil, from(ipAdmin))
		want := 400
		if q == "" {
			want = 200
		}
		if w.Code != want {
			t.Errorf("keep=%q: %d (atteso %d) %s", q, w.Code, want, w.Body.String())
		}
	}
}

// C2: force-release solo admin, tranne per i lock stale.
func TestForceReleaseAdminOnly(t *testing.T) {
	h := newHub(t)
	id := h.createSpace("Mondo")
	h.lock(id, ipMember)
	if w := h.do("DELETE", "/api/v1/spaces/"+id+"/lock?force=1", nil, from(ipOther)); w.Code != 403 {
		t.Fatalf("force da membro su lock vivo: %d %s", w.Code, w.Body.String())
	}
	if w := h.do("DELETE", "/api/v1/spaces/"+id+"/lock?force=1", nil, from(ipAdmin)); w.Code != 200 {
		t.Fatalf("force da admin: %d %s", w.Code, w.Body.String())
	}
	// lock stale: lo libera chiunque
	if _, _, err := h.srvStore().AcquireLock(id, "steve", nil, 1); err != nil {
		t.Fatal(err)
	}
	time.Sleep(1100 * time.Millisecond)
	if w := h.do("DELETE", "/api/v1/spaces/"+id+"/lock?force=1", nil, from(ipOther)); w.Code != 200 {
		t.Fatalf("rilascio di lock stale da membro: %d %s", w.Code, w.Body.String())
	}
}

// D12: export con blob mancante → 409 prima di scrivere lo zip.
func TestExportMissingBlob(t *testing.T) {
	h := newHub(t)
	id := h.createSpace("Mondo")
	st := h.srvStore()
	a, b := []byte("aaa"), []byte("bbb")
	man := store.Manifest{"a": {Hash: sha(a), Size: 3}, "b": {Hash: sha(b), Size: 3}}
	pid, _, err := st.BeginPush(id, store.PushOptions{Author: "alex", Files: man, NoLock: true})
	if err != nil {
		t.Fatal(err)
	}
	st.PushBlob(id, pid, sha(a), bytes.NewReader(a), false)
	st.PushBlob(id, pid, sha(b), bytes.NewReader(b), false)
	if _, _, err := st.CommitPush(id, pid); err != nil {
		t.Fatal(err)
	}
	if w := h.do("GET", "/api/v1/spaces/"+id+"/generations/1/zip", nil); w.Code != 200 ||
		w.Header().Get("Content-Type") != "application/zip" {
		t.Fatalf("export integro: %d", w.Code)
	}
	// via un blob
	matches, _ := filepath.Glob(filepath.Join(h.srv.DataDir, "spaces", id, "blobs", sha(b)[:2], sha(b)+"*"))
	for _, m := range matches {
		os.Remove(m)
	}
	w := h.do("GET", "/api/v1/spaces/"+id+"/generations/1/zip", nil)
	if w.Code != 409 || w.Header().Get("Content-Type") == "application/zip" {
		t.Fatalf("export con blob mancante: %d %s", w.Code, w.Header().Get("Content-Type"))
	}
}

// C6: SHA256SUMS servito ma non elencato.
func TestDLChecksumsHidden(t *testing.T) {
	h := newHub(t)
	os.MkdirAll(h.srv.DLDir, 0o755)
	os.WriteFile(filepath.Join(h.srv.DLDir, "minesync-linux-amd64"), []byte("ELF"), 0o644)
	os.WriteFile(filepath.Join(h.srv.DLDir, "SHA256SUMS"), []byte("abc  minesync-linux-amd64\n"), 0o644)
	os.WriteFile(filepath.Join(h.srv.DLDir, "SHA256SUMS.sig"), []byte("c2ln"), 0o644)
	w := h.do("GET", "/api/v1/dl", nil)
	if strings.Contains(w.Body.String(), "SHA256SUMS") || !strings.Contains(w.Body.String(), "minesync-linux-amd64") {
		t.Fatalf("elenco dl: %s", w.Body.String())
	}
	if w := h.do("GET", "/dl", nil); strings.Contains(w.Body.String(), "SHA256SUMS") {
		t.Fatal("SHA256SUMS nella pagina /dl")
	}
	for _, f := range []string{"SHA256SUMS", "SHA256SUMS.sig"} {
		w := h.do("GET", "/dl/"+f, nil, noMineSyncHeader())
		if w.Code != 200 || strings.Contains(w.Header().Get("Content-Disposition"), "minesync") {
			t.Fatalf("/dl/%s: %d %v", f, w.Code, w.Header())
		}
	}
	w = h.do("GET", "/dl/minesync-linux-amd64", nil, noMineSyncHeader())
	if w.Code != 200 || !strings.Contains(w.Header().Get("Content-Disposition"), "filename=minesync") {
		t.Fatalf("binario: %d %v", w.Code, w.Header())
	}
}

// Il 401 non deve parlare di password o token.
func TestUnauthenticatedMessage(t *testing.T) {
	h := newHub(t)
	w := h.do("GET", "/api/v1/whoami", nil, from("192.168.9.9"))
	if w.Code != 401 || strings.Contains(w.Body.String(), "password") {
		t.Fatalf("401: %d %s", w.Code, w.Body.String())
	}
}
