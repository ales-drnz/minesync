// Package tui: interfaccia testuale di minesync.
//
// Architettura: ogni schermata è un componente MVU autonomo (interface screen);
// App fa solo routing (stack), header/footer condivisi e connessioni globali
// (SSE eventi + ping latenza). Nessuna logica di dominio qui: vive in
// internal/session e internal/syncx.
package tui

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"minesync/client/internal/api"
	"minesync/client/internal/config"
	"minesync/client/internal/i18n"
	"minesync/client/internal/launch"
	"minesync/client/internal/mc"
	"minesync/client/internal/selfupdate"
	"minesync/client/internal/session"
	"minesync/client/internal/syncx"
	"minesync/client/internal/version"
)

type screen interface {
	init() tea.Cmd
	update(tea.Msg) (screen, tea.Cmd)
	view(w, h int) string
	title() string
	hints() []keyHint
}

// blocksGlobalKeys è implementata dalle schermate che usano q/esc per sé.
type blocksGlobalKeys interface{ blocksGlobal() bool }

// closer è implementata dalle schermate che hanno risorse da liberare quando
// escono dallo stack (contesti da cancellare). Il root la chiama sempre, da
// un unico punto: popScreen.
type closer interface{ close() }

// --- messaggi globali ---

type navPushMsg struct{ s screen }
type navPopMsg struct{}
type loginDoneMsg struct{ who api.Whoami } // login/join riuscito: riparti dalla home
type sseEventMsg struct{ ev api.Event }
type sseStateMsg struct{ connected bool }

// globalTickMsg: battito di refresh (5s) gestito dal ROOT e inoltrato alla
// schermata attiva — così il live-update non si perde navigando tra schermate.
type globalTickMsg struct{}
type pingMsg struct {
	latency    time.Duration
	err        error
	hubVersion string
	dnsZone    string
}

// whoamiMsg / whoamiErrMsg: esito di whoami. L'errore ha un tipo suo: se
// passasse da pingMsg farebbe partire un secondo loop di ping (R11).
type whoamiMsg struct {
	client *api.Client
	who    api.Whoami
}
type whoamiErrMsg struct {
	client *api.Client
	err    error
}
type updDoneMsg struct{ err error }
type restartMsg struct{} // l'utente ha scelto "Riavvia" nel popup di aggiornamento
type errMsg struct{ err error }
type flashMsg struct{ text string }
type flashClearMsg struct{ id int }

// langToggleMsg: l'utente ha chiesto di passare all'altra lingua.
type langToggleMsg struct{}

func toggleLang() tea.Msg { return langToggleMsg{} }

// quitSignalMsg: il terminale è stato chiuso (SIGHUP) mentre la TUI gira.
type quitSignalMsg struct{}

func push(s screen) tea.Cmd { return func() tea.Msg { return navPushMsg{s} } }
func pop() tea.Msg          { return navPopMsg{} }

// shutdownWait: quanto aspettiamo, uscendo, che una sessione di gioco ancora
// viva salvi e si fermi (stop → push finale → release del lock).
const shutdownWait = 60 * time.Second

// App è il modello radice.
type App struct {
	cfg    *config.Config
	client *api.Client
	who    api.Whoami

	width, height int
	stack         []screen

	connected bool
	latency   time.Duration
	flash     string
	flashID   int
	showHelp  bool // overlay '?' con l'elenco completo dei comandi

	sseStarted  bool
	pingStarted bool
	pingedOK    bool // primo ping riuscito: la versione corrente funziona

	// auto-aggiornamento: 0 niente, 1 in corso, 2 pronto (riavvia), 3 fallito
	updState         int
	updVer           string
	updPromptPending bool   // popup "riavvia" da mostrare appena la schermata è libera
	restart          bool   // uscendo, rilancia il binario aggiornato
	dnsZone          string // zona DNS dell'hub, per l'indirizzo fisso zerotier.<spazio>.<zona>

	sseCh   chan api.Event
	sseKick chan struct{} // forza la riconnessione SSE (es. cambio hub)
	ctx     context.Context
	cancel  context.CancelFunc

	// sessione di gioco viva: uscendo dalla TUI (normale, segnale o panic)
	// va fermata in modo pulito, altrimenti Java resta orfano (R2)
	live *playScreen

	// runtime Java: il rilevamento esegue `java -version` e non deve mai
	// girare nel thread UI (R7). Lista dei runtime installati + risoluzione
	// per spazio, entrambe in cache.
	javas       []mc.JavaInfo
	javasOK     bool
	javaCache   map[javaKey]javaRes
	javaPending map[javaKey]bool

	// pre-download ("warm cache"): un worker riempie la blob cache degli
	// spazi collegati così il pull di G è quasi istantaneo. Non tocca mai
	// la cartella del mondo, quindi è sicuro anche se interrotto.
	prefetchKick    chan []prefetchTarget
	prefetchCh      chan syncx.PrefetchStatus
	prefetch        map[string]syncx.PrefetchStatus // stato per spazio (per la home)
	prefetchStarted bool
	playActive      atomic.Bool // sessione di gioco in corso: il worker si ferma
}

// prefetchTarget è uno spazio da pre-scaricare (snapshot fatto nel thread UI:
// il worker non legge mai cfg direttamente).
type prefetchTarget struct {
	id     string
	client *api.Client
}

func newApp(cfg *config.Config) *App {
	ctx, cancel := context.WithCancel(context.Background())
	return &App{cfg: cfg, ctx: ctx, cancel: cancel,
		sseCh: make(chan api.Event, 64), sseKick: make(chan struct{}, 1),
		prefetchKick: make(chan []prefetchTarget, 4),
		prefetchCh:   make(chan syncx.PrefetchStatus, 64),
		prefetch:     map[string]syncx.PrefetchStatus{},
		javaCache:    map[javaKey]javaRes{},
		javaPending:  map[javaKey]bool{},
	}
}

// Run avvia la TUI.
func Run() (err error) {
	if !launch.HasTerminal() {
		// niente tty e nessun emulatore da aprire: senza questo messaggio
		// bubbletea direbbe solo "could not open a new TTY".
		return i18n.Errorf("serve un terminale: apri Konsole, GNOME Terminal o xterm ed esegui minesync da lì")
	}
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	app := newApp(cfg)
	defer app.cancel()
	// panic fuori da bubbletea (che recupera da solo quelli di Update/View):
	// prima di morire fermiamo comunque il server Java
	defer func() {
		if r := recover(); r != nil {
			app.shutdownLive()
			panic(r)
		}
	}()

	var first screen
	if cfg.Ready() {
		app.client = api.New(cfg.Server)
		first = newHome(app)
	} else {
		first = newSetup(app)
	}
	app.stack = []screen{first}
	p := tea.NewProgram(app, tea.WithAltScreen(), tea.WithMouseCellMotion())
	stopHangup := watchHangup(p)
	_, err = p.Run() // SIGINT/SIGTERM e panic li gestisce bubbletea: Run torna
	stopHangup()
	app.shutdownLive()
	if err == nil && app.restart {
		// il terminale è già stato ripristinato dall'uscita di bubbletea: ora
		// rilanciamo il binario aggiornato (su Unix rimpiazza il processo, su
		// Windows avvia il figlio, lo aspetta ed esce col suo codice).
		return relaunch()
	}
	return err
}

// watchHangup: bubbletea gestisce SIGINT/SIGTERM ma non SIGHUP (terminale
// chiuso), che di default ucciderebbe il processo lasciando Java orfano.
// Lo trasformiamo in un'uscita ordinata della TUI.
func watchHangup(p *tea.Program) (stop func()) {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGHUP)
	done := make(chan struct{})
	go func() {
		select {
		case <-ch:
			p.Send(quitSignalMsg{})
			// terminale sparito: se il renderer non riesce più a uscire, forza
			select {
			case <-done:
			case <-time.After(3 * time.Second):
				p.Kill()
			}
		case <-done:
		}
	}()
	return func() {
		signal.Stop(ch)
		close(done)
	}
}

// shutdownLive ferma in modo pulito una sessione di gioco ancora viva
// all'uscita della TUI: stop del server, push finale, release del lock.
// Aspetta al massimo shutdownWait; un secondo Ctrl+C (o SIGTERM/SIGHUP)
// passa all'arresto rapido (cancel del context: stop + kill dopo 30s).
func (a *App) shutdownLive() {
	l := a.live
	if l == nil || l.finished() {
		return
	}
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer signal.Stop(sigs)

	fmt.Fprintln(os.Stderr, i18n.S("MineSync: sessione di gioco ancora attiva — arresto del server e salvataggio sull'hub (max 60s, Ctrl+C di nuovo per accelerare)…"))
	if l.state < session.StateLaunching {
		l.cancel() // ancora in sincronizzazione: niente da salvare
	} else {
		l.sess.RequestStop()
	}
	timeout := time.NewTimer(shutdownWait)
	defer timeout.Stop()
	hard := func() {
		l.cancel()
		select {
		case <-l.sessDone:
		case <-time.After(35 * time.Second): // la sessione aspetta 30s poi uccide
		}
	}
	select {
	case <-l.sessDone:
		fmt.Fprintln(os.Stderr, i18n.S("MineSync: sessione chiusa."))
	case <-sigs:
		fmt.Fprintln(os.Stderr, i18n.S("MineSync: arresto rapido…"))
		hard()
	case <-timeout.C:
		fmt.Fprintln(os.Stderr, i18n.S("MineSync: il server non si è fermato in tempo, arresto forzato…"))
		hard()
	}
}

func (a *App) top() screen { return a.stack[len(a.stack)-1] }

// blocked: la schermata in cima usa per sé i tasti globali (q, esc, ?…).
func (a *App) blocked() bool {
	b, ok := a.top().(blocksGlobalKeys)
	return ok && b.blocksGlobal()
}

// maybeUpdatePrompt mostra il popup "riavvia per aggiornare" SOLO quando è
// sicuro: aggiornamento pronto, nessun popup già aperto, e la schermata in cima
// non è occupata (una sessione di gioco o un campo di testo bloccano i tasti
// globali). Altrimenti resta in sospeso e riproviamo al prossimo tick/ritorno.
func (a *App) maybeUpdatePrompt() tea.Cmd {
	if a.updState != 2 || !a.updPromptPending {
		return nil
	}
	if _, isConfirm := a.top().(*confirmScreen); isConfirm {
		return nil
	}
	if a.blocked() {
		return nil
	}
	a.updPromptPending = false
	return push(newRestartPrompt(a, a.updVer))
}

// newRestartPrompt: popup con "Riavvia" / "Non ora". Il chip in alto resta
// comunque come promemoria se l'utente rimanda.
func newRestartPrompt(app *App, ver string) *confirmScreen {
	c := newConfirm(app, i18n.S("Aggiornamento pronto"),
		i18n.Sf("MineSync %s è stato scaricato. Riavvio adesso per applicarlo?\n\n"+
			"Se stai per giocare scegli «Non ora»: l'aggiornamento resta pronto e puoi riavviare quando vuoi.", ver),
		i18n.S("Riavvia"), false, 1,
		func() tea.Msg { return restartMsg{} })
	c.cancelLabel = i18n.S("Non ora")
	c.choice = 1 // invio = Riavvia: qui il default utile è dire di sì (il popup
	// appare solo quando è sicuro, e riavviare non costa nulla). Gli altri
	// confirm restano su Annulla, che per force/restore/elimina è d'obbligo.
	return c
}

func (a *App) Init() tea.Cmd {
	cmds := []tea.Cmd{tea.SetWindowTitle("MineSync"), a.top().init(), a.tickCmd()}
	if a.client != nil {
		cmds = append(cmds, a.connections(), a.whoami())
	}
	return tea.Batch(cmds...)
}

func (a *App) tickCmd() tea.Cmd {
	return tea.Tick(5*time.Second, func(time.Time) tea.Msg { return globalTickMsg{} })
}

// connections avvia SSE e ping una sola volta (il goroutine SSE rilegge
// a.client a ogni riconnessione, quindi segue anche i cambi di hub).
func (a *App) connections() tea.Cmd {
	var cmds []tea.Cmd
	if !a.sseStarted {
		a.sseStarted = true
		cmds = append(cmds, a.startSSE())
	}
	if !a.pingStarted {
		a.pingStarted = true
		cmds = append(cmds, a.ping())
	}
	if !a.prefetchStarted {
		a.prefetchStarted = true
		go a.prefetchWorker()
		cmds = append(cmds, a.listenPrefetch())
	}
	return tea.Batch(cmds...)
}

// prefetchWorker consuma i kick e pre-scarica gli spazi indicati, uno alla
// volta. Si ferma da solo se nel frattempo è partita una sessione di gioco
// (la banda serve a chi hosta).
func (a *App) prefetchWorker() {
	cacheDir, err := config.CacheDir()
	if err != nil {
		return
	}
	for {
		select {
		case <-a.ctx.Done():
			return
		case targets := <-a.prefetchKick:
			for _, tg := range targets {
				if a.playActive.Load() || a.ctx.Err() != nil {
					break
				}
				eng := &syncx.Engine{
					Client: tg.client, SpaceID: tg.id,
					CachePath: filepath.Join(cacheDir, tg.id+".json"),
				}
				report := func(st syncx.PrefetchStatus) {
					select {
					case a.prefetchCh <- st:
					default: // UI indietro: si perde un aggiornamento, pazienza
					}
				}
				// errori silenziosi: è un'ottimizzazione, il pull vero rimedia
				eng.Prefetch(a.ctx, report)
			}
		}
	}
}

func (a *App) listenPrefetch() tea.Cmd {
	return func() tea.Msg {
		select {
		case st := <-a.prefetchCh:
			return st
		case <-a.ctx.Done():
			return nil
		}
	}
}

// kickPrefetch accoda un giro di pre-download per tutti gli spazi collegati
// (o solo per `only`, se indicato). Snapshot nel thread UI: niente race.
func (a *App) kickPrefetch(only string) {
	if a.client == nil {
		return
	}
	var ts []prefetchTarget
	for id := range a.cfg.Spaces {
		if only == "" || id == only {
			ts = append(ts, prefetchTarget{id: id, client: a.client})
		}
	}
	if len(ts) == 0 {
		return
	}
	select {
	case a.prefetchKick <- ts:
	default:
	}
}

// updatePlayActive tiene aggiornato il flag "si sta giocando" per il worker.
func (a *App) updatePlayActive() {
	active := false
	for _, s := range a.stack {
		if _, ok := s.(*playScreen); ok {
			active = true
			break
		}
	}
	a.playActive.Store(active)
}

// startSSE lancia lo stream eventi con riconnessione.
func (a *App) startSSE() tea.Cmd {
	go func() {
		for a.ctx.Err() == nil {
			ch := make(chan api.Event, 64)
			done := make(chan struct{})
			go func() {
				defer close(done)
				for e := range ch {
					select {
					case a.sseCh <- e:
					case <-a.ctx.Done():
						return
					}
				}
			}()
			// contesto per-connessione: un "kick" (cambio hub) la interrompe subito
			connCtx, connCancel := context.WithCancel(a.ctx)
			go func() {
				select {
				case <-a.sseKick:
					connCancel()
				case <-connCtx.Done():
				}
			}()
			a.client.StreamEvents(connCtx, ch)
			connCancel()
			close(ch)
			<-done
			select {
			case <-a.ctx.Done():
				return
			case <-time.After(3 * time.Second):
			}
		}
	}()
	return a.listenSSE()
}

func (a *App) listenSSE() tea.Cmd {
	return func() tea.Msg {
		select {
		case ev := <-a.sseCh:
			return sseEventMsg{ev}
		case <-a.ctx.Done():
			return nil
		}
	}
}

func (a *App) ping() tea.Cmd {
	client := a.client
	return tea.Tick(5*time.Second, func(time.Time) tea.Msg {
		start := time.Now()
		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
		defer cancel()
		st, err := client.Status(ctx)
		return pingMsg{latency: time.Since(start), err: err, hubVersion: st.Version, dnsZone: st.DNSZone}
	})
}

func (a *App) whoami() tea.Cmd {
	client := a.client
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		who, err := client.Whoami(ctx)
		if err != nil {
			return whoamiErrMsg{client: client, err: err}
		}
		return whoamiMsg{client: client, who: who}
	}
}

func (a *App) setFlash(text string) tea.Cmd {
	a.flash = text
	a.flashID++
	id := a.flashID
	return tea.Tick(4*time.Second, func(time.Time) tea.Msg { return flashClearMsg{id} })
}

// toggleLang passa all'altra lingua, subito (le viste si ridisegnano già
// tradotte) e per i prossimi avvii (config). MINESYNC_LANG, se impostata,
// vince comunque all'avvio.
func (a *App) toggleLang() tea.Cmd {
	l := i18n.Current().Other()
	i18n.Set(l)
	a.cfg.Lang = string(l)
	if err := a.cfg.Save(); err != nil {
		return a.setFlash(sErr.Render("✗ " + err.Error()))
	}
	return a.setFlash(sOK.Render(i18n.S("✔ lingua: italiano")))
}

// langHint: il tasto che cambia lingua, con la lingua di destinazione
// scritta in quella lingua (chi non capisce quella attuale la riconosce).
func langHint(key string, helpOnly bool) keyHint {
	return keyHint{key: key, label: i18n.S("lingua → English"), help: helpOnly}
}

// forwardTop inoltra msg alla schermata in cima allo stack.
func (a *App) forwardTop(msg tea.Msg) tea.Cmd {
	ns, cmd := a.top().update(msg)
	a.stack[len(a.stack)-1] = ns
	return cmd
}

// popScreen è l'UNICO punto in cui una schermata esce dallo stack: chiude le
// sue risorse (close), aggiorna il flag di gioco e rilancia i lavori sospesi.
func (a *App) popScreen() tea.Cmd {
	if len(a.stack) <= 1 {
		return nil
	}
	old := a.top()
	a.stack = a.stack[:len(a.stack)-1]
	if c, ok := old.(closer); ok {
		c.close()
	}
	a.updatePlayActive()
	if _, wasPlay := old.(*playScreen); wasPlay {
		a.kickPrefetch("") // fine sessione: riallinea la blob cache
	}
	// tornati a una schermata libera (es. fine sessione): eventuale popup update
	return a.maybeUpdatePrompt()
}

func (a *App) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		a.width, a.height = msg.Width, msg.Height
		// propaga a tutte le schermate nello stack
		var cmds []tea.Cmd
		for i, s := range a.stack {
			ns, cmd := s.update(msg)
			a.stack[i] = ns
			cmds = append(cmds, cmd)
		}
		return a, tea.Batch(cmds...)
	case tea.KeyMsg:
		if cmd, handled := a.handleKey(msg); handled {
			return a, cmd
		}
	case navPushMsg, navPopMsg, loginDoneMsg:
		return a, a.handleNav(msg)
	case pingMsg, updDoneMsg, restartMsg:
		return a, a.handleUpdate(msg)
	case quitSignalMsg:
		return a, tea.Quit
	case whoamiMsg:
		if msg.client == a.client {
			a.who = msg.who
			a.kickPrefetch("") // connessi: pre-scarica gli spazi collegati
		}
		return a, nil
	case whoamiErrMsg:
		if msg.client != a.client {
			return a, nil // risposta di un hub che non usiamo più
		}
		// il ping (unico loop) aggiorna lo stato di connessione; qui
		// riproviamo solo whoami, più tardi
		retry := a.whoami()
		return a, tea.Tick(10*time.Second, func(time.Time) tea.Msg { return retry() })
	case javaResolvedMsg, javasDetectedMsg:
		return a, tea.Batch(a.handleJava(msg), a.forwardTop(msg))
	case syncx.PrefetchStatus:
		a.prefetch[msg.SpaceID] = msg
		return a, tea.Batch(a.forwardTop(msg), a.listenPrefetch())
	case sseEventMsg:
		a.connected = true
		// qualcuno ha pushato uno spazio che abbiamo collegato: pre-scarica
		// subito i blob nuovi, così il prossimo G non aspetta la rete
		if msg.ev.Type == "push" && !a.playActive.Load() {
			if _, linked := a.cfg.Spaces[msg.ev.Space]; linked {
				a.kickPrefetch(msg.ev.Space)
			}
		}
		return a, tea.Batch(a.forwardTop(msg), a.listenSSE())
	case globalTickMsg:
		// il root riarma SEMPRE; e se un aggiornamento aspetta, prova a mostrare il popup
		return a, tea.Batch(a.forwardTop(msg), a.tickCmd(), a.maybeUpdatePrompt())
	case sseStateMsg:
		a.connected = msg.connected
		return a, nil
	case langToggleMsg:
		return a, a.toggleLang()
	case flashMsg:
		return a, a.setFlash(msg.text)
	case flashClearMsg:
		if msg.id == a.flashID {
			a.flash = ""
		}
		return a, nil
	case errMsg:
		return a, a.setFlash(sErr.Render("✗ " + msg.err.Error()))
	}
	return a, a.forwardTop(msg)
}

// handleKey gestisce i tasti globali. handled=false: il tasto va alla schermata.
func (a *App) handleKey(msg tea.KeyMsg) (cmd tea.Cmd, handled bool) {
	// overlay di aiuto aperto: un tasto qualsiasi lo chiude (e non arriva alla schermata)
	if a.showHelp {
		a.showHelp = false
		return nil, true
	}
	if a.blocked() {
		return nil, false
	}
	switch msg.String() {
	case "?":
		a.showHelp = true
		return nil, true
	case "ctrl+c":
		return tea.Quit, true
	case "q":
		if len(a.stack) > 1 {
			return pop, true
		}
		return tea.Quit, true
	case "esc":
		if len(a.stack) > 1 {
			return pop, true
		}
	}
	return nil, false
}

// handleNav gestisce i cambi di schermata.
func (a *App) handleNav(msg tea.Msg) tea.Cmd {
	switch msg := msg.(type) {
	case navPushMsg:
		a.stack = append(a.stack, msg.s)
		a.updatePlayActive()
		return msg.s.init()
	case navPopMsg:
		return a.popScreen()
	case loginDoneMsg:
		a.who = msg.who
		select { // stacca subito l'eventuale stream SSE del vecchio hub
		case a.sseKick <- struct{}{}:
		default:
		}
		for _, s := range a.stack {
			if c, ok := s.(closer); ok {
				c.close()
			}
		}
		home := newHome(a)
		a.stack = []screen{home}
		a.updatePlayActive()
		a.kickPrefetch("")
		return tea.Batch(home.init(), a.connections(),
			a.setFlash(sOK.Render(i18n.Sf("✔ connesso a %s come %s", a.cfg.Server, msg.who.Name))))
	}
	return nil
}

// handleUpdate gestisce ping e auto-aggiornamento.
func (a *App) handleUpdate(msg tea.Msg) tea.Cmd {
	switch msg := msg.(type) {
	case pingMsg:
		a.connected = msg.err == nil
		var cmds []tea.Cmd
		if msg.err == nil {
			a.latency = msg.latency
			a.dnsZone = msg.dnsZone
			if !a.pingedOK {
				// questa versione parla con l'hub: il backup dell'update
				// precedente non serve più (C6)
				a.pingedOK = true
				selfupdate.CleanupOld()
			}
			// hub strettamente più nuovo → auto-aggiornamento silenzioso in
			// background (mai downgrade, mai da/verso build "dev")
			if a.updState == 0 && version.Newer(msg.hubVersion, version.Client) {
				a.updState = 1
				a.updVer = msg.hubVersion
				server, hubVer := a.cfg.Server, msg.hubVersion
				cmds = append(cmds, func() tea.Msg {
					return updDoneMsg{selfupdate.Apply(context.Background(), server, hubVer)}
				})
			}
		}
		return tea.Batch(append(cmds, a.forwardTop(msg), a.ping())...)
	case updDoneMsg:
		if msg.err != nil {
			a.updState = 3 // riproveremo al prossimo avvio; non disturbare
			return nil
		}
		a.updState = 2
		a.updPromptPending = true // il chip in alto resta; il popup appare appena è sicuro
		return tea.Batch(
			a.setFlash(sOK.Render(i18n.Sf("✔ client aggiornato alla v%s — riavvia per applicare", a.updVer))),
			a.maybeUpdatePrompt())
	case restartMsg:
		a.restart = true
		return tea.Quit
	}
	return nil
}

func (a *App) View() string {
	if a.width == 0 {
		return i18n.S("avvio…")
	}
	if a.width < 70 || a.height < 20 {
		return lipgloss.Place(a.width, a.height, lipgloss.Center, lipgloss.Center,
			sWarn.Render(i18n.S("Allarga il terminale (minimo 70×20)")))
	}
	header := a.viewHeader()
	hints := a.footerHints()
	var footer string
	if a.flash != "" {
		footer = lipgloss.NewStyle().Padding(0, 1).Width(a.width).Render(a.flash)
	} else {
		footer = keybar(a.width, hints...)
	}
	bodyH := a.height - lipgloss.Height(header) - lipgloss.Height(footer)
	body := a.top().view(a.width, bodyH)
	if a.showHelp {
		body = a.helpOverlay(a.width, bodyH, hints)
	}
	body = lipgloss.NewStyle().Height(bodyH).MaxHeight(bodyH).Render(body)
	return header + "\n" + body + "\n" + footer
}

// footerHints: tasti della schermata + quelli globali (esc, ?).
func (a *App) footerHints() []keyHint {
	hints := a.top().hints()
	blocked := a.blocked()
	// esc sempre visibile: attivo se si può tornare indietro, oscurato se no
	hasEsc := false
	for _, h := range hints {
		if h.key == "esc" {
			hasEsc = true
			break
		}
	}
	if !hasEsc {
		hints = append(hints, keyHint{key: "esc", label: i18n.S("indietro"),
			off: len(a.stack) == 1 || blocked})
	}
	// "? aiuto" nel footer, così l'overlay è scopribile (non quando bloccati,
	// dove '?' è testo per la console)
	if !blocked {
		hints = append(hints, keyHint{key: "?", label: i18n.S("aiuto")})
	}
	return hints
}

// helpOverlay disegna l'elenco completo dei comandi del contesto corrente,
// centrato. Riceve gli hint già composti (contesto + globali).
func (a *App) helpOverlay(w, h int, hints []keyHint) string {
	var rows []string
	rows = append(rows, sBold.Render(i18n.S("Comandi")), "")
	for _, hint := range hints {
		key := sKeycap.Render(fmt.Sprintf("%-8s", hint.key))
		rows = append(rows, key+" "+sText.Render(hint.label))
	}
	rows = append(rows, "", sFaint.Render(i18n.S("un tasto qualsiasi per chiudere")))
	box := sPanel.Padding(1, 3).Render(lipgloss.JoinVertical(lipgloss.Left, rows...))
	return lipgloss.Place(w, h, lipgloss.Center, lipgloss.Center, box)
}

func (a *App) viewHeader() string {
	left := sTitle.Render("❒ MineSync") + sFaint.Render(" "+version.Display())
	crumb := sMuted.Render(" › ") + sBold.Render(a.top().title())

	right := ""
	if a.client != nil {
		conn := sErr.Render("○ offline")
		if a.connected {
			conn = sOK.Render("●") + sMuted.Render(fmt.Sprintf(" %dms", a.latency.Milliseconds()))
		}
		user := ""
		if a.who.Name != "" {
			user = sMuted.Render("  ") + sText.Render(a.who.Name)
			if a.who.Admin {
				user += sMuted.Render(" (admin)")
			}
		}
		upd := ""
		if a.updState == 2 {
			upd = sWarn.Render(i18n.Sf("  ⟳ riavvia per v%s", a.updVer)) + " "
		}
		right = upd + conn + user
	}
	gap := a.width - lipgloss.Width(left) - lipgloss.Width(crumb) - lipgloss.Width(right) - 2
	if gap < 1 {
		gap = 1
	}
	line := sHeader.Render(left + crumb + lipgloss.NewStyle().Width(gap).Render("") + right)
	rule := sFaint.Render(strings.Repeat("─", max(a.width, 0)))
	return line + "\n" + rule
}
