package tui

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"minesync/client/internal/api"
	"minesync/client/internal/config"
	"minesync/client/internal/i18n"
	"minesync/client/internal/mc"
	"minesync/client/internal/syncx"
)

// spaceScreen: dashboard di uno spazio (pre-sessione).
type spaceScreen struct {
	app     *App
	id      string
	sp      api.Space
	gens    []api.GenSummary
	local   string // cartella locale collegata ("" se no)
	info    mc.ServerInfo
	loaded  bool
	loadErr string

	linking   bool
	linkInput textinput.Model

	syncing  bool // pull/push standalone in corso
	progress syncx.Progress
	syncKind string
	pump     func() tea.Msg // legge il prossimo progresso del sync in corso
}

type spaceDataMsg struct {
	sp   api.Space
	gens []api.GenSummary
	err  error
}
type lockGrantedMsg struct {
	session      string
	tookOver     *api.LockInfo
	discardLocal bool
}
type lockBusyMsg struct {
	holder *api.LockInfo
	stale  bool
}
type syncProgressMsg struct{ p syncx.Progress }
type syncDoneMsg struct {
	kind string
	err  error
	note string
}
type spaceRefreshMsg struct{}

func newSpaceScreen(app *App, id string) *spaceScreen {
	li := textinput.New()
	li.Prompt = "  "
	li.Width = 56
	li.Placeholder = i18n.S(`es. C:\Minecraft\MioMondo oppure /home/tu/miomondo`)
	return &spaceScreen{app: app, id: id, linkInput: li}
}

func (s *spaceScreen) title() string { return s.id }
func (s *spaceScreen) hints() []keyHint {
	if s.linking {
		return []keyHint{{key: i18n.S("invio"), label: i18n.S("collega")}, {key: "esc", label: i18n.S("annulla")}}
	}
	h := []keyHint{}
	if s.canPlay() {
		h = append(h, keyHint{key: "g", label: i18n.S("GIOCA")})
	}
	if s.local != "" {
		h = append(h, keyHint{key: "p", label: "pull"}, keyHint{key: "u", label: "push"}, keyHint{key: "v", label: i18n.S("verifica")})
	}
	if s.sp.Profile == "minecraft" && s.local != "" {
		h = append(h, keyHint{key: "j", label: "java"})
	}
	h = append(h, keyHint{key: "l", label: i18n.S("cartella")}, keyHint{key: "s", label: i18n.S("storia")})
	if s.canForceRelease() {
		h = append(h, keyHint{key: "f", label: i18n.S("forza sblocco")})
	}
	return h
}

func (s *spaceScreen) canPlay() bool {
	return s.sp.Profile == "minecraft" && !s.syncing
}

// canForceRelease: forzare il lock di un altro è concesso solo se il lock è
// stale (heartbeat fermo) oppure a un admin (C2, lato hub è lo stesso).
func (s *spaceScreen) canForceRelease() bool {
	return s.sp.Lock != nil && (s.sp.LockStale || s.app.who.Admin)
}

// defaultLocalPath è la cartella usata se l'utente non ne sceglie una.
func defaultLocalPath(spaceID string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		home = "."
	}
	return filepath.Join(home, "MineSync", spaceID)
}

// setLocal collega la cartella e ne rilegge la fotografia (solo lettura).
func (s *spaceScreen) setLocal(path string) tea.Cmd {
	s.local = path
	s.info = mc.Inspect(path)
	return s.requestJava()
}

// ensureLinked collega automaticamente la cartella di default se serve.
func (s *spaceScreen) ensureLinked() error {
	if s.local != "" {
		return nil
	}
	path := defaultLocalPath(s.id)
	if err := os.MkdirAll(path, 0o755); err != nil {
		return err
	}
	if err := s.saveLocal(path); err != nil {
		return err
	}
	s.setLocal(path)
	return nil
}

// saveLocal salva in config la cartella dello spazio.
func (s *spaceScreen) saveLocal(path string) error {
	sc := s.app.cfg.Spaces[s.id]
	sc.LocalPath = path // preserva JavaPath ed eventuali altri campi
	s.app.cfg.Spaces[s.id] = sc
	return s.app.cfg.Save()
}

// requestJava fa risolvere (fuori dal thread UI, con cache nell'App) il
// runtime che verrà usato per questo server.
func (s *spaceScreen) requestJava() tea.Cmd {
	if s.sp.Profile == "generic" || s.local == "" {
		return nil
	}
	return s.app.requestJava(s.id, s.info)
}

func (s *spaceScreen) blocksGlobal() bool { return s.linking || s.syncing }

func (s *spaceScreen) init() tea.Cmd {
	var cmds []tea.Cmd
	if sc, ok := s.app.cfg.Spaces[s.id]; ok && sc.LocalPath != "" {
		cmds = append(cmds, s.setLocal(sc.LocalPath))
	}
	return tea.Batch(append(cmds, s.load())...)
}

func (s *spaceScreen) load() tea.Cmd {
	client := s.app.client
	id := s.id
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		sp, err := client.Space(ctx, id)
		if err != nil {
			return spaceDataMsg{err: err}
		}
		gens, _ := client.Generations(ctx, id, 8)
		return spaceDataMsg{sp: sp, gens: gens}
	}
}

func (s *spaceScreen) engine() *syncx.Engine {
	cacheDir, _ := config.CacheDir()
	return &syncx.Engine{
		Client: s.app.client, SpaceID: s.id, LocalPath: s.local,
		CachePath: filepath.Join(cacheDir, s.id+".json"),
		Matcher:   syncx.NewMatcher(s.sp.Ignore),
	}
}

func (s *spaceScreen) update(msg tea.Msg) (screen, tea.Cmd) {
	switch msg := msg.(type) {
	case spaceDataMsg:
		s.loaded = true
		if msg.err != nil {
			s.loadErr = msg.err.Error()
			return s, nil
		}
		s.loadErr = ""
		s.sp = msg.sp
		s.gens = msg.gens
		return s, s.requestJava()

	case spaceRefreshMsg:
		return s, s.load()

	case globalTickMsg:
		if !s.syncing && !s.linking {
			return s, tea.Batch(s.load(), s.requestJava())
		}
		return s, nil

	case sseEventMsg:
		if msg.ev.Space == s.id {
			return s, s.load()
		}
		return s, nil

	case syncProgressMsg:
		s.progress = msg.p
		if s.pump != nil {
			return s, s.pump
		}
		return s, nil

	case syncDoneMsg:
		s.syncing = false
		if msg.err != nil {
			return s, func() tea.Msg { return errMsg{msg.err} }
		}
		return s, tea.Batch(s.load(),
			func() tea.Msg { return flashMsg{sOK.Render("✔ " + msg.note)} })

	case lockGrantedMsg:
		note := ""
		if msg.tookOver != nil {
			note = i18n.Sf("Lock stale di %s rimpiazzato.", msg.tookOver.Owner)
		}
		res, _ := s.app.cachedJava(s.id, s.info)
		return s, push(newPlay(s.app, s.sp, s.local, playOptions{
			lockSession: msg.session, note: note, java: res.java, discardLocal: msg.discardLocal}))

	case lockBusyMsg:
		return s, s.onLockBusy(msg)

	case replayMsg:
		if msg.space == s.id && s.canPlay() {
			return s, s.acquireAndPlay(msg.discardLocal)
		}
		return s, nil

	case tea.KeyMsg:
		if s.linking {
			return s, s.handleLinkKey(msg)
		}
		if s.syncing {
			return s, nil
		}
		return s, s.handleKey(msg)
	}
	return s, nil
}

// onLockBusy: qualcuno sta giocando. Forzare è concesso solo su lock stale o
// agli admin; agli altri spieghiamo chi tiene il lock.
func (s *spaceScreen) onLockBusy(msg lockBusyMsg) tea.Cmd {
	holder := msg.holder
	if !msg.stale && !s.app.who.Admin {
		return func() tea.Msg {
			return errMsg{i18n.Errorf("%s sta giocando (ultimo heartbeat %s): aspetta che chiuda la sessione",
				holder.Owner, agoShort(holder.LastBeat))}
		}
	}
	body := i18n.Sf(
		"%s ha una sessione attiva (ultimo heartbeat %s).\n\n"+
			"Forzando il rilascio mentre gioca, i progressi non ancora salvati andranno persi.",
		holder.Owner, agoShort(holder.LastBeat))
	return push(newConfirm(s.app, i18n.S("Sessione in corso"), body, i18n.S("Forza e gioca"), true, 2,
		s.forceAndPlay()))
}

func (s *spaceScreen) handleLinkKey(msg tea.KeyMsg) tea.Cmd {
	switch msg.String() {
	case "esc":
		s.linking = false
		return nil
	case "enter":
		path := s.linkInput.Value()
		if path == "" {
			return nil
		}
		abs, err := filepath.Abs(path)
		if err != nil || s.saveLocal(abs) != nil {
			return nil
		}
		s.linking = false
		return tea.Batch(s.setLocal(abs),
			func() tea.Msg { return flashMsg{sOK.Render(i18n.S("✔ cartella collegata"))} })
	}
	var cmd tea.Cmd
	s.linkInput, cmd = s.linkInput.Update(msg)
	return cmd
}

func (s *spaceScreen) handleKey(msg tea.KeyMsg) tea.Cmd {
	switch msg.String() {
	case "l":
		s.linking = true
		s.linkInput.SetValue(s.local)
		s.linkInput.Focus()
		return textinput.Blink
	case "g":
		if s.canPlay() {
			if err := s.ensureLinked(); err != nil {
				return func() tea.Msg { return errMsg{err} }
			}
			return s.acquireAndPlay(false)
		}
	case "p":
		if err := s.ensureLinked(); err == nil {
			return s.startSync("pull")
		}
	case "u":
		if s.local != "" {
			return s.startSync("push")
		}
	case "v":
		if s.local != "" {
			return s.verifyWorld()
		}
	case "j":
		if s.sp.Profile == "minecraft" && s.local != "" {
			return push(newJavaScreen(s.app, s.id, s.info))
		}
	case "s":
		return push(newHistory(s.app, s.id))
	case "f":
		if s.canForceRelease() {
			holder := s.sp.Lock
			stages := 2
			verb := i18n.Sf("Il lock di %s è attivo: se sta giocando, perderà i progressi non salvati.", holder.Owner)
			if s.sp.LockStale {
				stages = 1
				verb = i18n.Sf("Il lock di %s è scaduto (heartbeat fermo da %s). Il rilascio è sicuro.", holder.Owner, agoShort(holder.LastBeat))
			}
			return push(newConfirm(s.app, i18n.S("Forzare il rilascio?"), verb, i18n.S("Rilascia"), !s.sp.LockStale, stages,
				s.forceRelease()))
		}
	case "r":
		return s.load()
	}
	return nil
}

// startSync esegue pull o push standalone con progresso live.
func (s *spaceScreen) startSync(kind string) tea.Cmd {
	s.syncing = true
	s.syncKind = kind
	s.progress = syncx.Progress{}
	eng := s.engine()
	progCh := make(chan syncx.Progress, 32)
	eng.Report = func(p syncx.Progress) {
		select {
		case progCh <- p:
		default:
		}
	}
	client, id, msg := s.app.client, s.id, i18n.Sf("push manuale di %s", s.app.who.Name)
	doneCh := make(chan syncDoneMsg, 1)
	go func() {
		ctx := context.Background()
		if kind == "pull" {
			plan, err := eng.Pull(ctx)
			doneCh <- syncDoneMsg{kind: kind, err: err,
				note: i18n.Sf("pull: generazione #%d, %d file", plan.Gen, len(plan.Download))}
		} else {
			res, err := manualPush(ctx, client, eng, id, msg)
			note := i18n.S("push: nessuna modifica")
			if err == nil && !res.NoChange {
				note = i18n.Sf("push: generazione #%d (%s)", res.Gen.N, humanBytes(res.Bytes))
			}
			doneCh <- syncDoneMsg{kind: kind, err: err, note: note}
		}
		close(progCh)
	}()
	s.pump = func() tea.Msg {
		if p, ok := <-progCh; ok {
			return syncProgressMsg{p}
		}
		return <-doneCh
	}
	return s.pump
}

// manualPush (C2): niente più nolock. Il push manuale prende il lock come una
// sessione di gioco, pusha legato a quella sessione e lo rilascia. Se qualcuno
// sta giocando, l'errore dice chi.
func manualPush(ctx context.Context, client *api.Client, eng *syncx.Engine, id, msg string) (syncx.PushResult, error) {
	lctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	lk, err := client.LockAcquire(lctx, id, map[string]string{"action": "push"})
	cancel()
	if err != nil {
		var ae *api.APIError
		if errors.As(err, &ae) && ae.Status == 409 && ae.Holder != nil {
			return syncx.PushResult{}, i18n.Errorf("push non possibile: %s ha il lock (sta giocando)", ae.Holder.Owner)
		}
		return syncx.PushResult{}, err
	}
	defer func() {
		rctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		client.LockRelease(rctx, id, lk.Session, false)
	}()
	eng.LockSession = lk.Session
	return eng.Push(ctx, msg, false)
}

func (s *spaceScreen) acquireAndPlay(discardLocal bool) tea.Cmd {
	client := s.app.client
	id := s.id
	// pubblica nel lock dove raggiungere il server: gli altri lo vedono
	// nella dashboard e nella web UI
	info := map[string]string{"action": "play"}
	if ips := mc.LocalIPs(); len(ips) > 0 {
		info["host"] = strings.Join(ips, ",")
	}
	info["port"] = cmp.Or(s.info.Port, "25565")
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		res, err := client.LockAcquire(ctx, id, info)
		if err != nil {
			var ae *api.APIError
			if errors.As(err, &ae) && ae.Status == 409 && ae.Holder != nil {
				return lockBusyMsg{holder: ae.Holder, stale: ae.Stale}
			}
			return errMsg{err}
		}
		return lockGrantedMsg{session: res.Session, tookOver: res.TookOver, discardLocal: discardLocal}
	}
}

func (s *spaceScreen) forceAndPlay() tea.Cmd {
	release := s.forceRelease()
	acquire := s.acquireAndPlay(false)
	return func() tea.Msg {
		if m, ok := release().(errMsg); ok {
			return m
		}
		return acquire()
	}
}

// verifyWorld controlla l'integrità dei region file locali (checkRegion su
// tutti, non solo quelli cambiati) e riporta l'esito nel flash.
func (s *spaceScreen) verifyWorld() tea.Cmd {
	local := s.local
	ignore := s.sp.Ignore
	return func() tea.Msg {
		problems, checked, err := syncx.VerifyWorld(local, syncx.NewMatcher(ignore))
		if err != nil {
			return errMsg{err}
		}
		if len(problems) == 0 {
			return flashMsg{sOK.Render(i18n.Sf("✔ integrità: %d region controllati, tutti sani", checked))}
		}
		return flashMsg{sErr.Render(i18n.Sf("✗ %d region danneggiati (es. %s) — ripristina dalla web UI", len(problems), problems[0].Path))}
	}
}

func (s *spaceScreen) forceRelease() tea.Cmd {
	client := s.app.client
	id := s.id
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := client.LockRelease(ctx, id, "", true); err != nil {
			return errMsg{err}
		}
		return spaceRefreshMsg{}
	}
}

func (s *spaceScreen) view(w, h int) string {
	if !s.loaded {
		return lipgloss.Place(w, h, lipgloss.Center, lipgloss.Center, sMuted.Render(i18n.S("carico…")))
	}
	if s.loadErr != "" {
		return lipgloss.Place(w, h, lipgloss.Center, lipgloss.Center, sErr.Render("✗ "+s.loadErr))
	}
	colW := (w - 1) / 2
	top := lipgloss.JoinHorizontal(lipgloss.Top, s.viewStatus(colW), " ", s.viewLocal(colW))
	if s.syncing {
		return lipgloss.JoinVertical(lipgloss.Left, top, s.viewTransfer(w))
	}
	return lipgloss.JoinVertical(lipgloss.Left, top, s.viewHistory(w))
}

// viewStatus: generazione, lock, ultimo push e dove entrare in gioco.
func (s *spaceScreen) viewStatus(colW int) string {
	lockState, lockTxt := "free", sFaint.Render(i18n.S("libero — nessuno in gioco"))
	if s.sp.Lock != nil {
		if s.sp.LockStale {
			lockState = "stale"
			lockTxt = sWarn.Render(i18n.Sf("STALE di %s (fermo %s)", s.sp.Lock.Owner, agoShort(s.sp.Lock.LastBeat)))
		} else {
			lockState = "held"
			lockTxt = sOK.Render(i18n.Sf("in gioco: %s (da %s)", s.sp.Lock.Owner, agoShort(s.sp.Lock.Since)))
		}
	}
	rows := []string{
		sMuted.Render(i18n.S("generazione  ")) + sBold.Render(fmt.Sprintf("#%d", s.sp.Head)),
		sMuted.Render("lock         ") + lockDot(lockState) + " " + lockTxt,
	}
	if len(s.gens) > 0 {
		g := s.gens[0]
		rows = append(rows,
			sMuted.Render(i18n.S("ultimo push  "))+sText.Render(fmt.Sprintf("%s · %s", g.Author, agoShort(g.TS))))
	}
	// qualcuno sta hostando: chi è online e dove entrare
	if s.sp.Lock != nil && !s.sp.LockStale {
		if n := len(s.sp.Lock.Players); n > 0 {
			rows = append(rows,
				sMuted.Render("online       ")+sOK.Render(fmt.Sprintf("%d ", n))+
					sText.Render(truncate(strings.Join(s.sp.Lock.Players, ", "), colW-20)))
		}
		if s.sp.Lock.Info["host"] != "" {
			port := cmp.Or(s.sp.Lock.Info["port"], "25565")
			rows = append(rows, "", sPanelTitle.Render(" "+i18n.S("ENTRA IN GIOCO SU")+" "))
			// indirizzo fisso (l'hub fa da DNS): sempre lo stesso, risolve a chi hosta
			if s.app.dnsZone != "" {
				rows = append(rows,
					sOK.Render(" ▸ ")+sBold.Render(fmt.Sprintf("zerotier.%s.%s", s.id, s.app.dnsZone)),
					sMuted.Render("   "+i18n.S("(indirizzo fisso, uguale per tutti)")))
			}
			for _, ip := range strings.Split(s.sp.Lock.Info["host"], ",") {
				rows = append(rows, sMuted.Render(" · ")+sText.Render(ip+":"+port))
			}
		}
	}
	return panel(i18n.S("stato hub"), lipgloss.JoinVertical(lipgloss.Left, rows...), colW, false)
}

// viewLocal: cartella collegata, loader, start script e runtime Java.
func (s *spaceScreen) viewLocal(colW int) string {
	var rows []string
	if s.local == "" {
		rows = []string{
			sMuted.Render(i18n.S("Nessuna cartella collegata. Con G verrà usata:")),
			sText.Render(truncate(defaultLocalPath(s.id), colW-6)),
			sMuted.Render(i18n.S("(premi 'l' per sceglierne un'altra)"))}
	} else {
		rows = []string{sMuted.Render(i18n.S("cartella  ")) + sText.Render(truncate(s.local, colW-14))}
		if s.sp.Profile == "minecraft" {
			script := sErr.Render(i18n.S("non so come avviarlo"))
			if len(s.info.Launch) > 0 {
				script = sOK.Render(launchLabel(s.info))
			}
			loader := s.info.Loader
			if s.info.Version != "" {
				loader += " " + s.info.Version
			}
			rows = append(rows,
				sMuted.Render("loader    ")+sText.Render(orDash(loader)),
				sMuted.Render("script    ")+script,
				sMuted.Render("runtime   ")+s.javaText())
		}
	}
	if s.linking {
		rows = append(rows, "", sPanelTitle.Render(" "+i18n.S("PERCORSO")+" "), s.linkInput.View())
	}
	return panel(i18n.S("copia locale"), lipgloss.JoinVertical(lipgloss.Left, rows...), colW, s.linking)
}

// javaText descrive il runtime risolto (dalla cache: la View non esegue nulla).
func (s *spaceScreen) javaText() string {
	res, ok := s.app.cachedJava(s.id, s.info)
	switch {
	case !ok:
		return sMuted.Render(i18n.S("rilevo java…"))
	case !res.java.Found:
		return sErr.Render(i18n.S("mancante! (premi j)"))
	case res.java.Unverified:
		// dentro la cartella sincronizzata: non lo eseguiamo prima del Play (S7)
		return sText.Render(i18n.S("java del modpack (verificato al Play)"))
	}
	v := cmp.Or(res.java.Version, "ok")
	// avvisa solo se è PIÙ VECCHIO del richiesto: un Java più nuovo di
	// solito va (ed è una scelta esplicita dell'utente)
	if res.req > 0 && res.java.Major > 0 && res.java.Major < res.req {
		return sWarn.Render(i18n.Sf("java %s ⚠ serve %d (premi j)", v, res.req))
	}
	return sOK.Render("java " + v)
}

// viewHistory: timeline delle ultime generazioni.
func (s *spaceScreen) viewHistory(w int) string {
	var tl []string
	for _, g := range s.gens {
		mark := sFaint.Render("│")
		bullet := sMuted.Render("●")
		if g.N == s.sp.Head {
			bullet = sOK.Render("●")
		}
		if g.Restore > 0 {
			bullet = sWarn.Render("⟲")
		}
		msg := cmp.Or(g.Message, i18n.S("salvataggio"))
		tl = append(tl,
			fmt.Sprintf("%s %s %s  %s",
				bullet, sBold.Render(fmt.Sprintf("#%-3d", g.N)),
				sText.Render(truncate(msg, w-46)),
				sMuted.Render(fmt.Sprintf("%s · %s · %s", g.Author, agoShort(g.TS), humanBytes(g.Stats.Bytes)))),
			mark)
	}
	if len(tl) > 0 {
		tl = tl[:len(tl)-1]
	} else {
		tl = []string{sMuted.Render(i18n.S("Ancora nessuna generazione: fai il primo push (u)."))}
	}
	return panel(i18n.S("storia recente"), lipgloss.JoinVertical(lipgloss.Left, tl...), w, false)
}

// viewTransfer: avanzamento del pull/push standalone.
func (s *spaceScreen) viewTransfer(w int) string {
	p := s.progress
	frac := 0.0
	if p.TotalBytes > 0 {
		frac = float64(p.DoneBytes) / float64(p.TotalBytes)
	}
	speedTxt := humanSpeed(p.Speed)
	if eta := humanETA(p.DoneBytes, p.TotalBytes, p.Speed); eta != "" {
		speedTxt += "  " + eta
	}
	rows := []string{
		sBold.Render(i18n.Sf("%s in corso — fase: ", s.syncKind)) + sOK.Render(p.Phase),
		"",
		progressBar(w-14, frac),
		"",
		i18n.Sf("%s  %s / %s   %s   %d/%d file",
			sMuted.Render(i18n.S("trasferiti")), humanBytes(p.DoneBytes), humanBytes(p.TotalBytes),
			sOK.Render(speedTxt), p.DoneFiles, p.TotalFiles),
	}
	for i, f := range p.Active {
		if i >= 6 {
			break
		}
		rows = append(rows, sFaint.Render("  ↕ ")+sMuted.Render(truncate(f, w-16)))
	}
	return panel(i18n.S("trasferimento"), lipgloss.JoinVertical(lipgloss.Left, rows...), w, true)
}

func orDash(s string) string {
	if s == "" {
		return "—"
	}
	return s
}
