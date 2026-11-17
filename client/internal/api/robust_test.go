package api

import (
	"compress/gzip"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// G: un proxy HTTP di sistema non deve mettersi in mezzo tra noi e l'hub
// (l'hub ci riconosce dall'IP ZeroTier). MINESYNC_USE_PROXY=1 lo riattiva.
func TestProxyDiSistemaIgnorato(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"name":"hub"}`))
	}))
	defer srv.Close()
	t.Setenv("HTTP_PROXY", "http://127.0.0.1:1") // proxy inesistente
	t.Setenv("http_proxy", "http://127.0.0.1:1")
	t.Setenv("NO_PROXY", "")
	t.Setenv("MINESYNC_USE_PROXY", "")
	if _, err := New(srv.URL).Status(context.Background()); err != nil {
		t.Fatalf("la richiesta è passata dal proxy: %v", err)
	}
	t.Setenv("MINESYNC_USE_PROXY", "1")
	if hubProxy() == nil {
		t.Error("MINESYNC_USE_PROXY=1 non riattiva il proxy")
	}
}

// C6: push/begin compresso, con parentDigest; un hub vecchio che risponde
// 400 senza codice riceve di nuovo la richiesta in chiaro.
func TestBeginGzipEFallback(t *testing.T) {
	var encs []string
	var parent string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		encs = append(encs, r.Header.Get("Content-Encoding"))
		var body io.Reader = r.Body
		if r.Header.Get("Content-Encoding") == "gzip" {
			zr, err := gzip.NewReader(r.Body)
			if err != nil {
				t.Error(err)
				return
			}
			body = zr
		}
		var req map[string]any
		json.NewDecoder(body).Decode(&req)
		parent, _ = req["parentDigest"].(string)
		if len(encs) == 1 && strings.Contains(r.URL.RawQuery, "old") {
			w.WriteHeader(400)
			w.Write([]byte(`{"error":"json non valido"}`))
			return
		}
		w.Write([]byte(`{"pushId":"p1","missing":[]}`))
	}))
	defer srv.Close()
	c := New(srv.URL)
	out, err := c.BeginPush(context.Background(), "sp", PushBeginReq{Parent: 3, ParentDigest: "abc", Files: Manifest{}})
	if err != nil || out.PushID != "p1" || len(encs) != 1 || encs[0] != "gzip" || parent != "abc" {
		t.Fatalf("out=%+v err=%v encs=%v parent=%q", out, err, encs, parent)
	}
	encs = nil
	if _, err := c.BeginPush(context.Background(), "sp?old=1&x", PushBeginReq{}); err != nil || len(encs) != 2 || encs[1] != "" {
		t.Errorf("fallback in chiaro: err=%v encs=%v", err, encs)
	}
}

// I: codici dell'hub riconosciuti; i conflitti con codice non sono lock persi.
func TestCodiciErrore(t *testing.T) {
	stale := &APIError{Status: 409, Msg: "base diversa (lock ok)", Code: CodeStaleBase}
	if !IsStaleBase(stale) || IsLockLost(stale) {
		t.Error("stale_base")
	}
	full := &APIError{Status: 507, Msg: "disk full", Code: CodeDiskFull}
	if !IsDiskFull(full) || !strings.Contains(full.Error(), "NAS") && !strings.Contains(full.Error(), "disco") {
		t.Errorf("disk_full: %v", full)
	}
	if !IsSpaceGone(&APIError{Status: 404, Code: CodeSpaceGone}) || IsSpaceGone(&APIError{Status: 404, Code: "altro"}) {
		t.Error("space_gone")
	}
	if !IsBadRequest(&APIError{Status: 400}) || IsBadRequest(&APIError{Status: 409}) || IsBadRequest(&APIError{Status: 500}) {
		t.Error("bad request")
	}
	if !IsLockLost(&APIError{Status: 409, Code: CodeLocked}) {
		t.Error("locked")
	}
}
