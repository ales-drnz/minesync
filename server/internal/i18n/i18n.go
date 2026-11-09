// Package i18n: testi dell'hub in italiano e inglese, stile gettext.
//
// La stringa italiana è l'id del messaggio; catalogEN la traduce. Gli errori
// dello store si creano con Errorf (come fmt.Errorf) e si traducono solo al
// bordo HTTP con la lingua della richiesta: lo store non sa chi lo chiama.
package i18n

import (
	"errors"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync/atomic"
)

type Lang string

const (
	IT Lang = "it"
	EN Lang = "en"
)

// Parse riconosce "it", "it_IT.UTF-8", "it-IT", "en-US,en;q=0.9"… (conta il
// primo tag). false se non è né italiano né inglese.
func Parse(s string) (Lang, bool) {
	s = strings.TrimSpace(s)
	if i := strings.IndexAny(s, ",;"); i >= 0 {
		s = s[:i]
	}
	s = strings.ToLower(strings.TrimSpace(s))
	if i := strings.IndexAny(s, "-_.@"); i >= 0 {
		s = s[:i]
	}
	switch s {
	case "it":
		return IT, true
	case "en":
		return EN, true
	}
	return "", false
}

// FromAcceptLanguage: il primo tag supportato (q>0) dell'header
// Accept-Language, altrimenti def.
func FromAcceptLanguage(h string, def Lang) Lang {
	for _, part := range strings.Split(h, ",") {
		tag, params, _ := strings.Cut(part, ";")
		if q, ok := strings.CutPrefix(strings.TrimSpace(params), "q="); ok {
			if v, err := strconv.ParseFloat(q, 64); err == nil && v <= 0 {
				continue
			}
		}
		if l, ok := Parse(tag); ok {
			return l
		}
	}
	return def
}

var def atomic.Value // Lang

// Default è la lingua dell'hub (bot Telegram, log): MINESYNC_LANG, poi LANG,
// altrimenti inglese.
func Default() Lang {
	if l, ok := def.Load().(Lang); ok {
		return l
	}
	l := fromEnv()
	def.CompareAndSwap(nil, l)
	return def.Load().(Lang)
}

// SetDefault fissa la lingua dell'hub (test).
func SetDefault(l Lang) { def.Store(l) }

func fromEnv() Lang {
	for _, k := range []string{"MINESYNC_LANG", "LC_ALL", "LC_MESSAGES", "LANG"} {
		if l, ok := Parse(os.Getenv(k)); ok {
			return l
		}
	}
	return EN
}

// T traduce un id (la stringa italiana) nella lingua l.
func T(l Lang, id string) string {
	if l == EN {
		if s, ok := catalogEN[id]; ok {
			return s
		}
	}
	return id
}

// Tf traduce e formatta. Gli argomenti localizzabili (errori di questo
// pacchetto, Text) si rendono nella stessa lingua; %w vale come %v.
func Tf(l Lang, id string, a ...any) string {
	out := fmt.Sprintf(strings.ReplaceAll(T(l, id), "%w", "%v"), localizeArgs(l, a)...)
	if l == EN {
		out = singolareEN(out)
	}
	return out
}

// singolareEN corregge il plurale inglese dopo un "1" isolato ("1 files" →
// "1 file"): i messaggi hanno un solo testo per tutti i numeri.
var reOneEN = regexp.MustCompile(`(^|[^0-9./,])1 (file|blob|generation|chunk|player|mod|change)s\b`)

func singolareEN(s string) string { return reOneEN.ReplaceAllString(s, "${1}1 $2") }

// L e Lf: testi nella lingua dell'hub (log, Telegram).
func L(id string) string            { return T(Default(), id) }
func Lf(id string, a ...any) string { return Tf(Default(), id, a...) }

// Localizer è qualcosa che sa rendersi in una lingua.
type Localizer interface {
	Localize(Lang) string
}

// Localize rende err nella lingua l: se nella catena c'è un errore
// localizzabile, quello (con tutto il suo contesto); altrimenti err.Error().
func Localize(l Lang, err error) string {
	if err == nil {
		return ""
	}
	if lz, ok := err.(Localizer); ok {
		return lz.Localize(l)
	}
	var e *Error
	if errors.As(err, &e) && e.Error() == err.Error() {
		return e.Localize(l)
	}
	return err.Error()
}

func localizeArgs(l Lang, a []any) []any {
	out := make([]any, len(a))
	for i, v := range a {
		switch x := v.(type) {
		case Localizer:
			out[i] = x.Localize(l)
		case float64: // numeri passati da JSON (eventi riletti dal log)
			if x == float64(int64(x)) {
				out[i] = int64(x)
			} else {
				out[i] = x
			}
		default:
			out[i] = v
		}
	}
	return out
}

// Error è un errore traducibile: id + argomenti, reso nella lingua scelta al
// momento della stampa. Gli argomenti di tipo error sono "wrappati" (%w).
type Error struct {
	id   string
	args []any
}

// Errorf crea un errore traducibile, come fmt.Errorf (supporta %w).
func Errorf(id string, args ...any) error {
	return &Error{id: id, args: args}
}

func (e *Error) Localize(l Lang) string { return Tf(l, e.id, e.args...) }

// Error: nella lingua dell'hub (log, test).
func (e *Error) Error() string { return e.Localize(Default()) }

func (e *Error) Unwrap() []error {
	var out []error
	for _, a := range e.args {
		if err, ok := a.(error); ok {
			out = append(out, err)
		}
	}
	return out
}

// Text è un messaggio da rendere più tardi (eventi): id + argomenti.
// Serializzato negli eventi come "key" e "args".
type Text struct {
	Key  string `json:"key"`
	Args []any  `json:"args,omitempty"`
}

// M crea un Text.
func M(id string, args ...any) *Text { return &Text{Key: id, Args: args} }

func (t *Text) Localize(l Lang) string { return Tf(l, t.Key, t.Args...) }
