package api

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// C1: ogni richiesta porta X-MineSync, anche upload e download dei blob.
func TestHeaderXMineSyncOvunque(t *testing.T) {
	var missing []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-MineSync") == "" {
			missing = append(missing, r.Method+" "+r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{}`))
	}))
	defer srv.Close()
	c := New(srv.URL)
	ctx := context.Background()
	c.Status(ctx)
	c.LockRelease(ctx, "sp", "s", false)
	c.PushBegin(ctx, "sp", 1, "m", Manifest{}, nil, "s", false)
	c.UploadBlob(ctx, "sp", "p", "h", strings.NewReader("x"), 1, false)
	if body, _, err := c.DownloadBlob(ctx, "sp", "h"); err == nil {
		body.Close()
	}
	if len(missing) > 0 {
		t.Errorf("richieste senza X-MineSync: %v", missing)
	}
}

// R1: un hub che accetta l'upload ma non risponde mai non blocca il client.
func TestWatchdogUploadFermo(t *testing.T) {
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	defer srv.Close()
	defer close(release)
	c := New(srv.URL)
	c.IdleTimeout = 50 * time.Millisecond
	start := time.Now()
	err := c.UploadBlob(context.Background(), "sp", "p", "h", bytes.NewReader(make([]byte, 1024)), 1024, false)
	if !errors.Is(err, ErrStalled) {
		t.Fatalf("errore = %v, atteso ErrStalled", err)
	}
	if el := time.Since(start); el > 5*time.Second {
		t.Errorf("il watchdog ci ha messo %s", el)
	}
}

func TestIsLockLost(t *testing.T) {
	cases := []struct {
		err  error
		want bool
	}{
		{&APIError{Status: 409, Msg: "conflitto: lock non tuo o già rilasciato"}, true},
		{&APIError{Status: 409, Msg: "spazio lockato", Holder: &LockInfo{Owner: "bob"}}, true},
		{&APIError{Status: 409, Msg: "conflitto: push senza lock (acquisisci il lock)"}, true},
		{&APIError{Status: 409, Msg: "conflitto: parent 3 ma HEAD è 4"}, false},
		{&APIError{Status: 409, Msg: "troppi file rimossi", Code: "mass_delete"}, false},
		{&APIError{Status: 500, Msg: "lock"}, false},
		{errors.New("lock"), false},
	}
	for _, c := range cases {
		if got := IsLockLost(c.err); got != c.want {
			t.Errorf("IsLockLost(%v) = %v, atteso %v", c.err, got, c.want)
		}
	}
}
