package api

import (
	"fmt"
	"html"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"minesync/server/internal/i18n"
)

// --- download client (pubblico) ---

var dlLabels = []struct{ prefix, label string }{
	{"minesync-windows", "Windows"},
	{"minesync-linux", "Linux"},
	{"minesync-darwin", "macOS (Apple Silicon)"},
}

func (s *Server) dlFiles() []string {
	entries, err := os.ReadDir(s.DLDir)
	if err != nil {
		return nil
	}
	// solo i binari: SHA256SUMS e la firma si scaricano da /dl/<nome> (li usa
	// il self-update) ma non sono bottoni per gli utenti
	var out []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasPrefix(e.Name(), "minesync-") && !isChecksumFile(e.Name()) {
			out = append(out, e.Name())
		}
	}
	sort.Strings(out)
	return out
}

// handleDLList: elenco dei binari per il tab "Client" della web UI.
func (s *Server) handleDLList(_ http.ResponseWriter, _ *http.Request, _ Identity) (any, error) {
	files := s.dlFiles()
	out := make([]map[string]any, 0, len(files))
	for _, f := range files {
		size := int64(0)
		if fi, err := os.Stat(filepath.Join(s.DLDir, f)); err == nil {
			size = fi.Size()
		}
		out = append(out, map[string]any{"name": f, "size": size})
	}
	return map[string]any{"files": out, "version": Version}, nil
}

func (s *Server) handleDLPage(w http.ResponseWriter, r *http.Request) {
	lang := reqLang(r)
	files := s.dlFiles()
	var rows strings.Builder
	for _, f := range files {
		label := f
		for _, dl := range dlLabels {
			if strings.HasPrefix(f, dl.prefix) {
				label = dl.label
				break
			}
		}
		fmt.Fprintf(&rows, `<a class="btn" href="/dl/%s" download><span class="os">%s</span><span class="get">%s</span></a>`,
			html.EscapeString(f), html.EscapeString(label), i18n.T(lang, "Scarica"))
	}
	if len(files) == 0 {
		rows.WriteString(`<p class="muted">` + html.EscapeString(i18n.T(lang, "Nessun binario disponibile sull'hub.")) + `</p>`)
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Language", string(lang))
	w.Header().Add("Vary", "Accept-Language")
	// i testi tradotti sono fidati (catalogo): l'HTML (<code>, <b>) è voluto
	fmt.Fprintf(w, dlPageHTML, lang, i18n.T(lang, "Scarica MineSync"),
		i18n.T(lang, "Il client per giocare ai server dell'hub."), rows.String(),
		i18n.T(lang, "Avvialo. Su Linux e macOS prima <code>chmod +x minesync</code>."),
		i18n.T(lang, "Conferma l'indirizzo dell'hub, scegli il server e premi <b>G</b>."),
		i18n.T(lang, "Requisiti: rete ZeroTier e Java nel PATH."))
}

func (s *Server) handleDLFile(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("file")
	if strings.Contains(name, "/") || strings.Contains(name, "\\") || strings.Contains(name, "..") {
		jsonError(w, r, http.StatusBadRequest, "nome non valido")
		return
	}
	path := filepath.Join(s.DLDir, name)
	if fi, err := os.Stat(path); err != nil || !fi.Mode().IsRegular() {
		jsonError(w, r, http.StatusNotFound, "file non trovato")
		return
	}
	if isChecksumFile(name) {
		// SHA256SUMS / SHA256SUMS.sig: testo, col loro nome
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
		http.ServeFile(w, r, path)
		return
	}
	// il binario scaricato si chiama semplicemente "minesync", senza suffissi
	friendly := "minesync"
	if strings.HasSuffix(name, ".exe") {
		friendly = "minesync.exe"
	}
	w.Header().Set("Content-Disposition", "attachment; filename="+friendly)
	http.ServeFile(w, r, path)
}

// isChecksumFile: i file di verifica del self-update (C6).
func isChecksumFile(name string) bool {
	return name == "SHA256SUMS" || name == "SHA256SUMS.sig"
}

// Pagina /dl allineata al tema della web UI: carbone, verde Minecraft, titolo
// pixel, bottoni squadrati con bevel. Segue prefers-color-scheme come l'app.
const dlPageHTML = `<!doctype html>
<html lang="%s"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>%s</title>
<link rel="icon" href="data:image/svg+xml,%%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%%3E%%3Crect width='24' height='24' rx='5' fill='%%233c8527'/%%3E%%3Cg fill='none' stroke='white' stroke-width='2' stroke-linecap='round' stroke-linejoin='round' transform='translate(3.6 3.6) scale(0.7)'%%3E%%3Cpath d='M12 2 20.66 7 20.66 17 12 22 3.34 17 3.34 7Z'/%%3E%%3Cpath d='m3.34 7 8.66 5 8.66-5'/%%3E%%3Cpath d='M12 12v10'/%%3E%%3C/g%%3E%%3C/svg%%3E">
<style>
@font-face{font-family:"Pixel";src:url("/pixel.woff2") format("woff2");font-display:swap}
:root{--bg:#161617;--card:#1e1e1f;--card2:#262628;--line:#313235;--line2:#48494b;
  --text:#fff;--muted:#9d9da0;--faint:#58585c;--green:#3c8527;--green-hi:#4ca933;--green-txt:#6cc349;--green-dim:rgba(76,169,51,.14)}
@media (prefers-color-scheme: light){:root{--bg:#efefef;--card:#fff;--card2:#f4f4f4;--line:#d9d9d9;--line2:#bdbdbd;
  --text:#1e1e1f;--muted:#5d5d60;--faint:#9d9da0;--green-txt:#2f7b1c;--green-dim:rgba(60,133,39,.12)}}
*{box-sizing:border-box;margin:0}
body{background:var(--bg);color:var(--text);font:15px/1.55 "Noto Sans","Segoe UI",system-ui,sans-serif;
  display:flex;min-height:100vh;align-items:center;justify-content:center;padding:24px}
.card{max-width:440px;width:100%%;text-align:center}
.logo{width:60px;height:60px;border-radius:10px;display:inline-grid;place-items:center;background:var(--green);color:#fff;margin-bottom:14px}
h1{font-family:"Pixel",monospace;font-weight:400;font-size:22px;letter-spacing:1px;text-transform:uppercase;margin-bottom:6px}
.muted{color:var(--muted);font-size:14px}
.list{margin:26px 0 8px;display:flex;flex-direction:column;gap:10px}
.btn{display:flex;align-items:center;justify-content:space-between;gap:12px;text-decoration:none;
  background:var(--card);border:1px solid var(--line);border-radius:3px;padding:14px 18px;transition:border-color .12s,background .12s}
.btn:hover{border-color:var(--green-hi);background:var(--card2)}
.btn .os{font-family:"Pixel",monospace;font-size:12px;letter-spacing:.5px;color:var(--text)}
.btn .get{font-size:11px;font-weight:800;text-transform:uppercase;letter-spacing:.07em;color:#fff;background:var(--green);
  border:1px solid var(--green-hi);border-radius:3px;padding:7px 14px;box-shadow:inset 0 -3px 0 rgba(0,0,0,.28)}
ol{text-align:left;color:var(--muted);font-size:13.5px;margin:22px auto 0;max-width:380px;padding-left:20px}
ol li{margin:7px 0}ol b{color:var(--text)}
code{font-family:"Cascadia Code",Consolas,monospace;background:var(--card2);border:1px solid var(--line);
  border-radius:3px;padding:1px 7px;font-size:12.5px;color:var(--green-txt)}
</style></head><body><div class="card">
<div class="logo"><svg width="34" height="34" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2 20.66 7 20.66 17 12 22 3.34 17 3.34 7Z"/><path d="m3.34 7 8.66 5 8.66-5"/><path d="M12 12v10"/></svg></div>
<h1>MineSync</h1>
<p class="muted">%s</p>
<div class="list">%s</div>
<ol>
<li>%s</li>
<li>%s</li>
<li>%s</li>
</ol>
</div></body></html>`
