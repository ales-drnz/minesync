package i18n

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"
)

// translators: funzioni che traducono, con l'indice dell'argomento id.
// Chiamate qualificate dal pacchetto i18n…
var pkgFuncs = map[string]int{"T": 1, "Tf": 1, "L": 0, "Lf": 0, "Errorf": 0, "M": 0}

// …metodi/funzioni locali che passano l'id a i18n (bot Telegram, risposte API).
var localFuncs = map[string]int{"tr": 0, "trf": 0, "jsonError": 3}

// constString valuta un letterale stringa (anche concatenato con +).
func constString(e ast.Expr) (string, bool) {
	switch x := e.(type) {
	case *ast.BasicLit:
		if x.Kind != token.STRING {
			return "", false
		}
		s, err := strconv.Unquote(x.Value)
		return s, err == nil
	case *ast.BinaryExpr:
		if x.Op != token.ADD {
			return "", false
		}
		a, ok1 := constString(x.X)
		b, ok2 := constString(x.Y)
		return a + b, ok1 && ok2
	case *ast.ParenExpr:
		return constString(x.X)
	}
	return "", false
}

// usedIDs raccoglie tutti gli id passati alle funzioni di traduzione nei
// sorgenti (non di test) del modulo, fuori da questo pacchetto.
func usedIDs(t *testing.T) map[string]string {
	t.Helper()
	root := filepath.Join("..", "..")
	ids := map[string]string{}
	fset := token.NewFileSet()
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if path != root && (d.Name() == "i18n" || d.Name() == "static" || strings.HasPrefix(d.Name(), ".")) {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		f, err := parser.ParseFile(fset, path, nil, 0)
		if err != nil {
			return err
		}
		ast.Inspect(f, func(n ast.Node) bool {
			// il corpo dei wrapper passa un id variabile: è lecito
			if fd, ok := n.(*ast.FuncDecl); ok {
				_, wrapper := localFuncs[fd.Name.Name]
				return !wrapper
			}
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			idx := -1
			switch fn := call.Fun.(type) {
			case *ast.SelectorExpr:
				if pkg, ok := fn.X.(*ast.Ident); ok && pkg.Name == "i18n" {
					if i, ok := pkgFuncs[fn.Sel.Name]; ok {
						idx = i
					}
				} else if i, ok := localFuncs[fn.Sel.Name]; ok {
					idx = i
				}
			case *ast.Ident:
				if i, ok := localFuncs[fn.Name]; ok {
					idx = i
				}
			}
			if idx < 0 {
				return true
			}
			pos := fset.Position(call.Pos()).String()
			if len(call.Args) <= idx {
				t.Errorf("%s: chiamata senza id", pos)
				return true
			}
			s, ok := constString(call.Args[idx])
			if !ok {
				t.Errorf("%s: l'id del messaggio deve essere un letterale stringa", pos)
				return true
			}
			ids[s] = pos
			return true
		})
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return ids
}

func TestCatalogCoverage(t *testing.T) {
	ids := usedIDs(t)
	if len(ids) < 50 {
		t.Fatalf("trovati solo %d id: lo scanner non funziona?", len(ids))
	}
	var missing []string
	for id, pos := range ids {
		if _, ok := catalogEN[id]; !ok {
			missing = append(missing, strconv.Quote(id)+": \"\", // "+pos)
		}
	}
	slices.Sort(missing)
	if len(missing) > 0 {
		t.Errorf("%d id senza traduzione inglese:\n%s", len(missing), strings.Join(missing, "\n"))
	}
	for id := range catalogEN {
		if _, ok := ids[id]; !ok {
			t.Errorf("voce di catalogo non più usata: %q", id)
		}
	}
}

var verbRE = regexp.MustCompile(`%[-+# 0]*(\[\d+\])?\d*(\.\d+)?[a-zA-Z%]`)

func verbs(s string) []string {
	var out []string
	for _, v := range verbRE.FindAllString(s, -1) {
		if v != "%%" {
			out = append(out, v)
		}
	}
	return out
}

func TestCatalogVerbs(t *testing.T) {
	for id, en := range catalogEN {
		if en == "" {
			t.Errorf("traduzione vuota per %q", id)
			continue
		}
		if a, b := verbs(id), verbs(en); !slices.Equal(a, b) {
			t.Errorf("verbi diversi:\n  it %q %v\n  en %q %v", id, a, en, b)
		}
	}
}
