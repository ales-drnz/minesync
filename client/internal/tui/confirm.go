package tui

import (
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"minesync/client/internal/i18n"
)

// confirmScreen: modale di conferma generico, con supporto a doppia conferma
// per le azioni distruttive (force release, restore…).
type confirmScreen struct {
	app         *App
	titleTxt    string
	body        string
	okLabel     string
	cancelLabel string // vuoto = "Annulla"
	danger      bool
	stages      int // 1 = conferma semplice, 2 = doppia conferma
	stage       int
	choice      int // 0 = annulla, 1 = ok
	onOK        tea.Cmd
}

func newConfirm(app *App, title, body, okLabel string, danger bool, stages int, onOK tea.Cmd) *confirmScreen {
	if stages < 1 {
		stages = 1
	}
	return &confirmScreen{app: app, titleTxt: title, body: body, okLabel: okLabel,
		danger: danger, stages: stages, onOK: onOK}
}

func (c *confirmScreen) title() string { return c.titleTxt }
func (c *confirmScreen) hints() []keyHint {
	return []keyHint{{key: "←/→", label: i18n.S("scegli")}, {key: i18n.S("invio"), label: i18n.S("conferma")}, {key: "esc", label: i18n.S("annulla")}}
}
func (c *confirmScreen) init() tea.Cmd { return nil }

func (c *confirmScreen) update(msg tea.Msg) (screen, tea.Cmd) {
	if key, ok := msg.(tea.KeyMsg); ok {
		switch key.String() {
		case "left", "right", "tab", "h", "l":
			c.choice = 1 - c.choice
		case "enter":
			if c.choice == 0 {
				return c, func() tea.Msg { return pop() }
			}
			c.stage++
			if c.stage >= c.stages {
				return c, tea.Sequence(func() tea.Msg { return pop() }, c.onOK)
			}
			c.choice = 0 // la seconda conferma riparte da "annulla"
		}
	}
	return c, nil
}

func (c *confirmScreen) view(w, h int) string {
	warnStyle := sBold
	if c.danger {
		warnStyle = sErr
	}
	head := warnStyle.Render(c.titleTxt)
	body := lipgloss.NewStyle().Width(52).Foreground(cText).Render(c.body)
	if c.stages > 1 {
		body += "\n\n" + sWarn.Render(i18n.Sf("Conferma %s di 2.", ordinale(c.stage+1)))
		if c.stage == 1 {
			body += "\n" + sErr.Render(i18n.S("ULTIMA CHIAMATA: l'azione è irreversibile."))
		}
	}
	cancelLabel := c.cancelLabel
	if cancelLabel == "" {
		cancelLabel = i18n.S("Annulla")
	}
	cancel := "  " + cancelLabel + "  "
	ok := "  " + c.okLabel + "  "
	if c.choice == 0 {
		cancel = sSelected.Render(cancel)
		ok = sMuted.Render(ok)
	} else {
		cancel = sMuted.Render(cancel)
		if c.danger {
			ok = lipgloss.NewStyle().Bold(true).Foreground(cRed).Reverse(true).Render(ok)
		} else {
			ok = sSelected.Render(ok)
		}
	}
	buttons := lipgloss.JoinHorizontal(lipgloss.Center, cancel, "   ", ok)
	card := panel("", head+"\n\n"+body+"\n\n"+buttons, 58, true)
	return lipgloss.Place(w, h, lipgloss.Center, lipgloss.Center, card)
}

func ordinale(n int) string {
	if n == 1 {
		return i18n.S("1ª")
	}
	return i18n.S("2ª")
}
