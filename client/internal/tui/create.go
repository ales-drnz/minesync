package tui

import (
	"context"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"minesync/client/internal/i18n"
)

// createScreen: form nuovo server (solo admin).
type createScreen struct {
	app     *App
	name    textinput.Model
	busy    bool
	errText string
}

type createdMsg struct{ err error }

func newCreateSpace(app *App) *createScreen {
	name := textinput.New()
	name.Placeholder = i18n.S("es. MioMondo")
	name.Prompt = "  "
	name.CharLimit = 40
	name.Width = 40
	name.Focus()
	return &createScreen{app: app, name: name}
}

func (s *createScreen) title() string { return i18n.S("nuovo server") }

// blocksGlobal: il campo nome deve ricevere anche q/esc.
func (s *createScreen) blocksGlobal() bool { return true }

func (s *createScreen) hints() []keyHint {
	return []keyHint{{key: i18n.S("invio"), label: i18n.S("crea")}, {key: "esc", label: i18n.S("annulla")}}
}
func (s *createScreen) init() tea.Cmd { return textinput.Blink }

func (s *createScreen) update(msg tea.Msg) (screen, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		if msg.String() == "ctrl+c" {
			return s, tea.Quit
		}
		if msg.String() == "esc" {
			if !s.busy {
				return s, func() tea.Msg { return pop() }
			}
			return s, nil
		}
		if s.busy {
			return s, nil
		}
		if msg.String() == "enter" {
			name := strings.TrimSpace(s.name.Value())
			if name == "" {
				s.errText = i18n.S("dai un nome al server")
				return s, nil
			}
			s.busy = true
			client := s.app.client
			return s, func() tea.Msg {
				ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
				defer cancel()
				_, err := client.CreateSpace(ctx, name, "minecraft")
				return createdMsg{err}
			}
		}
	case createdMsg:
		s.busy = false
		if msg.err != nil {
			s.errText = msg.err.Error()
			return s, nil
		}
		return s, tea.Sequence(func() tea.Msg { return pop() },
			func() tea.Msg { return homeRefreshMsg{} },
			func() tea.Msg { return flashMsg{sOK.Render(i18n.S("✔ server creato"))} })
	}
	var cmd tea.Cmd
	s.name, cmd = s.name.Update(msg)
	return s, cmd
}

func (s *createScreen) view(w, h int) string {
	body := lipgloss.JoinVertical(lipgloss.Left,
		sPanelTitle.Render(" "+i18n.S("NOME DEL SERVER")+" "),
		s.name.View(),
	)
	if s.errText != "" {
		body += "\n\n" + sErr.Render("✗ "+truncate(s.errText, 50))
	} else if s.busy {
		body += "\n\n" + sMuted.Render(i18n.S("creo…"))
	}
	return lipgloss.Place(w, h, lipgloss.Center, lipgloss.Center,
		panel(i18n.S("nuovo server"), body, 58, true))
}
