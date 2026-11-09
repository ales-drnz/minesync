package tui

import (
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"

	"minesync/client/internal/i18n"
	"minesync/client/internal/mc"
)

// Palette MineSync: verde Minecraft su carbone, coerente con la web UI
// (--green-txt #6cc349, --amber #fcc44d, --red #ff6d6d, --blue #6ea8ff).
var (
	cAccent = lipgloss.AdaptiveColor{Light: "#2f7b1c", Dark: "#6cc349"}
	cAmber  = lipgloss.AdaptiveColor{Light: "#8a6210", Dark: "#fcc44d"}
	cRed    = lipgloss.AdaptiveColor{Light: "#c43c3c", Dark: "#ff6d6d"}
	cBlue   = lipgloss.AdaptiveColor{Light: "#2563eb", Dark: "#6ea8ff"}
	cText   = lipgloss.AdaptiveColor{Light: "#1e1e1f", Dark: "#ffffff"}
	cMuted  = lipgloss.AdaptiveColor{Light: "#5d5d60", Dark: "#9d9da0"}
	cFaint  = lipgloss.AdaptiveColor{Light: "#9d9da0", Dark: "#58585c"}
)

var (
	sTitle = lipgloss.NewStyle().Bold(true).Foreground(cAccent)
	sBold  = lipgloss.NewStyle().Bold(true).Foreground(cText)
	sText  = lipgloss.NewStyle().Foreground(cText)
	sMuted = lipgloss.NewStyle().Foreground(cMuted)
	sFaint = lipgloss.NewStyle().Foreground(cFaint)
	sWarn  = lipgloss.NewStyle().Foreground(cAmber)
	sErr   = lipgloss.NewStyle().Foreground(cRed).Bold(true)
	sOK    = lipgloss.NewStyle().Foreground(cAccent)
	sBlue  = lipgloss.NewStyle().Foreground(cBlue)

	sPanel = lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(cFaint).
		Padding(0, 1)

	sPanelTitle = lipgloss.NewStyle().Bold(true).Foreground(cMuted).
			Transform(strings.ToUpper)

	sHeader = lipgloss.NewStyle().Padding(0, 1)

	sKeycap = lipgloss.NewStyle().Foreground(cAccent).Bold(true)
	sKeyLbl = lipgloss.NewStyle().Foreground(cMuted)

	sSelected = lipgloss.NewStyle().Bold(true).Foreground(cAccent).
			Background(lipgloss.AdaptiveColor{Light: "#d8efd0", Dark: "#1d3a14"})
	sCursorBar = lipgloss.NewStyle().Foreground(cAccent).Bold(true)
)

// panel disegna un riquadro con il titolo inciso nel bordo superiore:
// ╭─ TITOLO ────────╮
// Il titolo DEVE essere testo puro: viene messo in maiuscolo, e il ToUpper
// corromperebbe eventuali sequenze ANSI (la 'm' finale diventa 'M').
func panel(title, body string, width int, focused bool) string {
	st := sPanel
	if width > 0 {
		st = st.Width(width - 2)
	}
	bc := cFaint
	if focused {
		bc = cAccent
	}
	st = st.BorderForeground(bc)
	box := st.Render(body)
	if title == "" {
		return box
	}
	lines := strings.Split(box, "\n")
	w := lipgloss.Width(lines[0])
	t := " " + strings.ToUpper(title) + " "
	if lipgloss.Width(t) > w-4 {
		t = truncate(t, w-4)
	}
	bs := lipgloss.NewStyle().Foreground(bc)
	rest := w - 3 - lipgloss.Width(t)
	if rest < 0 {
		rest = 0
	}
	lines[0] = bs.Render("╭─") + sPanelTitle.Render(t) + bs.Render(strings.Repeat("─", rest)+"╮")
	return strings.Join(lines, "\n")
}

// keybar compone il footer dei tasti. off=true → tasto oscurato (non attivo
// in questo momento, ma esiste: l'utente vede che tornerà disponibile).
type keyHint struct {
	key, label string
	off        bool
	help       bool // solo nell'overlay '?', non nel footer (che resta corto)
}

func keybar(width int, hints ...keyHint) string {
	parts := make([]string, 0, len(hints))
	for _, h := range hints {
		if h.help {
			continue
		}
		if h.off {
			parts = append(parts, sFaint.Render(h.key+" "+h.label))
		} else {
			parts = append(parts, sKeycap.Render(h.key)+" "+sKeyLbl.Render(h.label))
		}
	}
	bar := strings.Join(parts, sFaint.Render("  ·  "))
	return lipgloss.NewStyle().Padding(0, 1).Width(width).Render(bar)
}

// dot colorato per gli stati del lock.
func lockDot(state string) string {
	switch state {
	case "held":
		return sOK.Render("●")
	case "stale":
		return sWarn.Render("◐")
	default:
		return sFaint.Render("○")
	}
}

// progressBar disegna una barra piena/vuota con percentuale.
func progressBar(width int, frac float64) string {
	if width < 10 {
		width = 10
	}
	if frac < 0 {
		frac = 0
	}
	if frac > 1 {
		frac = 1
	}
	inner := width - 7
	fill := int(frac * float64(inner))
	bar := sOK.Render(strings.Repeat("█", fill)) + sFaint.Render(strings.Repeat("░", inner-fill))
	return fmt.Sprintf("%s %4.0f%%", bar, frac*100)
}

func humanBytes(n int64) string {
	switch {
	case n >= 1e9:
		return fmt.Sprintf("%.2f GB", float64(n)/1e9)
	case n >= 1e6:
		return fmt.Sprintf("%.1f MB", float64(n)/1e6)
	case n >= 1e3:
		return fmt.Sprintf("%.0f kB", float64(n)/1e3)
	}
	return fmt.Sprintf("%d B", n)
}

func humanSpeed(bps float64) string {
	return humanBytes(int64(bps)) + "/s"
}

// humanETA stima il tempo rimanente ("" se non calcolabile).
func humanETA(doneB, totalB int64, speed float64) string {
	if speed <= 0 || totalB <= doneB {
		return ""
	}
	d := time.Duration(float64(totalB-doneB)/speed) * time.Second
	switch {
	case d >= time.Hour:
		return fmt.Sprintf("~%dh%02dm", int(d.Hours()), int(d.Minutes())%60)
	case d >= time.Minute:
		return fmt.Sprintf("~%dm%02ds", int(d.Minutes()), int(d.Seconds())%60)
	default:
		return fmt.Sprintf("~%ds", int(d.Seconds()))
	}
}

func agoShort(t time.Time) string {
	if t.IsZero() {
		return i18n.S("mai")
	}
	d := time.Since(t)
	switch {
	case d < time.Minute:
		return i18n.Sf("%ds fa", int(d.Seconds()))
	case d < time.Hour:
		return i18n.Sf("%dm fa", int(d.Minutes()))
	case d < 24*time.Hour:
		return i18n.Sf("%dh fa", int(d.Hours()))
	default:
		return t.Local().Format("02/01 15:04")
	}
}

// truncate taglia una stringa a w celle aggiungendo … se serve.
func truncate(s string, w int) string {
	if w <= 1 {
		return ""
	}
	if lipgloss.Width(s) <= w {
		return s
	}
	r := []rune(s)
	if len(r) > w-1 {
		r = r[:w-1]
	}
	return string(r) + "…"
}

// launchLabel descrive in breve come verrà avviato il server: il nome dello
// script se c'è, altrimenti il jar lanciato direttamente.
func launchLabel(info mc.ServerInfo) string {
	if info.StartScript != "" {
		return filepath.Base(info.StartScript)
	}
	if len(info.Launch) >= 3 && info.Launch[1] == "-jar" {
		return info.Launch[2]
	}
	if len(info.Launch) > 0 {
		return info.Launch[0]
	}
	return "?"
}
