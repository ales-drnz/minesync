// Package session: orchestratore headless di una sessione di gioco.
// Macchina a stati esplicita, indipendente dalla UI: la TUI (o una CLI)
// consuma gli eventi e invia richieste, tutta la logica vive qui.
package session

import (
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"minesync/client/internal/api"
	"minesync/client/internal/i18n"
	"minesync/client/internal/mc"
	"minesync/client/internal/syncx"
)

// State è lo stato corrente della sessione.
type State int

const (
	StateIdle State = iota
	StatePulling
	StateLaunching
	StateRunning
	StateSaving   // save-off + flush in corso
	StatePushing  // push (autosave o finale)
	StateStopping // stop inviato, attesa exit
	StateDone
	StateFailed
)

func (s State) String() string {
	switch s {
	case StateIdle:
		return i18n.S("pronto")
	case StatePulling:
		return i18n.S("sincronizzazione")
	case StateLaunching:
		return i18n.S("avvio server")
	case StateRunning:
		return i18n.S("in gioco")
	case StateSaving:
		return i18n.S("salvataggio mondo")
	case StatePushing:
		return i18n.S("push sull'hub")
	case StateStopping:
		return i18n.S("arresto server")
	case StateDone:
		return i18n.S("terminata")
	case StateFailed:
		return i18n.S("errore")
	}
	return "?"
}

// EventKind distingue i tipi di evento della sessione.
type EventKind int

const (
	EvState EventKind = iota
	EvProgress
	EvConsole
	EvNote
	EvPlayers
	EvSaved // autosave+push completato
	EvDone  // sessione finita (Err eventuale)
)

// Event è una notifica della sessione verso la UI.
type Event struct {
	Kind     EventKind
	State    State
	Progress syncx.Progress
	Line     string
	Note     string
	Warn     bool
	// Alert: avviso bloccante (con Kind=EvNote e Warn=true), da mostrare in
	// modo che non passi inosservato: oggi il lock perso, che ferma il server.
	Alert   bool
	Players []string
	Gen     int
	Err     error
}

// ErrLockLost: il lock dello spazio non è più nostro (forzato da un altro,
// scaduto durante un'assenza di rete). La sessione ferma il server e non
// pusha: il mondo resta solo sul disco locale.
var ErrLockLost = i18n.NewError("lock perso")

// Default della sessione (esportati: la TUI li mostra e li usa nei countdown).
const (
	DefaultAutosaveEvery = 5 * time.Minute  // come promesso dal README
	DefaultEmptyStop     = 30 * time.Minute // server vuoto da tanto → stop pulito
	DefaultMaxRestarts   = 2                // riavvii automatici dopo un crash
)

// Spegnimento: quanto si aspetta prima di considerare il processo piantato.
// closeIdleKill è tempo di SILENZIO della console, non tempo assoluto: uno
// spegnimento onesto stampa "Saving chunks for level …" per ogni dimensione e
// su un modpack grosso dura minuti. closeHardKill è il tetto oltre il quale
// non si aspetta comunque più.
const (
	closeIdleKill = 90 * time.Second
	closeHardKill = 15 * time.Minute
	// attesa della conferma di salvataggio: si riarma a ogni riga di
	// avanzamento, quindi su mondi grandi non scade a metà lavoro
	flushWait = 60 * time.Second
)

// Config di una sessione.
type Config struct {
	Client         *api.Client
	SpaceID        string
	LocalPath      string
	CachePath      string
	Ignore         []string
	Owner          string
	LockSession    string // lock già acquisito dal chiamante
	JavaPath       string // eseguibile java scelto ("" = auto dal modpack)
	AutosaveEvery  time.Duration
	HeartbeatEvery time.Duration
	EmptyStopAfter time.Duration // 0 = usa il default; <0 = disattivo
	MaxRestarts    int           // riavvii automatici post-crash (<0 = nessuno)
	// DiscardLocal: il pull iniziale scarta le modifiche locali non pushate
	// (con backup) invece di fermarsi con un DirtyLocalError divergente.
	DiscardLocal bool
}

// Session orchestra lock-heartbeat, pull, processo Java, autosave e push.
type Session struct {
	cfg     Config
	eng     *syncx.Engine
	events  chan Event
	saveNow chan struct{}

	mu         sync.Mutex
	state      State
	sup        *mc.Supervisor
	players    map[string]bool
	stopReq    bool
	lockLost   bool // il lock non è più nostro: niente più push
	released   bool // lock rilasciato da noi: i 409 dell'heartbeat sono attesi
	lastGen    int
	autoStop   time.Duration // 0 = disattivo (modificabile live dalla TUI)
	emptySince time.Time     // da quando il server è senza giocatori
	ready      bool          // server Minecraft avviato (abilita il test porta)
	reachable  *bool         // esito test porta dall'hub (nil = non ancora noto)
}

// New prepara una sessione (senza avviarla).
func New(cfg Config) *Session {
	if cfg.AutosaveEvery <= 0 {
		cfg.AutosaveEvery = DefaultAutosaveEvery
	}
	if cfg.HeartbeatEvery <= 0 {
		cfg.HeartbeatEvery = 20 * time.Second
	}
	if cfg.EmptyStopAfter == 0 {
		cfg.EmptyStopAfter = DefaultEmptyStop
	}
	if cfg.MaxRestarts == 0 {
		cfg.MaxRestarts = DefaultMaxRestarts
	}
	s := &Session{
		cfg:     cfg,
		events:  make(chan Event, 512),
		saveNow: make(chan struct{}, 1),
		players: map[string]bool{},
		state:   StateIdle,
	}
	if cfg.EmptyStopAfter > 0 {
		s.autoStop = cfg.EmptyStopAfter
	}
	s.eng = &syncx.Engine{
		Client: cfg.Client, SpaceID: cfg.SpaceID,
		LocalPath: cfg.LocalPath, CachePath: cfg.CachePath,
		Matcher:      syncx.NewMatcher(cfg.Ignore),
		Report:       func(p syncx.Progress) { s.emit(Event{Kind: EvProgress, Progress: p}) },
		LockSession:  cfg.LockSession,
		DiscardLocal: cfg.DiscardLocal,
	}
	return s
}

// Events è il canale da consumare nella UI.
func (s *Session) Events() <-chan Event { return s.events }

// LastGen è l'ultima generazione pushata in questa sessione.
func (s *Session) LastGen() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lastGen
}

func (s *Session) emit(e Event) {
	select {
	case s.events <- e:
	default: // UI bloccata: meglio perdere un progress che bloccare la sessione
	}
}

func (s *Session) setState(st State) {
	s.mu.Lock()
	s.state = st
	s.mu.Unlock()
	s.emit(Event{Kind: EvState, State: st})
}

// note e warn ricevono testo già tradotto (i18n.S/Sf al chiamante).
func (s *Session) note(msg string) {
	s.emit(Event{Kind: EvNote, Note: msg})
}

func (s *Session) warn(msg string) {
	s.emit(Event{Kind: EvNote, Note: msg, Warn: true})
}

// warnCorrupt segnala i region file danneggiati appena salvati: sono già
// sull'hub come nuova generazione, ma marcati — dalla web UI si può ripristinare
// la versione integra del singolo file.
func (s *Session) warnCorrupt(res syncx.PushResult) {
	if len(res.Corrupt) == 0 {
		return
	}
	s.warn(i18n.Sf("Attenzione: %d region file risultano danneggiati (es. %s). La generazione è marcata; ripristina la versione integra dalla web UI.",
		len(res.Corrupt), res.Corrupt[0]))
}

// SendCommand inoltra un comando alla console del server.
// "stop" digitato a mano equivale a RequestStop (così il flusso di chiusura
// pulita parte comunque: push finale, release, sblocco del pause del .bat).
func (s *Session) SendCommand(cmd string) {
	if strings.EqualFold(strings.TrimSpace(cmd), "stop") {
		s.RequestStop()
		return
	}
	s.mu.Lock()
	sup := s.sup
	s.mu.Unlock()
	if sup != nil {
		sup.Send(cmd)
	}
}

// RequestSaveNow chiede subito un ciclo autosave completo (flush + push).
func (s *Session) RequestSaveNow() {
	select {
	case s.saveNow <- struct{}{}:
	default:
	}
}

// AutoStop riporta il timeout corrente dell'auto-stop (0 = disattivo).
func (s *Session) AutoStop() time.Duration {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.autoStop
}

// Reachable riporta l'esito del test porta dall'hub (nil = non ancora noto).
func (s *Session) Reachable() *bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.reachable
}

// updateReachable memorizza l'esito e avvisa solo quando cambia.
func (s *Session) updateReachable(r *bool) {
	if r == nil {
		return
	}
	s.mu.Lock()
	changed := s.reachable == nil || *s.reachable != *r
	s.reachable = r
	s.mu.Unlock()
	if !changed {
		return
	}
	if *r {
		s.note(i18n.S("Porta raggiungibile: i giocatori possono connettersi."))
	} else {
		s.warn(i18n.Sf("La porta %s non risponde dall'hub: consentila nel firewall del sistema (via ZeroTier non serve il port forwarding).", s.portHint()))
	}
}

func (s *Session) portHint() string {
	if p := mc.Inspect(s.cfg.LocalPath).Port; p != "" {
		return p
	}
	return "25565"
}

// SetAutoStop cambia (o disattiva, con 0) l'auto-stop a server vuoto.
func (s *Session) SetAutoStop(d time.Duration) {
	s.mu.Lock()
	s.autoStop = d
	s.emptySince = time.Time{} // riparte il conteggio da adesso
	if d > 0 && len(s.players) == 0 {
		s.emptySince = time.Now()
	}
	s.mu.Unlock()
}

// RequestStop avvia lo spegnimento pulito (stop → push finale → release).
func (s *Session) RequestStop() {
	s.mu.Lock()
	sup, already := s.sup, s.stopReq
	s.stopReq = true
	s.mu.Unlock()
	if already {
		return
	}
	if sup != nil && sup.Running() {
		s.setState(StateStopping)
		sup.Send("stop")
	}
}

// itoaOr rende un major di Java come stringa, "" se ignoto.
func itoaOr(n int) string {
	if n <= 0 {
		return ""
	}
	return strconv.Itoa(n)
}

func orDefault(v, def string) string {
	if v == "" {
		return def
	}
	return v
}

func humanDur(d time.Duration) string {
	m := int(d.Minutes())
	if m < 60 {
		return fmt.Sprintf("%dm", m)
	}
	return fmt.Sprintf("%dh %dm", m/60, m%60)
}

func humanBytes(n int64) string {
	switch {
	case n > 1e9:
		return fmt.Sprintf("%.2f GB", float64(n)/1e9)
	case n > 1e6:
		return fmt.Sprintf("%.1f MB", float64(n)/1e6)
	case n > 1e3:
		return fmt.Sprintf("%.0f kB", float64(n)/1e3)
	}
	return fmt.Sprintf("%d B", n)
}
