package tui

import (
	"context"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"minesync/client/internal/api"
	"minesync/client/internal/config"
	"minesync/client/internal/i18n"
)

// setupScreen: connessione all'hub. Nessuna credenziale: basta l'indirizzo,
// l'hub ti riconosce dall'IP della rete ZeroTier.
type setupScreen struct {
	app     *App
	addr    textinput.Model
	testing bool
	spin    spinner.Model
	errText string
}

type setupFailMsg struct{ err error }

func newSetup(app *App) *setupScreen {
	addr := textinput.New()
	addr.Prompt = "  "
	addr.CharLimit = 128
	addr.Width = 46
	// nessun hub predefinito nelle build pubbliche (DefaultServer vuoto):
	// il segnaposto mostra il formato atteso
	addr.Placeholder = "http://<ip-hub>:8084"
	addr.SetValue(config.DefaultServer)
	if app.cfg.Server != "" {
		addr.SetValue(app.cfg.Server)
	}
	addr.Focus()
	addr.CursorEnd()

	sp := spinner.New(spinner.WithSpinner(spinner.MiniDot))
	sp.Style = sOK
	return &setupScreen{app: app, addr: addr, spin: sp}
}

func (s *setupScreen) title() string { return i18n.S("connessione") }

// blocksGlobal: il campo di testo deve ricevere anche q/esc.
func (s *setupScreen) blocksGlobal() bool { return true }

func (s *setupScreen) hints() []keyHint {
	h := []keyHint{{key: i18n.S("invio"), label: i18n.S("connetti")}}
	if len(s.app.stack) > 1 {
		h = append(h, keyHint{key: "esc", label: i18n.S("annulla")})
	}
	return append(h, keyHint{key: "ctrl+c", label: i18n.S("esci")}, langHint("ctrl+l", false))
}
func (s *setupScreen) init() tea.Cmd { return textinput.Blink }

func (s *setupScreen) update(msg tea.Msg) (screen, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		if msg.String() == "ctrl+c" {
			return s, tea.Quit
		}
		if msg.String() == "ctrl+l" {
			return s, toggleLang
		}
		if msg.String() == "esc" {
			if len(s.app.stack) > 1 && !s.testing {
				return s, func() tea.Msg { return pop() }
			}
			return s, nil
		}
		if s.testing {
			return s, nil
		}
		if msg.String() == "enter" {
			return s, s.submit()
		}
	case setupFailMsg:
		s.testing = false
		s.errText = msg.err.Error()
		return s, nil
	case spinner.TickMsg:
		var cmd tea.Cmd
		s.spin, cmd = s.spin.Update(msg)
		return s, cmd
	}
	var cmd tea.Cmd
	s.addr, cmd = s.addr.Update(msg)
	return s, cmd
}

func (s *setupScreen) submit() tea.Cmd {
	url := strings.TrimSpace(s.addr.Value())
	if url == "" {
		s.errText = i18n.S("inserisci l'indirizzo dell'hub")
		return nil
	}
	if !strings.HasPrefix(url, "http") {
		url = "http://" + url
	}
	url = strings.TrimRight(url, "/")
	s.testing = true
	s.errText = ""
	app := s.app
	return tea.Batch(s.spin.Tick, func() tea.Msg {
		client := api.New(url)
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		who, err := client.Whoami(ctx)
		if err != nil {
			return setupFailMsg{err}
		}
		app.cfg.Server, app.cfg.Name = url, who.Name
		if err := app.cfg.Save(); err != nil {
			return setupFailMsg{err}
		}
		app.client = client
		return loginDoneMsg{who}
	})
}

func (s *setupScreen) view(w, h int) string {
	logo := sTitle.Render(`
  ❒  M I N E S Y N C`) + sMuted.Render("\n     "+i18n.S("il mondo condiviso, sempre aggiornato"))

	form := lipgloss.JoinVertical(lipgloss.Left,
		sPanelTitle.Render(" "+i18n.S("INDIRIZZO HUB")+" "),
		s.addr.View(),
	)
	status := ""
	if s.testing {
		status = s.spin.View() + sMuted.Render(" "+i18n.S("connessione…"))
	} else if s.errText != "" {
		status = sErr.Render("✗ " + truncate(s.errText, 54))
	}
	card := panel(i18n.S("connessione"), form+"\n\n"+status, 58, true)
	return lipgloss.Place(w, h, lipgloss.Center, lipgloss.Center,
		lipgloss.JoinVertical(lipgloss.Center, logo, "", card))
}
