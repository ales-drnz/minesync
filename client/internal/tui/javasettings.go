package tui

import (
	"cmp"
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"minesync/client/internal/i18n"
	"minesync/client/internal/mc"
)

// javaScreen: sceglie il runtime Java per un singolo spazio. Elenca i Java
// rilevati sul sistema; il default ("Automatico") lascia a MineSync la scelta
// del runtime compatibile col modpack.
type javaScreen struct {
	app  *App
	id   string
	info mc.ServerInfo
	req  int // major di Java richiesto dal modpack (0 = ignoto)

	javas   []mc.JavaInfo
	loading bool
	cursor  int    // 0 = "Automatico", 1..N = i java rilevati
	current string // JavaPath salvato ("" = automatico)
}

func newJavaScreen(app *App, id string, info mc.ServerInfo) *javaScreen {
	return &javaScreen{
		app: app, id: id, info: info,
		req:     mc.RequiredMajor(info.MCVersion),
		loading: true,
		current: app.cfg.Spaces[id].JavaPath,
	}
}

func (s *javaScreen) title() string { return s.id + " · java" }

func (s *javaScreen) hints() []keyHint {
	return []keyHint{
		{key: "↑↓", label: i18n.S("scegli")},
		{key: i18n.S("invio"), label: i18n.S("salva")},
		{key: "r", label: i18n.S("ririleva")},
	}
}

// init usa la lista già rilevata dall'App se c'è; altrimenti la rileva
// (spawna dei `java -version`, quindi fuori dal thread UI).
func (s *javaScreen) init() tea.Cmd {
	if s.app.javasOK {
		s.setJavas(s.app.javas)
		return nil
	}
	return detectJavas()
}

// setJavas mostra la lista e posiziona il cursore sulla scelta salvata.
func (s *javaScreen) setJavas(javas []mc.JavaInfo) {
	s.javas = javas
	s.loading = false
	s.cursor = 0
	if s.current != "" {
		for i, j := range s.javas {
			if strings.EqualFold(j.Path, s.current) {
				s.cursor = i + 1
				break
			}
		}
	}
}

func (s *javaScreen) update(msg tea.Msg) (screen, tea.Cmd) {
	switch msg := msg.(type) {
	case javasDetectedMsg:
		s.setJavas(msg.javas)
		return s, nil

	case tea.KeyMsg:
		switch msg.String() {
		case "up", "k":
			if s.cursor > 0 {
				s.cursor--
			}
		case "down", "j":
			if s.cursor < len(s.javas) {
				s.cursor++
			}
		case "r":
			s.loading = true
			return s, detectJavas()
		case "enter":
			return s, s.save()
		}
	}
	return s, nil
}

// save persiste la scelta nella config dello spazio e torna indietro.
func (s *javaScreen) save() tea.Cmd {
	var path string
	if s.cursor > 0 && s.cursor <= len(s.javas) {
		path = s.javas[s.cursor-1].Path
	}
	sc := s.app.cfg.Spaces[s.id]
	sc.JavaPath = path
	s.app.cfg.Spaces[s.id] = sc
	if err := s.app.cfg.Save(); err != nil {
		return func() tea.Msg { return errMsg{err} }
	}
	note := i18n.S("runtime: automatico (dal modpack)")
	if path != "" {
		note = i18n.Sf("runtime fissato per %s", s.id)
	}
	return tea.Batch(
		func() tea.Msg { return flashMsg{sOK.Render("✔ " + note)} },
		pop,
		s.app.requestJava(s.id, s.info), // la dashboard trova il runtime già risolto
	)
}

func (s *javaScreen) view(w, h int) string {
	colW := w
	if colW > 92 {
		colW = 92
	}

	loader := orDash(s.info.Loader)
	if s.info.MCVersion != "" {
		loader = strings.TrimSpace(s.info.Loader + " · Minecraft " + s.info.MCVersion)
	}
	reqTxt := sMuted.Render(i18n.S("Java consigliato: sconosciuto (versione di Minecraft non rilevata)"))
	if s.req > 0 {
		reqTxt = sText.Render(i18n.S("Java consigliato per questo modpack: ")) + sBold.Render(fmt.Sprintf("%d", s.req))
	}
	head := lipgloss.JoinVertical(lipgloss.Left,
		sMuted.Render("modpack   ")+sText.Render(loader),
		reqTxt)

	var rows []string
	if s.loading {
		rows = append(rows, sMuted.Render(i18n.S("rilevo i runtime installati…")))
	} else {
		rows = append(rows, s.row(0, i18n.S("Automatico"), s.autoSub(), colW))
		for i, j := range s.javas {
			ver := cmp.Or(j.Version, "?")
			sub := sMuted.Render(ver+"  ") + sFaint.Render(truncate(j.Path, colW-14))
			rows = append(rows, s.row(i+1, fmt.Sprintf("Java %d", j.Major), sub, colW))
		}
		if len(s.javas) == 0 {
			rows = append(rows, "", sWarn.Render(i18n.S("Nessun runtime trovato sul sistema.")),
				sMuted.Render(i18n.S("Installa il Java richiesto (es. Adoptium/Temurin) e premi r.")))
		}
	}

	body := lipgloss.JoinVertical(lipgloss.Left, head, "",
		lipgloss.JoinVertical(lipgloss.Left, rows...))
	box := panel(i18n.Sf("runtime java per %s", s.id), body, colW, true)
	return lipgloss.Place(w, h, lipgloss.Center, lipgloss.Top, box)
}

// row disegna una riga-opzione: freccia se sotto il cursore, pallino se è la
// scelta salvata, tag "consigliato" se il major combacia col modpack.
func (s *javaScreen) row(idx int, title, sub string, colW int) string {
	saved := idx == 0 && s.current == ""
	if idx > 0 {
		saved = s.current != "" && strings.EqualFold(s.javas[idx-1].Path, s.current)
	}
	cur, tstyle := "  ", sText
	if idx == s.cursor {
		cur, tstyle = sCursorBar.Render("▸ "), sBold
	}
	dot := "  "
	if saved {
		dot = sOK.Render("● ")
	}
	tag := ""
	if idx > 0 && s.req > 0 && s.javas[idx-1].Major == s.req {
		tag = "  " + sOK.Render(i18n.S("✓ consigliato"))
	}
	line := cur + dot + tstyle.Render(title) + tag
	if sub != "" {
		line += "\n      " + sub
	}
	return line
}

// autoSub spiega cosa farebbe l'opzione "Automatico" adesso.
func (s *javaScreen) autoSub() string {
	if s.req <= 0 {
		return sMuted.Render(i18n.S("usa il runtime compatibile col modpack"))
	}
	for _, j := range s.javas {
		if j.Major == s.req {
			return sMuted.Render(i18n.S("→ userebbe ")) + sOK.Render("Java "+cmp.Or(j.Version, fmt.Sprintf("%d", j.Major)))
		}
	}
	return sWarn.Render(i18n.Sf("⚠ nessun Java %d installato", s.req))
}
