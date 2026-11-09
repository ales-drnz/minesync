package syncx

import (
	"path"
	"runtime"
	"strings"
)

// Matcher valuta le esclusioni di uno spazio.
//
// Regole (separatore sempre "/"):
//   - "nome", "*.lock" (senza /)  → glob sul nome, a qualunque profondità
//     (equivale a "**/nome");
//   - "a/b.txt", "config/*.bak"   → glob segmento per segmento sul percorso
//     completo;
//   - "**" come segmento intero   → zero o più cartelle: "**/logs/**" esclude
//     ogni cartella logs a qualunque profondità, "world_backup*/**" ogni
//     cartella che inizia per world_backup e tutto quello che contiene.
//
// Ogni segmento è un glob di path.Match: "world_backup*/**" funziona come ci
// si aspetta (prima il prefisso era confrontato alla lettera e il default non
// escludeva mai niente). Su Windows il confronto ignora le maiuscole, come il
// filesystem.
//
// Un file è escluso se un pattern combacia col suo percorso, oppure se una
// delle sue cartelle è esclusa (MatchDir): così la scansione, che pota le
// cartelle, e il confronto col manifest remoto, che vede solo file, danno
// sempre la stessa risposta.
type Matcher struct {
	pats []pattern
	fold bool // confronto senza maiuscole (Windows)
}

type pattern struct {
	segs []string
	// prune: il pattern può escludere un'intera cartella. Vale per i pattern
	// che finiscono in "/**" e per i nomi esatti senza caratteri jolly
	// ("node_modules"); un glob sul nome come "*.lock" esclude solo file,
	// non una cartella che per caso si chiama x.lock.
	prune bool
}

// NewMatcher compila le esclusioni (righe vuote e commenti "#" ignorati).
func NewMatcher(patterns []string) *Matcher {
	return newMatcher(patterns, runtime.GOOS == "windows")
}

func newMatcher(patterns []string, fold bool) *Matcher {
	m := &Matcher{fold: fold}
	for _, p := range patterns {
		p = strings.TrimSpace(strings.ReplaceAll(p, "\\", "/"))
		if p == "" || strings.HasPrefix(p, "#") {
			continue
		}
		p = strings.TrimPrefix(p, "/")
		if fold {
			p = strings.ToLower(p)
		}
		if rest, ok := strings.CutPrefix(p, "**/"); ok && rest != "" && !strings.Contains(rest, "/") {
			p = rest // "**/nome" equivale a "nome"
		}
		pt := pattern{}
		if !strings.Contains(p, "/") {
			// nome semplice: a qualunque profondità
			pt.segs = []string{"**", p}
			pt.prune = !strings.ContainsAny(p, "*?[")
		} else {
			pt.segs = strings.Split(p, "/")
			pt.prune = strings.HasSuffix(p, "/**")
		}
		m.pats = append(m.pats, pt)
	}
	return m
}

func (m *Matcher) norm(rel string) []string {
	rel = strings.Trim(strings.ReplaceAll(rel, "\\", "/"), "/")
	if m.fold {
		rel = strings.ToLower(rel)
	}
	return strings.Split(rel, "/")
}

// Match riporta se il file (percorso relativo, separatore /) è escluso.
func (m *Matcher) Match(rel string) bool {
	if m == nil {
		return false
	}
	segs := m.norm(rel)
	for _, p := range m.pats {
		if globSegs(p.segs, segs) {
			return true
		}
	}
	// una cartella antenata esclusa esclude anche il file
	for i := 1; i < len(segs); i++ {
		if m.matchDirSegs(segs[:i]) {
			return true
		}
	}
	return false
}

// MatchDir riporta se un'intera cartella è esclusa (per potare la walk).
func (m *Matcher) MatchDir(rel string) bool {
	if m == nil {
		return false
	}
	return m.matchDirSegs(m.norm(rel))
}

func (m *Matcher) matchDirSegs(segs []string) bool {
	for _, p := range m.pats {
		if p.prune && globSegs(p.segs, segs) {
			return true
		}
	}
	return false
}

// globSegs confronta un pattern a segmenti con un percorso a segmenti; "**"
// vale zero o più segmenti, gli altri sono glob di path.Match.
func globSegs(pat, segs []string) bool {
	for len(pat) > 0 {
		if pat[0] == "**" {
			// "**" in coda prende tutto (anche niente)
			if len(pat) == 1 {
				return true
			}
			for i := 0; i <= len(segs); i++ {
				if globSegs(pat[1:], segs[i:]) {
					return true
				}
			}
			return false
		}
		if len(segs) == 0 {
			return false
		}
		if ok, _ := path.Match(pat[0], segs[0]); !ok {
			return false
		}
		pat, segs = pat[1:], segs[1:]
	}
	return len(segs) == 0
}
