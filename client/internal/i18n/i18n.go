// Package i18n: testi del client in italiano e inglese, stile gettext.
//
// Il testo italiano letterale è l'id del messaggio: in italiano si mostra
// così com'è, in inglese si cerca in catalogEN (se manca, resta l'id). Le
// chiamate vanno sempre fatte con un letterale stringa come primo argomento
// del messaggio: il test di copertura le trova nel sorgente e controlla che
// ognuna abbia la sua traduzione.
package i18n

import (
	"fmt"
	"regexp"
	"strings"
	"sync/atomic"
)

// Lang è una lingua supportata.
type Lang string

const (
	IT Lang = "it"
	EN Lang = "en"
)

// Parse riconosce una lingua da un tag di locale o da un Accept-Language:
// "it", "it_IT.UTF-8", "it-IT", "en-US,en;q=0.9", "fr-FR,it;q=0.8" → la prima
// lingua supportata. false se nessuna è italiano o inglese.
func Parse(s string) (Lang, bool) {
	for _, part := range strings.FieldsFunc(s, func(r rune) bool { return r == ',' || r == ':' }) {
		tag, _, _ := strings.Cut(part, ";")
		tag = strings.ToLower(strings.TrimSpace(tag))
		tag = strings.Trim(tag, `"'`)
		if i := strings.IndexAny(tag, "-_.@"); i >= 0 {
			tag = tag[:i]
		}
		switch tag {
		case "it":
			return IT, true
		case "en":
			return EN, true
		}
	}
	return "", false
}

// Name è il nome della lingua nella lingua stessa.
func (l Lang) Name() string {
	if l == IT {
		return "italiano"
	}
	return "English"
}

// Other è l'altra lingua supportata (per il tasto che le alterna).
func (l Lang) Other() Lang {
	if l == IT {
		return EN
	}
	return IT
}

var current atomic.Value // Lang

func init() { current.Store(EN) }

// Set cambia la lingua del processo (sicuro da più goroutine).
func Set(l Lang) {
	if l != IT {
		l = EN
	}
	current.Store(l)
}

// Current è la lingua corrente del processo.
func Current() Lang { return current.Load().(Lang) }

// T traduce id nella lingua l (fallback: id stesso).
func T(l Lang, id string) string {
	if l == EN {
		if s, ok := catalogEN[id]; ok {
			return s
		}
	}
	return id
}

// Tf è fmt.Sprintf(T(l, id), a...).
func Tf(l Lang, id string, a ...any) string {
	if l != EN {
		return fmt.Sprintf(id, a...)
	}
	return singolareEN(fmt.Sprintf(T(EN, id), a...))
}

// singolareEN corregge il plurale inglese dopo un "1" isolato ("1 files" →
// "1 file"): i messaggi hanno un solo testo per tutti i numeri.
var reOneEN = regexp.MustCompile(`(^|[^0-9./,])1 (file|blob|generation|chunk|player|mod|change)s\b`)

func singolareEN(s string) string { return reOneEN.ReplaceAllString(s, "${1}1 $2") }

// S traduce id nella lingua corrente.
func S(id string) string { return T(Current(), id) }

// Sf è fmt.Sprintf(S(id), a...).
func Sf(id string, a ...any) string {
	if Current() != EN {
		return fmt.Sprintf(id, a...)
	}
	return fmt.Sprintf(T(EN, id), a...)
}

// Errorf è fmt.Errorf(S(id), a...): %w funziona come al solito.
func Errorf(id string, a ...any) error {
	if Current() != EN {
		return fmt.Errorf(id, a...)
	}
	return fmt.Errorf(T(EN, id), a...)
}

// Error è un errore sentinella il cui testo segue la lingua corrente nel
// momento in cui viene mostrato (le variabili di pacchetto nascono prima che
// la lingua sia scelta). Si confronta per identità con errors.Is.
type Error struct{ id string }

// NewError crea un errore sentinella tradotto in modo pigro.
func NewError(id string) error { return &Error{id: id} }

func (e *Error) Error() string { return S(e.id) }
