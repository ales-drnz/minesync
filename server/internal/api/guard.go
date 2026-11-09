package api

import (
	"net"
	"net/http"
	"os"
	"strings"
)

// contentSecurityPolicy è compatibile con la web UI statica: nessuno script
// inline (app.js è esterno), ma stili inline sì (attributi style creati da
// app.js e <style> della pagina /dl). Immagini data: per la favicon.
const contentSecurityPolicy = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; " +
	"img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; " +
	"base-uri 'none'; form-action 'self'; frame-ancestors 'none'"

// securityHeaders aggiunge le intestazioni difensive a ogni risposta.
func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Content-Security-Policy", contentSecurityPolicy)
		h.Set("Referrer-Policy", "no-referrer")
		next.ServeHTTP(w, r)
	})
}

// guard difende da CSRF e DNS rebinding. L'autenticazione è per IP, quindi
// una pagina malevola aperta da un membro potrebbe usarne l'autorità:
//   - Host in allow-list su ogni rotta (un dominio dell'attaccante che
//     risolve sull'hub non passa);
//   - sulle /api/: niente richieste cross-site, e ogni mutazione deve avere
//     l'header X-MineSync (che un form o una simple request non possono
//     mettere senza preflight CORS, che l'hub non concede).
func (s *Server) guard(next http.Handler) http.Handler {
	extra := map[string]bool{}
	for _, list := range [][]string{s.AllowedHosts, strings.Split(os.Getenv("MINESYNC_HOSTS"), ",")} {
		for _, h := range list {
			if h = normHost(h); h != "" {
				extra[h] = true
			}
		}
	}
	zone := strings.ToLower(strings.Trim(s.DNSZone, "."))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !hostAllowed(r.Host, zone, extra) {
			jsonError(w, r, http.StatusForbidden, "host non ammesso (aggiungilo a MINESYNC_HOSTS)")
			return
		}
		if strings.HasPrefix(r.URL.Path, "/api/") {
			if r.Header.Get("Sec-Fetch-Site") == "cross-site" {
				jsonError(w, r, http.StatusForbidden, "richiesta cross-site rifiutata")
				return
			}
			if r.Method != http.MethodGet && r.Method != http.MethodHead && r.Header.Get("X-MineSync") == "" {
				jsonError(w, r, http.StatusForbidden, "header X-MineSync mancante")
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

// normHost: minuscolo, senza porta, parentesi IPv6 e punto finale.
func normHost(h string) string {
	h = strings.TrimSpace(h)
	if hh, _, err := net.SplitHostPort(h); err == nil {
		h = hh
	}
	h = strings.Trim(h, "[]")
	return strings.TrimSuffix(strings.ToLower(h), ".")
}

func hostAllowed(raw, zone string, extra map[string]bool) bool {
	h := normHost(raw)
	if h == "" {
		return false
	}
	ipPart, _, _ := strings.Cut(h, "%") // zona IPv6 (fe80::1%eth0)
	if net.ParseIP(ipPart) != nil {
		return true
	}
	if h == "localhost" || strings.HasSuffix(h, ".localhost") || extra[h] {
		return true
	}
	return zone != "" && (h == zone || strings.HasSuffix(h, "."+zone))
}
