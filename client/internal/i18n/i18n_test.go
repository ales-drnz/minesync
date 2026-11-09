package i18n

import (
	"errors"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"sort"
	"strconv"
	"strings"
	"testing"
)

func TestParse(t *testing.T) {
	cases := map[string]Lang{
		"it": IT, "it_IT.UTF-8": IT, "it-IT": IT, "IT": IT, "it_CH@euro": IT,
		"en": EN, "en_US.UTF-8": EN, "en-US,en;q=0.9": EN, "en-GB": EN,
		"fr-FR,it;q=0.8,en;q=0.5": IT, "de:en": EN, ` "it-IT"`: IT,
	}
	for in, want := range cases {
		if got, ok := Parse(in); !ok || got != want {
			t.Errorf("Parse(%q) = %q,%v; want %q", in, got, ok, want)
		}
	}
	for _, in := range []string{"", "C", "POSIX", "C.UTF-8", "fr_FR.UTF-8", "de-DE,fr;q=0.9"} {
		if got, ok := Parse(in); ok {
			t.Errorf("Parse(%q) = %q; want no match", in, got)
		}
	}
}

func TestParseAppleLanguages(t *testing.T) {
	if l, ok := parseAppleLanguages("(\n    \"fr-FR\",\n    \"it-IT\",\n    \"en-US\"\n)\n"); !ok || l != IT {
		t.Errorf("got %q %v", l, ok)
	}
	if _, ok := parseAppleLanguages("(\n    \"de-DE\"\n)\n"); ok {
		t.Error("nessuna lingua supportata")
	}
}

func TestResolveOrder(t *testing.T) {
	t.Setenv("LC_ALL", "")
	t.Setenv("LC_MESSAGES", "")
	t.Setenv("LANG", "it_IT.UTF-8")
	t.Setenv(EnvVar, "en")
	if got := Resolve("it"); got != EN {
		t.Errorf("env MINESYNC_LANG deve vincere: %q", got)
	}
	t.Setenv(EnvVar, "")
	if got := Resolve("en"); got != EN {
		t.Errorf("la config deve vincere sul sistema: %q", got)
	}
	if got := Resolve(""); got != IT && osDetectsFromEnv {
		t.Errorf("con config automatica conta il sistema (LANG=it): %q", got)
	}
	t.Setenv("LANG", "C")
	if got := Resolve(""); got != EN && osDetectsFromEnv {
		t.Errorf("fallback inglese: %q", got)
	}
}

func TestTranslate(t *testing.T) {
	defer Set(Current())
	id := "Nessuno spazio. Creane uno con `minesync create <nome>`."
	Set(IT)
	if S(id) != id {
		t.Errorf("in italiano l'id resta com'è")
	}
	Set(EN)
	if S(id) == id || !strings.Contains(S(id), "minesync create") {
		t.Errorf("manca la traduzione inglese: %q", S(id))
	}
	if T(EN, "testo senza traduzione") != "testo senza traduzione" {
		t.Error("fallback all'id")
	}
	err := NewError("lock perso")
	Set(IT)
	if err.Error() != "lock perso" {
		t.Error(err)
	}
	Set(EN)
	if err.Error() != "lock lost" {
		t.Errorf("errore sentinella pigro: %q", err.Error())
	}
	wrapped := Errorf("pull fallito: %w", err)
	if !errors.Is(wrapped, err) || !strings.HasPrefix(wrapped.Error(), "pull failed") {
		t.Errorf("Errorf: %v", wrapped)
	}
}

var verbRe = regexp.MustCompile(`%[-+# 0]*(\[\d+\])?(\d+|\*)?(\.(\d+|\*))?[a-zA-Z%]`)

func verbs(s string) []string { return verbRe.FindAllString(s, -1) }

// TestCatalogVerbs: traduzione e id devono avere gli stessi verbi di
// formato, nello stesso ordine.
func TestCatalogVerbs(t *testing.T) {
	for id, en := range catalogEN {
		if a, b := verbs(id), verbs(en); !slices.Equal(a, b) {
			t.Errorf("verbi diversi\n  it %q %v\n  en %q %v", id, a, en, b)
		}
		if strings.TrimSpace(en) == "" {
			t.Errorf("traduzione vuota per %q", id)
		}
	}
}

// funcs: funzioni di traduzione e indice dell'argomento con l'id.
var funcs = map[string]int{"T": 1, "Tf": 1, "S": 0, "Sf": 0, "Errorf": 0, "NewError": 0}

// literal valuta un letterale stringa (anche concatenato con +).
func literal(e ast.Expr) (string, bool) {
	switch e := e.(type) {
	case *ast.BasicLit:
		if e.Kind != token.STRING {
			return "", false
		}
		s, err := strconv.Unquote(e.Value)
		return s, err == nil
	case *ast.ParenExpr:
		return literal(e.X)
	case *ast.BinaryExpr:
		if e.Op != token.ADD {
			return "", false
		}
		a, ok1 := literal(e.X)
		b, ok2 := literal(e.Y)
		return a + b, ok1 && ok2
	}
	return "", false
}

// TestCatalogCoverage: ogni chiamata a una funzione di traduzione nel modulo
// ha un letterale come id, ogni id ha la sua traduzione inglese e il catalogo
// non contiene voci che nessuno usa più.
func TestCatalogCoverage(t *testing.T) {
	root, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "go.mod")); err != nil {
		t.Fatalf("radice del modulo non trovata in %s", root)
	}
	used := map[string]bool{}
	var missing []string
	fset := token.NewFileSet()
	filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if n := d.Name(); n == "testdata" || n == "vendor" || (strings.HasPrefix(n, ".") && path != root) {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		f, err := parser.ParseFile(fset, path, nil, 0)
		if err != nil {
			t.Errorf("%s: %v", path, err)
			return nil
		}
		ast.Inspect(f, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			sel, ok := call.Fun.(*ast.SelectorExpr)
			if !ok {
				return true
			}
			pkg, ok := sel.X.(*ast.Ident)
			idx, known := funcs[sel.Sel.Name]
			if !ok || pkg.Name != "i18n" || !known {
				return true
			}
			pos := fset.Position(call.Pos())
			if len(call.Args) <= idx {
				t.Errorf("%s: chiamata senza id", pos)
				return true
			}
			id, ok := literal(call.Args[idx])
			if !ok {
				t.Errorf("%s: i18n.%s vuole un letterale stringa come id", pos, sel.Sel.Name)
				return true
			}
			used[id] = true
			if _, ok := catalogEN[id]; !ok {
				missing = append(missing, id)
			}
			return true
		})
		return nil
	})
	sort.Strings(missing)
	missing = slices.Compact(missing)
	for _, id := range missing {
		t.Errorf("manca la traduzione inglese:\n%s", strconv.Quote(id))
	}
	var unused []string
	for id := range catalogEN {
		if !used[id] && !internalIDs[id] {
			unused = append(unused, id)
		}
	}
	sort.Strings(unused)
	for _, id := range unused {
		t.Errorf("voce di catalogo non più usata: %q", id)
	}
	if len(used) < 50 {
		t.Errorf("trovate solo %d chiamate: il test non sta guardando il modulo giusto?", len(used))
	}
	if testing.Verbose() {
		fmt.Printf("catalogo: %d voci, %d id usati\n", len(catalogEN), len(used))
	}
}

// osDetectsFromEnv: su linux/bsd la lingua di sistema viene solo dalle
// variabili di locale (su Windows e macOS c'è anche l'API di sistema).
var osDetectsFromEnv = runtime.GOOS != "windows" && runtime.GOOS != "darwin"

// internalIDs: id usati solo da questo pacchetto (nei test).
var internalIDs = map[string]bool{}

func TestSingolareEN(t *testing.T) {
	cases := map[string]string{
		"1 files downloaded":     "1 file downloaded",
		"Push complete: 1 blobs": "Push complete: 1 blob",
		"11 files":               "11 files",
		"0/1 files":              "0/1 files",
		"generation #1, 2 files": "generation #1, 2 files",
		"2.1 files":              "2.1 files",
		"1 generations · 3 MB":   "1 generation · 3 MB",
	}
	for in, want := range cases {
		if got := singolareEN(in); got != want {
			t.Errorf("%q → %q, atteso %q", in, got, want)
		}
	}
}
