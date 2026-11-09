package tui

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"minesync/client/internal/api"
	"minesync/client/internal/config"
	"minesync/client/internal/i18n"
	"minesync/client/internal/mc"
	"minesync/client/internal/session"
	"minesync/client/internal/syncx"
)

// playStatusW è la larghezza della colonna dei pannelli di stato.
const playStatusW = 34

// lagWindow: finestra della spia "server in affanno".
const lagWindow = 2 * time.Minute

// playScreen: sessione di gioco viva (pull → server → console → autosave → stop).
type playScreen struct {
	app   *App
	sp    api.Space
	local string

	sess     *session.Session
	cancel   context.CancelFunc
	sessDone chan struct{} // chiuso quando sess.Run è tornata

	state     session.State
	progress  syncx.Progress
	players   []string
	lastGen   int
	lastSave  time.Time
	notes     []noteLine
	done      bool
	doneErr   error
	stopAsked bool
	started   time.Time

	console   viewport.Model
	log       consoleBuffer
	searching bool // l'input sta modificando la ricerca, non la console
	input     textinput.Model
	history   []string // comandi già inviati (↑/↓ per ripescarli)
	histPos   int      // posizione nella cronologia (len = riga nuova)
	histCur   string   // riga in corso, parcheggiata mentre si scorre
	follow    bool
	ready     bool
	w, h      int

	launchAt time.Time   // avvio dello script: da qui parte il ritmo autosave
	lagTimes []time.Time // righe "Can't keep up!" recenti (spia server in affanno)

	addrs  []string // IP di questa macchina (ZeroTier per primo)
	port   string   // porta del server Minecraft
	script string   // nome dello start script
	java   string   // versione java ("" se assente)
}

// playTickMsg: battito da un secondo, solo per uptime e countdown autosave.
type playTickMsg struct{}

type noteLine struct {
	text string
	warn bool
	ts   time.Time
}

// sessBatchMsg raggruppa gli eventi in coda: durante lo spam della console
// (avvio/spegnimento di Forge) processarli uno per messaggio congelava la UI.
type sessBatchMsg struct {
	evs    []session.Event
	closed bool
}
type sessClosedMsg struct{}

// playOptions sono le scelte fatte prima del Play.
type playOptions struct {
	lockSession  string
	note         string
	java         mc.JavaInfo // runtime già risolto dalla dashboard (Found=false: decide la sessione)
	discardLocal bool        // C7: l'utente ha scelto di scartare le modifiche locali
}

func newPlay(app *App, sp api.Space, local string, opt playOptions) *playScreen {
	in := textinput.New()
	in.Prompt = sOK.Render("» ")
	in.Placeholder = i18n.S("comando console (es. list, say ciao)…")
	in.CharLimit = 256
	in.Focus()

	cacheDir, _ := config.CacheDir()
	// il runtime l'ha già trovato la dashboard: la sessione lo usa così com'è
	// invece di rilevarlo di nuovo (R7)
	javaPath := app.cfg.Spaces[sp.ID].JavaPath
	// (un runtime incluso nel pack, non ancora verificato, lo sceglie invece la
	// sessione con la sua classifica: è lei che può eseguirlo, dopo il Play)
	if opt.java.Found && opt.java.Path != "" && !opt.java.Unverified {
		javaPath = opt.java.Path
	}
	ctx, cancel := context.WithCancel(context.Background())
	sess := session.New(session.Config{
		Client: app.client, SpaceID: sp.ID, LocalPath: local,
		CachePath: filepath.Join(cacheDir, sp.ID+".json"),
		Ignore:    sp.Ignore, Owner: app.who.Name, LockSession: opt.lockSession,
		JavaPath: javaPath, DiscardLocal: opt.discardLocal,
	})
	info := mc.Inspect(local)
	p := &playScreen{
		app: app, sp: sp, local: local, sess: sess, cancel: cancel,
		sessDone: make(chan struct{}),
		input:    in, follow: true, started: time.Now(),
		addrs: mc.LocalIPs(), port: cmp.Or(info.Port, "25565"),
		script: launchLabel(info),
	}
	switch {
	case opt.java.Unverified:
		p.java = i18n.S("dal modpack") // versione nota solo dopo l'avvio (S7)
	case opt.java.Found:
		p.java = cmp.Or(opt.java.Version, "ok")
	}
	if opt.note != "" {
		p.notes = append(p.notes, noteLine{text: opt.note, warn: true, ts: time.Now()})
	}
	app.live = p // uscendo dalla TUI la sessione va fermata, non abbandonata (R2)
	go func() {
		defer close(p.sessDone)
		sess.Run(ctx)
	}()
	return p
}

// finished riporta se la goroutine della sessione è terminata.
func (p *playScreen) finished() bool {
	select {
	case <-p.sessDone:
		return true
	default:
		return false
	}
}

// close: la schermata esce dallo stack (solo a sessione finita: prima i
// tasti globali sono bloccati).
func (p *playScreen) close() {
	p.cancel()
	if p.app.live == p && p.finished() {
		p.app.live = nil
	}
}

func (p *playScreen) title() string      { return p.sp.ID + " · " + i18n.S("sessione") }
func (p *playScreen) blocksGlobal() bool { return !p.done }
func (p *playScreen) hints() []keyHint {
	if p.done {
		return []keyHint{{key: "esc", label: i18n.S("chiudi")}}
	}
	if p.searching {
		return []keyHint{{key: i18n.S("invio"), label: i18n.S("applica ricerca")}, {key: "esc", label: i18n.S("annulla")},
			{key: "ctrl+g", label: i18n.S("chiudi ricerca")}}
	}
	return []keyHint{{key: i18n.S("invio"), label: i18n.S("comando")}, {key: "↑↓", label: i18n.S("cronologia")},
		{key: "ctrl+s", label: i18n.S("salva")}, {key: "ctrl+x", label: "STOP"},
		{key: "ctrl+f", label: i18n.S("filtro")}, {key: "ctrl+g", label: i18n.S("cerca")},
		{key: "ctrl+e", label: "autostop"}}
}

func (p *playScreen) init() tea.Cmd { return tea.Batch(p.listen(), textinput.Blink, p.tick()) }

func (p *playScreen) tick() tea.Cmd {
	return tea.Tick(time.Second, func(time.Time) tea.Msg { return playTickMsg{} })
}

func (p *playScreen) listen() tea.Cmd {
	events := p.sess.Events()
	return func() tea.Msg {
		ev, ok := <-events
		if !ok {
			return sessClosedMsg{}
		}
		batch := sessBatchMsg{evs: []session.Event{ev}}
		for len(batch.evs) < 512 { // svuota la coda senza bloccare
			select {
			case ev2, ok2 := <-events:
				if !ok2 {
					batch.closed = true
					return batch
				}
				batch.evs = append(batch.evs, ev2)
			default:
				return batch
			}
		}
		return batch
	}
}

func (p *playScreen) update(msg tea.Msg) (screen, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		p.w, p.h = msg.Width, msg.Height
		p.layout()
		return p, nil
	case sessBatchMsg:
		return p, p.handleBatch(msg)
	case sessClosedMsg:
		p.done = true
		return p, nil
	case playTickMsg:
		p.pruneLag(time.Now())
		if p.done {
			return p, nil // il battito muore con la sessione
		}
		return p, p.tick() // il re-render avviene da solo: basta riarmare
	case tea.MouseMsg:
		p.handleMouse(msg)
		return p, nil
	case tea.KeyMsg:
		return p, p.handleKey(msg)
	}
	return p, nil
}

// handleBatch applica gli eventi della sessione arrivati in blocco.
func (p *playScreen) handleBatch(msg sessBatchMsg) tea.Cmd {
	hadConsole := false
	for _, ev := range msg.evs {
		if ev.Kind == session.EvConsole {
			hadConsole = true
		}
		p.applyEvent(ev)
	}
	if hadConsole {
		p.refreshConsole() // un solo SetContent per batch, non per riga
	}
	// C7: modifiche locali mai pushate e hub andato avanti → chiedi all'utente
	var dirty *syncx.DirtyLocalError
	if p.done && errors.As(p.doneErr, &dirty) && dirty.Diverged() {
		return tea.Sequence(pop, push(newDiscardConfirm(p.app, p.sp.ID, p.local, dirty)))
	}
	if msg.closed {
		p.done = true
		return nil
	}
	return p.listen()
}

func (p *playScreen) handleMouse(msg tea.MouseMsg) {
	switch msg.Button {
	case tea.MouseButtonWheelUp:
		p.console.ScrollUp(3)
		p.follow = false
	case tea.MouseButtonWheelDown:
		p.console.ScrollDown(3)
		if p.console.AtBottom() {
			p.follow = true
		}
	}
}

// handleKey smista i tasti: scroll, controlli di sessione, cronologia,
// ricerca; il resto va all'input. (esc/q a sessione finita li gestisce il
// root: la schermata non blocca più i tasti globali.)
func (p *playScreen) handleKey(msg tea.KeyMsg) tea.Cmd {
	if p.handleScrollKey(msg) || p.handleSessionKey(msg) {
		return nil
	}
	switch msg.String() {
	case "esc":
		if p.searching { // esc = annulla la ricerca
			p.exitSearch(true)
		}
		return nil
	case "ctrl+g":
		p.toggleSearch()
		return nil
	case "up", "down":
		if p.handleHistoryKey(msg.String()) {
			return nil
		}
	case "enter":
		p.submit()
		return nil
	}
	var cmd tea.Cmd
	p.input, cmd = p.input.Update(msg)
	if p.searching && p.log.setSearch(p.input.Value()) { // la ricerca filtra mentre scrivi
		p.console.SetContent(p.log.content())
		p.console.GotoBottom()
	}
	return cmd
}

// handleScrollKey gestisce lo scorrimento della console.
func (p *playScreen) handleScrollKey(msg tea.KeyMsg) bool {
	switch msg.String() {
	case "pgup":
		p.console.HalfPageUp()
		p.follow = false
	case "pgdown":
		p.console.HalfPageDown()
		if p.console.AtBottom() {
			p.follow = true
		}
	case "end":
		p.console.GotoBottom()
		p.follow = true
	default:
		return false
	}
	return true
}

// handleSessionKey gestisce stop, salvataggio, filtro e autostop.
func (p *playScreen) handleSessionKey(msg tea.KeyMsg) bool {
	switch msg.String() {
	case "ctrl+c", "ctrl+x":
		// Ctrl+C durante la sessione = stop pulito, non uscita brutale
		if !p.done && !p.stopAsked {
			p.stopAsked = true
			p.sess.RequestStop()
			p.addNote(i18n.S("Arresto richiesto: salvataggio finale e chiusura in corso."), false)
		}
	case "ctrl+s":
		if !p.done && p.state == session.StateRunning {
			p.sess.RequestSaveNow() // ciclo completo: flush + push sull'hub
		}
	case "ctrl+f":
		p.log.cycleFilter()
		p.console.SetContent(p.log.content())
		if p.follow {
			p.console.GotoBottom()
		}
	case "ctrl+e":
		if p.done {
			break
		}
		// autostop on/off (default 30m): si vede nel pannello sessione
		if p.sess.AutoStop() > 0 {
			p.sess.SetAutoStop(0)
			p.addNote(i18n.S("Arresto automatico disattivato."), false)
		} else {
			p.sess.SetAutoStop(session.DefaultEmptyStop)
			p.addNote(i18n.S("Arresto automatico attivo: dopo 30 minuti senza giocatori."), false)
		}
	default:
		return false
	}
	return true
}

// handleHistoryKey scorre la cronologia dei comandi (↑/↓). false = lascia
// il tasto all'input (in ricerca, a sessione finita o senza cronologia).
func (p *playScreen) handleHistoryKey(key string) bool {
	if p.searching || p.done || len(p.history) == 0 {
		return false
	}
	if key == "up" && p.histPos > 0 {
		if p.histPos == len(p.history) {
			p.histCur = p.input.Value() // parcheggia la riga in corso
		}
		p.histPos--
		p.input.SetValue(p.history[p.histPos])
		p.input.CursorEnd()
	} else if key == "down" && p.histPos < len(p.history) {
		p.histPos++
		if p.histPos == len(p.history) {
			p.input.SetValue(p.histCur)
		} else {
			p.input.SetValue(p.history[p.histPos])
		}
		p.input.CursorEnd()
	}
	return true
}

// toggleSearch: l'input diventa il campo di ricerca nel log (live); un
// secondo ctrl+g la spegne e restituisce l'input alla console.
func (p *playScreen) toggleSearch() {
	if p.searching {
		p.exitSearch(true)
		return
	}
	if p.done {
		return
	}
	p.searching = true
	p.histCur = p.input.Value()
	p.input.Prompt = sWarn.Render(i18n.S("cerca") + " » ")
	p.input.SetValue(p.log.search)
	p.input.CursorEnd()
}

// submit: invio conferma la ricerca o manda il comando alla console.
func (p *playScreen) submit() {
	if p.searching { // conferma la ricerca e torna alla console
		p.exitSearch(false)
		return
	}
	cmd := strings.TrimSpace(p.input.Value())
	if cmd == "" || p.done {
		return
	}
	p.sess.SendCommand(cmd)
	if len(p.history) == 0 || p.history[len(p.history)-1] != cmd {
		p.history = append(p.history, cmd)
		if len(p.history) > 100 {
			p.history = p.history[len(p.history)-100:]
		}
	}
	p.histPos = len(p.history)
	p.histCur = ""
	p.input.SetValue("")
}

// exitSearch chiude la modalità ricerca; con cancel azzera anche il filtro.
func (p *playScreen) exitSearch(cancel bool) {
	if cancel {
		p.log.search = ""
	}
	p.searching = false
	p.input.Prompt = sOK.Render("» ")
	p.input.SetValue(p.histCur)
	p.input.CursorEnd()
	p.histCur = ""
	p.log.rewrap()
	p.console.SetContent(p.log.content())
	if p.follow {
		p.console.GotoBottom()
	}
}

func (p *playScreen) applyEvent(ev session.Event) {
	switch ev.Kind {
	case session.EvState:
		if ev.State == session.StateLaunching && p.launchAt.IsZero() {
			p.launchAt = time.Now() // il ticker dell'autosave parte da qui
		}
		p.state = ev.State
	case session.EvProgress:
		p.progress = ev.Progress
	case session.EvConsole:
		p.log.append(ev.Line)
		// spia lag: quante volte il server si è lamentato negli ultimi 2 minuti
		if isLagLine(strings.ToLower(ev.Line)) {
			p.lagTimes = append(p.lagTimes, time.Now())
		}
	case session.EvNote:
		// le info di routine vivono già nei riquadri strutturati:
		// nel pannello avvisi finiscono solo i warning veri
		if ev.Warn {
			p.addNote(ev.Note, true)
		}
	case session.EvPlayers:
		p.players = ev.Players
	case session.EvSaved:
		p.lastGen = ev.Gen
		p.lastSave = time.Now()
	case session.EvDone:
		p.done = true
		p.doneErr = ev.Err
		if ev.Err != nil {
			p.addNote(ev.Err.Error(), true)
		} else {
			p.addNote(i18n.S("Sessione terminata. Stato salvato sull'hub."), false)
		}
	}
}

// pruneLag toglie le segnalazioni di lag più vecchie della finestra: senza
// questo la spia "in affanno" non si spegneva più (R13).
func (p *playScreen) pruneLag(now time.Time) {
	i := 0
	for i < len(p.lagTimes) && now.Sub(p.lagTimes[i]) > lagWindow {
		i++
	}
	p.lagTimes = p.lagTimes[i:]
}

func (p *playScreen) addNote(text string, warn bool) {
	p.notes = append(p.notes, noteLine{text: text, warn: warn, ts: time.Now()})
	if len(p.notes) > 4 {
		p.notes = p.notes[len(p.notes)-4:]
	}
}

// isLagLine riconosce il server che arranca (tick in ritardo).
func isLagLine(lower string) bool {
	return strings.Contains(lower, "can't keep up") || strings.Contains(lower, "running") &&
		strings.Contains(lower, "behind")
}

// refreshConsole aggiorna la viewport (chiamata una volta per batch).
func (p *playScreen) refreshConsole() {
	if !p.ready {
		return
	}
	p.console.SetContent(p.log.content())
	if p.follow {
		p.console.GotoBottom()
	}
}

func (p *playScreen) layout() {
	// larghezza pannello = w-playStatusW-1; bordi (2) + padding (2) → interno -4
	conW := max(p.w-playStatusW-5, 20)
	conH := max(p.h-7, 5)
	if !p.ready {
		p.console = viewport.New(conW, conH)
		p.ready = true
	} else {
		p.console.Width = conW
		p.console.Height = conH
	}
	p.log.setWidth(conW)
	p.console.SetContent(p.log.content())
	if p.follow {
		p.console.GotoBottom()
	}
	p.input.Width = conW - 4
}

func (p *playScreen) view(w, h int) string {
	if !p.ready {
		p.w, p.h = w, h+4
		p.layout()
	}
	var panels []string
	for _, pn := range []string{p.viewSession(), p.viewServer(), p.viewAddress(),
		p.viewPlayers(), p.viewTransfer(), p.viewNotes()} {
		if pn != "" {
			panels = append(panels, pn)
		}
	}
	statusPanel := lipgloss.JoinVertical(lipgloss.Left, panels...)
	return lipgloss.JoinHorizontal(lipgloss.Top, statusPanel, " ", p.viewConsole())
}

func lbl(k, v string) string { return sMuted.Render(k) + sText.Render(v) }

// viewSession: stato, uptime, ultimo salvataggio, autosave, autostop, lag.
func (p *playScreen) viewSession() string {
	stateTxt := sBold.Render(p.state.String())
	switch p.state {
	case session.StateRunning:
		stateTxt = sOK.Render("● " + p.state.String())
	case session.StateFailed:
		stateTxt = sErr.Render("✗ " + p.state.String())
	case session.StateSaving, session.StatePushing:
		stateTxt = sWarn.Render("◌ " + p.state.String())
	case session.StateDone:
		stateTxt = sOK.Render("✔ " + p.state.String())
	}
	rows := []string{
		stateTxt,
		lbl("uptime    ", time.Since(p.started).Round(time.Second).String()),
		lbl(i18n.S("versione  "), genTxt(p.lastGen, p.sp.Head)),
		lbl(i18n.S("salvato   "), agoShort(p.lastSave)),
	}
	// countdown al prossimo autosave: il ticker parte con lo script
	if p.state == session.StateRunning && !p.launchAt.IsZero() {
		every := session.DefaultAutosaveEvery
		left := every - time.Since(p.launchAt)%every
		rows = append(rows, lbl("autosave  ", i18n.Sf("tra %s", left.Round(time.Second))))
	}
	autostopTxt := sFaint.Render("off (ctrl+e)")
	if d := p.sess.AutoStop(); d > 0 {
		autostopTxt = sText.Render(i18n.Sf("%dm se vuoto", int(d.Minutes())))
	}
	rows = append(rows, sMuted.Render("autostop  ")+autostopTxt)
	// il server si lamenta di essere in ritardo sui tick: fallo notare
	if len(p.lagTimes) >= 2 && p.state == session.StateRunning {
		rows = append(rows, sWarn.Render(i18n.Sf("⚠ in affanno (%d avvisi/2m)", len(p.lagTimes))))
	}
	return panel(i18n.S("sessione"), lipgloss.JoinVertical(lipgloss.Left, rows...), playStatusW, false)
}

func (p *playScreen) viewServer() string {
	javaTxt := sErr.Render(i18n.S("mancante!"))
	if p.java != "" {
		javaTxt = sText.Render(p.java)
	}
	return panel("server", lipgloss.JoinVertical(lipgloss.Left,
		lbl("script    ", truncate(p.script, playStatusW-16)),
		sMuted.Render("java      ")+javaTxt,
		lbl(i18n.S("porta     "), p.port),
		lbl(i18n.S("cartella  "), truncate(p.local, playStatusW-16)),
	), playStatusW, false)
}

// viewAddress: dove si collegano i giocatori + esito del test porta.
func (p *playScreen) viewAddress() string {
	if len(p.addrs) == 0 || p.state != session.StateRunning {
		return ""
	}
	var rows []string
	for i, ip := range p.addrs {
		st := sText
		if i == 0 {
			st = sBold
		}
		rows = append(rows, sOK.Render("▸ ")+st.Render(ip+":"+p.port))
	}
	// esito del test porta fatto dall'hub (prospettiva dei giocatori)
	switch r := p.sess.Reachable(); {
	case r == nil:
		rows = append(rows, sMuted.Render(i18n.S("test porta in corso…")))
	case *r:
		rows = append(rows, sOK.Render(i18n.S("● porta raggiungibile")))
	default:
		rows = append(rows, sErr.Render(i18n.S("✗ porta bloccata (firewall)")))
	}
	return panel(i18n.S("indirizzo per i giocatori"), lipgloss.JoinVertical(lipgloss.Left, rows...), playStatusW, false)
}

func (p *playScreen) viewPlayers() string {
	if len(p.players) == 0 {
		return ""
	}
	var rows []string
	for _, pl := range p.players {
		rows = append(rows, sOK.Render("◆ ")+sText.Render(pl))
	}
	return panel(i18n.Sf("giocatori (%d)", len(p.players)),
		lipgloss.JoinVertical(lipgloss.Left, rows...), playStatusW, false)
}

func (p *playScreen) viewTransfer() string {
	if p.state != session.StatePulling && p.state != session.StatePushing {
		return ""
	}
	pr := p.progress
	frac := 0.0
	if pr.TotalBytes > 0 {
		frac = float64(pr.DoneBytes) / float64(pr.TotalBytes)
	}
	speedTxt := humanSpeed(pr.Speed)
	if eta := humanETA(pr.DoneBytes, pr.TotalBytes, pr.Speed); eta != "" {
		speedTxt += " · " + eta
	}
	rows := []string{
		progressBar(playStatusW-6, frac),
		sMuted.Render(i18n.Sf("%d/%d file · %s", pr.DoneFiles, pr.TotalFiles, speedTxt)),
	}
	if pr.Current != "" {
		rows = append(rows, sFaint.Render(truncate("↕ "+pr.Current, playStatusW-6)))
	}
	return panel(i18n.S("trasferimento"), lipgloss.JoinVertical(lipgloss.Left, rows...), playStatusW, true)
}

func (p *playScreen) viewNotes() string {
	if len(p.notes) == 0 {
		return ""
	}
	var rows []string
	for _, n := range p.notes {
		st := sMuted
		if n.warn {
			st = sWarn
		}
		for _, l := range wrapText(n.text, playStatusW-6) {
			rows = append(rows, st.Render(l))
		}
	}
	return panel(i18n.S("avvisi"), lipgloss.JoinVertical(lipgloss.Left, rows...), playStatusW, false)
}

// viewConsole: log del server + riga di input.
func (p *playScreen) viewConsole() string {
	consolePanel := panel(p.log.title(p.searching, p.follow), p.console.View(), p.w-playStatusW-1, true)
	inputLine := lipgloss.NewStyle().PaddingLeft(1).Render(p.input.View())
	if p.done {
		inputLine = lipgloss.NewStyle().PaddingLeft(1).Render(
			sMuted.Render(i18n.S("sessione terminata — premi esc per tornare indietro")))
	}
	return lipgloss.JoinVertical(lipgloss.Left, consolePanel, inputLine)
}

// newDiscardConfirm (C7): il mondo locale ha modifiche mai pushate e l'hub nel
// frattempo è andato avanti. Si può scartarle (con backup) e ripartire, o
// annullare e sistemare a mano.
func newDiscardConfirm(app *App, spaceID, local string, e *syncx.DirtyLocalError) *confirmScreen {
	backup := filepath.Join(filepath.Dir(local), ".minesync-backup", spaceID+"-…")
	body := i18n.Sf(
		"La copia locale ha modifiche mai salvate sull'hub: %d file cambiati, %d eliminati "+
			"(base: generazione #%d, hub ora a #%d).\n\n"+
			"Scartandole, il Play riparte dalla versione dell'hub. I file locali toccati "+
			"vengono prima copiati in:\n%s\n\nAnnulla per lasciare tutto com'è.",
		len(e.Changed), len(e.Removed), e.BaseGen, e.HubHead, backup)
	c := newConfirm(app, i18n.S("Modifiche locali non salvate"), body,
		i18n.S("Scarta le modifiche locali"), true, 1,
		func() tea.Msg { return replayMsg{space: spaceID, discardLocal: true} })
	return c
}

// replayMsg chiede alla dashboard dello spazio di ripartire col Play.
type replayMsg struct {
	space        string
	discardLocal bool
}

func genTxt(last, head int) string {
	if last == 0 {
		return fmt.Sprintf("#%d (hub)", head)
	}
	return fmt.Sprintf("#%d", last)
}

func wrapText(s string, w int) []string {
	if w < 8 {
		w = 8
	}
	words := strings.Fields(s)
	var lines []string
	cur := ""
	for _, word := range words {
		if cur == "" {
			cur = word
		} else if len(cur)+1+len(word) <= w {
			cur += " " + word
		} else {
			lines = append(lines, cur)
			cur = word
		}
	}
	if cur != "" {
		lines = append(lines, cur)
	}
	return lines
}
