package api

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"minesync/client/internal/i18n"
)

// Ogni richiesta porta Accept-Language con la lingua corrente, e i messaggi
// d'errore dell'hub (già localizzati da lui) arrivano così come sono.
func TestAcceptLanguageAndHubErrorVerbatim(t *testing.T) {
	defer i18n.Set(i18n.Current())
	var got []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		lang := r.Header.Get("Accept-Language")
		got = append(got, lang)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(409)
		if lang == "en" {
			w.Write([]byte(`{"error":"space locked by bob","holder":{"owner":"bob"}}`))
		} else {
			w.Write([]byte(`{"error":"spazio in uso da bob","holder":{"owner":"bob"}}`))
		}
	}))
	defer srv.Close()
	c := New(srv.URL)
	for _, tc := range []struct {
		lang i18n.Lang
		msg  string
	}{{i18n.EN, "space locked by bob"}, {i18n.IT, "spazio in uso da bob"}} {
		i18n.Set(tc.lang)
		_, err := c.LockAcquire(context.Background(), "x", nil)
		var ae *APIError
		if !errors.As(err, &ae) || ae.Msg != tc.msg || ae.Holder == nil {
			t.Errorf("%s: errore %v", tc.lang, err)
		}
		// anche lo stream eventi e i blob: tutte le richieste passano da req()
		c.DownloadBlob(context.Background(), "x", "h")
	}
	if strings.Join(got, ",") != "en,en,it,it" {
		t.Errorf("Accept-Language inviati: %v", got)
	}
}

// Gli errori di rete (lato client) sono localizzati.
func TestNetworkErrorLocalized(t *testing.T) {
	defer i18n.Set(i18n.Current())
	srv := httptest.NewServer(http.NotFoundHandler())
	url := srv.URL
	srv.Close() // porta chiusa: connessione rifiutata
	c := New(url)
	i18n.Set(i18n.EN)
	if _, err := c.Status(context.Background()); err == nil || !strings.HasPrefix(err.Error(), "hub unreachable: ") {
		t.Errorf("EN: %v", err)
	}
	i18n.Set(i18n.IT)
	if _, err := c.Status(context.Background()); err == nil || !strings.HasPrefix(err.Error(), "hub non raggiungibile: ") {
		t.Errorf("IT: %v", err)
	}
}
