package tui

import (
	"strings"

	"github.com/muesli/reflow/wrap"

	"minesync/client/internal/i18n"
)

const (
	consoleMaxLines   = 2000 // righe grezze tenute in memoria
	consoleMaxWrapped = 4000 // righe a video dopo il wrap
)

// logItem è una riga di console classificata (0 info, 1 warn, 2 error).
type logItem struct {
	raw string // testo puro, per la ricerca
	txt string // già colorato per la viewport
	lvl int
}

// consoleBuffer tiene il log del server: righe grezze, filtro di livello,
// ricerca testuale e righe già wrappate alla larghezza corrente. Non sa nulla
// della viewport: la schermata ne prende content() dopo ogni modifica.
type consoleBuffer struct {
	lines   []logItem
	wrapped []string
	width   int    // 0 = non ancora dimensionato (niente wrap)
	filter  int    // 0 tutto · 1 avvisi+errori · 2 solo errori
	search  string // filtro testuale ("" = nessuno)
}

// passes riporta se una riga supera filtro di livello e ricerca testuale.
func (b *consoleBuffer) passes(it logItem) bool {
	if it.lvl < b.filter {
		return false
	}
	if b.search == "" {
		return true
	}
	return strings.Contains(strings.ToLower(it.raw), strings.ToLower(b.search))
}

// append aggiunge una riga; se visibile la wrappa subito (niente rewrap totale).
func (b *consoleBuffer) append(line string) {
	it := classifyLog(line)
	b.lines = append(b.lines, it)
	if len(b.lines) > consoleMaxLines {
		b.lines = b.lines[len(b.lines)-consoleMaxLines:]
	}
	if b.width > 0 && b.passes(it) {
		b.wrapped = append(b.wrapped, b.wrapLine(it)...)
		if len(b.wrapped) > consoleMaxWrapped {
			b.wrapped = b.wrapped[len(b.wrapped)-consoleMaxWrapped:]
		}
	}
}

func (b *consoleBuffer) wrapLine(it logItem) []string {
	return strings.Split(wrap.String(it.txt, b.width), "\n")
}

// rewrap ricalcola tutte le righe visibili (resize, filtro o ricerca).
func (b *consoleBuffer) rewrap() {
	b.wrapped = b.wrapped[:0]
	if b.width <= 0 {
		return
	}
	for _, it := range b.lines {
		if b.passes(it) {
			b.wrapped = append(b.wrapped, b.wrapLine(it)...)
		}
	}
	if len(b.wrapped) > consoleMaxWrapped {
		b.wrapped = b.wrapped[len(b.wrapped)-consoleMaxWrapped:]
	}
}

func (b *consoleBuffer) setWidth(w int) {
	b.width = w
	b.rewrap()
}

// cycleFilter passa al filtro di livello successivo.
func (b *consoleBuffer) cycleFilter() {
	b.filter = (b.filter + 1) % 3
	b.rewrap()
}

// setSearch cambia la ricerca; riporta se è cambiata davvero.
func (b *consoleBuffer) setSearch(q string) bool {
	if q == b.search {
		return false
	}
	b.search = q
	b.rewrap()
	return true
}

func (b *consoleBuffer) content() string { return strings.Join(b.wrapped, "\n") }

// title compone il titolo del pannello console. Deve restare testo puro
// (niente stili ANSI: il ToUpper del bordo li corromperebbe).
func (b *consoleBuffer) title(searching, follow bool) string {
	t := "console"
	switch b.filter {
	case 1:
		t += " · " + i18n.S("solo avvisi+errori")
	case 2:
		t += " · " + i18n.S("solo errori")
	}
	if b.search != "" || searching {
		t += " · " + i18n.S("cerca") + ": “" + b.search + "”"
	}
	if !follow {
		t += " · " + i18n.S("▲ scroll — End per tornare live")
	}
	return t
}

func classifyLog(line string) logItem {
	l := strings.ToLower(line)
	switch {
	case strings.Contains(l, "error") || strings.Contains(l, "exception") ||
		strings.Contains(l, "fatal") || strings.Contains(l, "severe"):
		return logItem{raw: line, txt: sErr.Render(line), lvl: 2}
	case strings.Contains(l, "warn"):
		return logItem{raw: line, txt: sWarn.Render(line), lvl: 1}
	case strings.Contains(l, "joined the game") || strings.Contains(l, "left the game"):
		return logItem{raw: line, txt: sBlue.Render(line), lvl: 0}
	default:
		return logItem{raw: line, txt: sText.Render(line), lvl: 0}
	}
}
