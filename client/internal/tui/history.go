package tui

import (
	"context"
	"fmt"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"minesync/client/internal/api"
	"minesync/client/internal/i18n"
)

// historyScreen: storia completa delle generazioni + restore.
type historyScreen struct {
	app    *App
	id     string
	gens   []api.GenSummary
	head   int
	cursor int
	loaded bool
	offset int
}

type historyDataMsg struct {
	gens []api.GenSummary
	head int
	err  error
}
type restoredMsg struct{ err error }

func newHistory(app *App, id string) *historyScreen {
	return &historyScreen{app: app, id: id}
}

func (s *historyScreen) title() string { return s.id + " · " + i18n.S("storia") }
func (s *historyScreen) hints() []keyHint {
	hs := []keyHint{{key: "↑↓", label: i18n.S("naviga")}}
	if s.app.who.Admin {
		hs = append(hs, keyHint{key: i18n.S("invio"), label: i18n.S("ripristina")})
	}
	return append(hs, keyHint{key: "esc", label: i18n.S("indietro")})
}

func (s *historyScreen) init() tea.Cmd { return s.load() }

func (s *historyScreen) load() tea.Cmd {
	client := s.app.client
	id := s.id
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		sp, err := client.Space(ctx, id)
		if err != nil {
			return historyDataMsg{err: err}
		}
		gens, err := client.Generations(ctx, id, 200)
		return historyDataMsg{gens: gens, head: sp.Head, err: err}
	}
}

func (s *historyScreen) update(msg tea.Msg) (screen, tea.Cmd) {
	switch msg := msg.(type) {
	case historyDataMsg:
		s.loaded = true
		if msg.err == nil {
			s.gens = msg.gens
			s.head = msg.head
		}
		return s, nil
	case globalTickMsg:
		return s, s.load()
	case restoredMsg:
		if msg.err != nil {
			return s, func() tea.Msg { return errMsg(msg) }
		}
		return s, tea.Batch(s.load(),
			func() tea.Msg { return flashMsg{sOK.Render(i18n.S("✔ generazione ripristinata"))} })
	case tea.MouseMsg:
		switch msg.Button {
		case tea.MouseButtonWheelUp:
			if s.cursor > 0 {
				s.cursor--
			}
		case tea.MouseButtonWheelDown:
			if s.cursor < len(s.gens)-1 {
				s.cursor++
			}
		}
		return s, nil
	case tea.KeyMsg:
		switch msg.String() {
		case "up", "k":
			if s.cursor > 0 {
				s.cursor--
			}
		case "down", "j":
			if s.cursor < len(s.gens)-1 {
				s.cursor++
			}
		case "enter":
			if s.cursor < len(s.gens) {
				g := s.gens[s.cursor]
				if !s.app.who.Admin {
					return s, func() tea.Msg { return flashMsg{sMuted.Render(i18n.S("il ripristino è riservato all'admin"))} }
				}
				if g.N == s.head {
					return s, func() tea.Msg { return flashMsg{sMuted.Render(i18n.S("è già la generazione corrente"))} }
				}
				body := i18n.Sf(
					"Verrà creata una nuova generazione con il contenuto di #%d (%s, %s).\n\nNessun dato viene perso: la storia resta. Al prossimo avvio tutti scaricheranno questa versione.",
					g.N, g.Author, g.TS.Local().Format("02/01 15:04"))
				return s, push(newConfirm(s.app, i18n.Sf("Ripristinare #%d?", g.N), body,
					i18n.S("Ripristina"), false, 1, s.restore(g.N)))
			}
		}
	}
	return s, nil
}

func (s *historyScreen) restore(n int) tea.Cmd {
	client := s.app.client
	id := s.id
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		_, err := client.Restore(ctx, id, n)
		return restoredMsg{err}
	}
}

func (s *historyScreen) view(w, h int) string {
	if !s.loaded {
		return lipgloss.Place(w, h, lipgloss.Center, lipgloss.Center, sMuted.Render(i18n.S("carico…")))
	}
	if len(s.gens) == 0 {
		return lipgloss.Place(w, h, lipgloss.Center, lipgloss.Center,
			sMuted.Render(i18n.S("Nessuna generazione.")))
	}
	visible := h - 4
	if visible < 3 {
		visible = 3
	}
	if s.cursor < s.offset {
		s.offset = s.cursor
	}
	if s.cursor >= s.offset+visible {
		s.offset = s.cursor - visible + 1
	}
	var rows []string
	end := s.offset + visible
	if end > len(s.gens) {
		end = len(s.gens)
	}
	for i := s.offset; i < end; i++ {
		g := s.gens[i]
		cursor := "  "
		if i == s.cursor {
			cursor = sCursorBar.Render("▎ ")
		}
		bullet := sMuted.Render("●")
		headTag := ""
		if g.N == s.head {
			bullet = sOK.Render("●")
			headTag = sOK.Render(" ← HEAD")
		}
		if g.Restore > 0 {
			bullet = sWarn.Render("⟲")
		}
		msg := g.Message
		if msg == "" {
			msg = i18n.S("salvataggio")
		}
		stats := fmt.Sprintf("%s+%d %s~%d %s−%d",
			sOK.Render(""), g.Stats.Added, sWarn.Render(""), g.Stats.Changed, sErr.Render(""), g.Stats.Removed)
		line := fmt.Sprintf("%s%s %s  %s  %s  %s%s",
			cursor, bullet,
			sBold.Render(fmt.Sprintf("#%-4d", g.N)),
			sText.Render(truncate(msg, w-58)),
			sMuted.Render(fmt.Sprintf("%-8s %s", truncate(g.Author, 8), g.TS.Local().Format("02/01 15:04"))),
			stats, headTag)
		rows = append(rows, line)
	}
	list := lipgloss.JoinVertical(lipgloss.Left, rows...)
	counter := sMuted.Render(i18n.Sf("%d generazioni · %s totali (HEAD)", len(s.gens), func() string {
		for _, g := range s.gens {
			if g.N == s.head {
				return humanBytes(g.Stats.Bytes)
			}
		}
		return "?"
	}()))
	return panel(i18n.Sf("storia di %s", s.id), counter+"\n\n"+list, w, true)
}
