package tui

import (
	"context"
	"fmt"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"minesync/client/internal/api"
	"minesync/client/internal/i18n"
)

// homeScreen: elenco spazi + feed attività dell'hub.
type homeScreen struct {
	app     *App
	spaces  []api.Space
	events  []api.Event
	cursor  int
	loaded  bool
	loadErr string
}

type homeDataMsg struct {
	spaces []api.Space
	events []api.Event
	err    error
}
type homeRefreshMsg struct{}

func newHome(app *App) *homeScreen { return &homeScreen{app: app} }

func (s *homeScreen) title() string { return i18n.S("server") }
func (s *homeScreen) hints() []keyHint {
	h := []keyHint{{key: "↑↓", label: i18n.S("naviga")}, {key: i18n.S("invio"), label: i18n.S("apri")}}
	if s.app.who.Admin {
		h = append(h, keyHint{key: "n", label: i18n.S("nuovo server")})
	}
	return append(h, keyHint{key: "c", label: i18n.S("cambia hub")}, keyHint{key: "r", label: i18n.S("aggiorna")},
		keyHint{key: "q", label: i18n.S("esci")}, langHint("l", true))
}

func (s *homeScreen) init() tea.Cmd { return s.load() }

func (s *homeScreen) load() tea.Cmd {
	client := s.app.client
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		spaces, err := client.Spaces(ctx)
		if err != nil {
			return homeDataMsg{err: err}
		}
		evs, _ := client.Events(ctx, 40)
		return homeDataMsg{spaces: spaces, events: evs}
	}
}

func (s *homeScreen) update(msg tea.Msg) (screen, tea.Cmd) {
	switch msg := msg.(type) {
	case homeDataMsg:
		s.loaded = true
		if msg.err != nil {
			s.loadErr = msg.err.Error()
			return s, nil
		}
		s.loadErr = ""
		s.spaces = msg.spaces
		s.events = msg.events
		if s.cursor >= len(s.spaces) {
			s.cursor = max(0, len(s.spaces)-1)
		}
		return s, nil
	case homeRefreshMsg, globalTickMsg:
		return s, s.load()
	case sseEventMsg:
		s.events = append(s.events, msg.ev)
		if len(s.events) > 60 {
			s.events = s.events[len(s.events)-60:]
		}
		return s, s.load()
	case tea.MouseMsg:
		switch msg.Button {
		case tea.MouseButtonWheelUp:
			if s.cursor > 0 {
				s.cursor--
			}
		case tea.MouseButtonWheelDown:
			if s.cursor < len(s.spaces)-1 {
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
			if s.cursor < len(s.spaces)-1 {
				s.cursor++
			}
		case "enter":
			if s.cursor < len(s.spaces) {
				return s, push(newSpaceScreen(s.app, s.spaces[s.cursor].ID))
			}
		case "n":
			if s.app.who.Admin {
				return s, push(newCreateSpace(s.app))
			}
		case "c":
			return s, push(newSetup(s.app))
		case "r":
			return s, s.load()
		case "l":
			return s, toggleLang
		}
	}
	return s, nil
}

func (s *homeScreen) view(w, h int) string {
	listW := w * 55 / 100
	feedW := w - listW - 1

	var rows []string
	if !s.loaded {
		rows = append(rows, sMuted.Render(i18n.S("carico…")))
	} else if s.loadErr != "" {
		rows = append(rows, sErr.Render("✗ "+truncate(s.loadErr, listW-6)))
	} else if len(s.spaces) == 0 {
		rows = append(rows, sMuted.Render(i18n.S("Nessun server.")),
			sMuted.Render(i18n.S("Premi 'n' per crearne uno.")))
	}
	for i, sp := range s.spaces {
		cursor := "  "
		nameSt, idSt := sBold, sMuted
		if i == s.cursor {
			cursor = sCursorBar.Render("▎ ")
			nameSt = nameSt.Foreground(cAccent)
		}
		lockState := "free"
		lockTxt := sFaint.Render(i18n.S("libero"))
		if sp.Lock != nil {
			if sp.LockStale {
				lockState = "stale"
				lockTxt = sWarn.Render("stale · " + sp.Lock.Owner)
			} else {
				lockState = "held"
				lockTxt = sOK.Render(i18n.Sf("in gioco · %s", sp.Lock.Owner))
				if n := len(sp.Lock.Players); n > 0 {
					lockTxt += sMuted.Render(fmt.Sprintf(" · %d online", n))
				}
			}
		}
		linked := ""
		if _, ok := s.app.cfg.Spaces[sp.ID]; ok {
			linked = sOK.Render(" ⇅")
			// pre-download in corso: si vede che il prossimo G sarà istantaneo
			if st, ok := s.app.prefetch[sp.ID]; ok && st.Running && st.TotalBytes > 0 {
				pct := int(100 * st.DoneBytes / st.TotalBytes)
				linked = sWarn.Render(i18n.Sf(" ⇣ pre-scarico %d%%", pct))
			}
		}
		line1 := cursor + nameSt.Render(truncate(sp.Name, listW-24)) + linked +
			"  " + idSt.Render("#"+fmt.Sprint(sp.Head))
		line2 := "  " + lockDot(lockState) + " " + lockTxt
		rows = append(rows, line1, line2, "")
	}
	list := panel(i18n.Sf("server (%d)", len(s.spaces)),
		lipgloss.JoinVertical(lipgloss.Left, rows...), listW, true)

	var evRows []string
	for i := len(s.events) - 1; i >= 0 && len(evRows) < h-4; i-- {
		e := s.events[i]
		t := sFaint.Render(e.TS.Local().Format("15:04"))
		badge := eventBadge(e.Type)
		evRows = append(evRows, t+" "+badge+" "+sText.Render(truncate(eventMsg(e), feedW-16)))
	}
	if len(evRows) == 0 {
		evRows = append(evRows, sMuted.Render(i18n.S("nessuna attività")))
	}
	feed := panel(i18n.S("attività"), lipgloss.JoinVertical(lipgloss.Left, evRows...), feedW, false)

	return lipgloss.JoinHorizontal(lipgloss.Top, list, " ", feed)
}

// eventMsg pulisce il messaggio per il feed: dai salvataggi toglie la coda
// "— <messaggio> (+a ~c −r)" (i dettagli stanno nella storia), come nella web UI.
func eventMsg(e api.Event) string {
	m := e.Msg
	if e.Type == "push" {
		if i := strings.IndexRune(m, '—'); i > 0 {
			m = strings.TrimRight(m[:i], " ")
		}
	}
	return m
}

func eventBadge(t string) string {
	switch t {
	case "push":
		return sOK.Render("push ")
	case "lock":
		return sBlue.Render("lock ")
	case "unlock":
		return sErr.Render("stop ")
	case "force":
		return sErr.Render("FORCE")
	case "restore":
		return sWarn.Render("rstr ")
	case "gc":
		return sWarn.Render("gc   ")
	default:
		return sMuted.Render(fmt.Sprintf("%-5s", truncate(t, 5)))
	}
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
