package session

import (
	"context"
	"errors"
	"sort"
	"strings"
	"time"

	"minesync/client/internal/api"
	"minesync/client/internal/i18n"
	"minesync/client/internal/mc"
	"minesync/client/internal/syncx"
)

// Run esegue l'intera sessione. Blocca fino alla fine (da chiamare in goroutine).
func (s *Session) Run(ctx context.Context) {
	defer close(s.events)
	err := s.run(ctx)
	if err != nil {
		s.setState(StateFailed)
	} else {
		s.setState(StateDone)
	}
	s.emit(Event{Kind: EvDone, Err: err})
}

func (s *Session) run(ctx context.Context) error {
	hbCtx, hbCancel := context.WithCancel(ctx)
	defer hbCancel()
	go s.heartbeatLoop(hbCtx)

	ls, err := s.pullAndLaunch(ctx)
	if err != nil {
		return err
	}
	defer ls.stopTimers()
	return ls.loop(ctx)
}

// syncAtStart è il pull iniziale (lock già acquisito). Se la cartella locale
// ha modifiche mai arrivate sull'hub e l'hub è ancora fermo alla loro base,
// sono un fast-forward: si pushano prima, poi si prosegue normalmente. Se
// l'hub è andato avanti (divergenza) la sessione si ferma con il
// DirtyLocalError (avvolto, errors.As funziona): decide l'utente.
func (s *Session) syncAtStart(ctx context.Context) (syncx.PullPlan, error) {
	// outbox di una sessione precedente finita male: non si riprende (vedi
	// syncx/outbox.go), lo stato locale lo gestisce il controllo qui sotto
	if err := s.eng.ResetOutbox(); err != nil {
		s.warn(i18n.Sf("Pulizia dell'outbox non riuscita: %v", err))
	}
	s.setState(StatePulling)
	plan, err := s.eng.Pull(ctx)
	var dirty *syncx.DirtyLocalError
	if errors.As(err, &dirty) && !dirty.Diverged() {
		s.warn(i18n.Sf("La cartella locale ha modifiche mai arrivate sull'hub (%d file modificati o aggiunti, %d cancellati): le carico ora, prima di avviare.",
			len(dirty.Changed), len(dirty.Removed)))
		s.setState(StatePushing)
		res, perr := s.eng.Push(ctx, i18n.Sf("modifiche locali non sincronizzate di %s", s.cfg.Owner), false)
		if perr != nil {
			return plan, i18n.Errorf("caricamento delle modifiche locali fallito: %w", perr)
		}
		if !res.NoChange {
			s.recordPush(res, true, time.Now())
			s.note(i18n.Sf("Modifiche locali caricate: generazione %d", res.Gen.N))
		}
		s.setState(StatePulling)
		plan, err = s.eng.Pull(ctx)
	}
	if err != nil {
		return plan, i18n.Errorf("pull fallito: %w", err)
	}
	if plan.Backup != "" {
		s.warn(i18n.Sf("Modifiche locali scartate: ne trovi una copia in %s", plan.Backup))
	}
	// la cartella è identica all'hub da adesso
	s.setHubSavedAt(time.Now())
	s.emit(Event{Kind: EvUpload, HubSavedAt: s.HubSavedAt()})
	return plan, nil
}

// pullAndLaunch sincronizza la cartella, sceglie il runtime e avvia il
// server. Su errore il lock è già stato rilasciato.
func (s *Session) pullAndLaunch(ctx context.Context) (*loopState, error) {
	fail := func(err error) (*loopState, error) {
		s.releaseLock()
		return nil, err
	}
	plan, err := s.syncAtStart(ctx)
	if err != nil {
		return fail(err)
	}
	s.note(i18n.Sf("Sincronizzato alla generazione %d (%d file scaricati)", plan.Gen, len(plan.Download)))
	if s.isLockLost() {
		return nil, i18n.Errorf("%w prima dell'avvio: il server non è stato avviato", ErrLockLost)
	}

	pick := s.pickLaunch
	if s.launchOverride != nil {
		pick = s.launchOverride
	}
	info, javaExe, err := pick()
	if err != nil {
		return fail(err)
	}

	s.setState(StateLaunching)
	s.note(i18n.Sf("Avvio: %s", orDefault(info.LaunchNote, strings.Join(info.Launch, " "))))
	sup, err := mc.Start(ctx, info, javaExe)
	if err != nil {
		return fail(i18n.Errorf("avvio fallito: %w", err))
	}
	s.mu.Lock()
	s.sup = sup
	s.mu.Unlock()
	return newLoopState(s, info, javaExe, sup), nil
}

// pickLaunch decide come avviare il server: script o jar, e quale Java.
func (s *Session) pickLaunch() (mc.ServerInfo, string, error) {
	info := mc.Inspect(s.cfg.LocalPath)
	if len(info.Launch) == 0 {
		return info, "", i18n.Errorf("non so come avviare il server in %s: non c'e' nessuno script di avvio "+
			"(run.sh, start.sh, ServerStart.sh…) ne' un jar avviabile (fabric-server-launch.jar, server.jar…)",
			s.cfg.LocalPath)
	}
	java, reqMajor := mc.PickJava(info, s.cfg.JavaPath)
	javaExe := java.Path
	switch {
	case !java.Found && info.StartScript != "":
		// Nessun Java in vista, ma il pack ha uno script: quasi sempre lo
		// script sa da sé quale runtime usare (molti ne includono uno). Prima
		// si abortiva, rifiutando di avviare server che partivano benissimo.
		javaExe = ""
		s.warn(i18n.Sf("Nessun runtime Java trovato dal sistema: lascio decidere allo script del pack. Se non parte, installa Java %s.",
			orDefault(itoaOr(reqMajor), "21")))
	case !java.Found:
		return info, "", i18n.Errorf("java non trovato: installane uno (Minecraft %s vuole Java %s) o selezionalo dalle impostazioni dello spazio",
			orDefault(info.MCVersion, i18n.S("moderno")), orDefault(itoaOr(reqMajor), "21"))
	case reqMajor > 0 && java.Major < reqMajor:
		s.warn(i18n.Sf("Java %s è troppo vecchio: Minecraft %s richiede Java %d. Il server morirà con UnsupportedClassVersionError — installa Java %d.",
			orDefault(java.Version, "?"), info.MCVersion, reqMajor, reqMajor))
	case reqMajor > 0 && java.Major > reqMajor:
		s.warn(i18n.Sf("Uso Java %s, ma questo modpack (Minecraft %s) è fatto per Java %d: se l'avvio fallisce è il primo indiziato.",
			orDefault(java.Version, "?"), info.MCVersion, reqMajor))
	case java.Major > 0:
		s.note(i18n.Sf("Java %s ok", java.Version))
	}

	javaLbl := orDefault(java.Version, "ok")
	if !java.Found {
		javaLbl = i18n.S("scelto dallo script del pack")
	}
	s.emit(Event{Kind: EvLaunch, Java: javaLbl, Script: info.LaunchLabel(), Port: info.Port})
	return info, javaExe, nil
}

// loopState è lo stato del ciclo principale della sessione (server avviato).
type loopState struct {
	s       *Session
	info    mc.ServerInfo
	javaExe string
	sup     *mc.Supervisor

	autosave     *time.Ticker
	nudge        *time.Ticker
	flushTimeout *time.Timer
	killT        *time.Timer

	waitingFlush bool
	flushStart   time.Time // invio del save-all flush in corso
	launched     bool
	eulaBlocked  bool
	restarts     int

	// ciclo di autosave in corso (quiete, snapshot, upload): vedi autosave.go
	cycle         *cycle
	cycleMsg      chan cycleMsg
	lastSaveStart time.Time
	saveQueued    bool            // salvataggio manuale chiesto durante un upload
	ctx           context.Context // contesto della sessione (i cicli ne derivano)

	// Molti ServerStart.bat finiscono con `pause`: a server spento il .bat
	// aspetta un tasto per sempre e il processo non esce mai. Durante lo
	// spegnimento si mandano invii periodici sullo stdin (innocui per il
	// server vivo) per sbloccarlo, e dopo un silenzio prolungato si chiude
	// il processo.
	closing     bool
	closeSince  time.Time
	lastConsole time.Time
}

func newLoopState(s *Session, info mc.ServerInfo, javaExe string, sup *mc.Supervisor) *loopState {
	ls := &loopState{
		s: s, info: info, javaExe: javaExe, sup: sup,
		autosave:      time.NewTicker(s.cfg.AutosaveEvery),
		nudge:         time.NewTicker(2 * time.Second),
		flushTimeout:  time.NewTimer(time.Hour),
		killT:         time.NewTimer(24 * time.Hour),
		lastConsole:   time.Now(),
		cycleMsg:      make(chan cycleMsg, 4),
		lastSaveStart: time.Now(),
		ctx:           context.Background(),
	}
	ls.flushTimeout.Stop()
	ls.killT.Stop()
	return ls
}

func (ls *loopState) stopTimers() {
	ls.autosave.Stop()
	ls.nudge.Stop()
	ls.flushTimeout.Stop()
	ls.killT.Stop()
}

func (ls *loopState) loop(ctx context.Context) error {
	ls.ctx = ctx
	s := ls.s
	for {
		select {
		case <-ctx.Done():
			return ls.handleCancel(ctx)
		case line, ok := <-ls.sup.Lines:
			ls.handleLine(line, ok)
		case exitErr := <-ls.sup.Exited:
			if done, err := ls.handleExit(ctx, exitErr); done {
				return err
			}
		case <-ls.nudge.C:
			ls.handleNudge()
		case <-ls.killT.C:
			s.warn(i18n.Sf("Console ferma da %s durante lo spegnimento: il processo sembra piantato (pause nello script?), arresto forzato.",
				humanDur(time.Since(ls.lastConsole))))
			ls.sup.Kill()
		case <-ls.autosave.C:
			// con un ciclo già in corso il tick si salta: mai due upload
			// insieme, e mai un save-off subito dopo un save-on
			if ls.cycle == nil && ls.beginSafeSave() {
				s.note(i18n.S("Autosave in corso"))
			}
		case <-s.saveNow:
			switch {
			case ls.cycle != nil || ls.waitingFlush:
				if !ls.saveQueued {
					ls.saveQueued = true
					s.note(i18n.S("Salvataggio già in corso: ne parte un altro appena finisce."))
				}
			case ls.beginSafeSave():
				s.note(i18n.S("Salvataggio manuale in corso"))
			}
		case m := <-ls.cycleMsg:
			ls.handleCycle(m)
		case <-ls.flushTimeout.C:
			if ls.waitingFlush {
				ls.waitingFlush = false
				if !ls.stopping() {
					s.warn(i18n.Sf("Nessuna conferma di salvataggio entro %s: snapshot comunque avviato.", humanDur(time.Since(ls.flushStart))))
				}
				ls.startCycle()
			}
		}
	}
}

// handleCancel: contesto ucciso (Ctrl+C duro). Prova comunque uno stop rapido.
func (ls *loopState) handleCancel(ctx context.Context) error {
	ls.endCycle()
	if ls.sup.Running() {
		ls.sup.Stop()
		select {
		case <-ls.sup.Exited:
		case <-time.After(30 * time.Second):
			ls.sup.Kill()
		}
	}
	ls.s.releaseLock()
	return ctx.Err()
}

// armClose: lo spegnimento è iniziato. Il kill è a "silenzio", non a tempo
// assoluto: uno spegnimento onesto stampa `Saving chunks for level …` per
// ogni dimensione e su un modpack grosso può durare parecchi minuti. Uccidere
// a 60s dall'inizio dello stop significava segare il server a metà scrittura
// delle region, cioè corrompere il mondo proprio mentre lo si stava salvando.
// Il timer riparte a ogni riga di console e c'è comunque un tetto massimo,
// oltre il quale il processo è considerato piantato davvero.
func (ls *loopState) armClose() {
	if !ls.closing {
		ls.closing = true
		ls.closeSince = time.Now()
		ls.killT.Reset(closeIdleKill)
	}
}

// stopping: lo spegnimento è stato chiesto o è già in corso.
func (ls *loopState) stopping() bool {
	ls.s.mu.Lock()
	defer ls.s.mu.Unlock()
	return ls.s.stopReq || ls.closing
}

func (ls *loopState) handleLine(line string, ok bool) {
	if !ok {
		ls.sup.Lines = nil // exit arriverà su Exited
		return
	}
	ls.lastConsole = time.Now()
	// il server sta ancora parlando: se è in fase di spegnimento sta
	// salvando, non è piantato. Il kill si sposta in avanti.
	if ls.closing && time.Since(ls.closeSince) < closeHardKill {
		ls.killT.Reset(closeIdleKill)
	}
	ls.s.emit(Event{Kind: EvConsole, Line: line})
	ls.drainEvents()
}

// drainEvents applica i fatti del supervisore (avvio completato,
// spegnimento, salvataggi, join/leave). Arrivano da una coda, non dalle
// righe: quelle si perdono quando la UI è lenta, i fatti no.
func (ls *loopState) drainEvents() {
	s := ls.s
	for _, e := range ls.sup.DrainEvents() {
		switch e.Kind {
		case mc.EvStarted:
			if !ls.launched {
				ls.launched = true
				s.setState(StateRunning)
				s.note(i18n.Sf("Server avviato (porta %s)", orDefault(ls.info.Port, "25565")))
				// un save-off lasciato da un client crashato non sopravvive al
				// riavvio del server, ma un save-on in più non costa niente
				ls.sup.Send("save-on")
				s.mu.Lock()
				s.ready = true // abilita il test della porta lato hub
				if len(s.players) == 0 {
					s.emptySince = time.Now() // vuoto dall'avvio: l'autostop parte da qui
				}
				s.mu.Unlock()
			}
		case mc.EvStopping:
			ls.armClose()
		case mc.EvEULA:
			ls.eulaBlocked = true
		case mc.EvSaving:
			// il salvataggio è in corso: sposta in avanti la scadenza
			// invece di fotografare un mondo ancora in scrittura (ma non
			// oltre il tetto)
			if ls.waitingFlush {
				if left := flushHardCap - time.Since(ls.flushStart); left > 0 {
					ls.flushTimeout.Reset(min(flushWait, left))
				}
			}
		case mc.EvSaved:
			if ls.waitingFlush {
				ls.waitingFlush = false
				ls.flushTimeout.Stop()
				ls.startCycle()
			}
		case mc.EvJoin, mc.EvLeave:
			s.mu.Lock()
			if e.Kind == mc.EvJoin {
				s.players[e.Name] = true
			} else {
				delete(s.players, e.Name)
			}
			list := make([]string, 0, len(s.players))
			for p := range s.players {
				list = append(list, p)
			}
			if len(s.players) == 0 {
				s.emptySince = time.Now()
			} else {
				s.emptySince = time.Time{}
			}
			s.mu.Unlock()
			sort.Strings(list)
			s.emit(Event{Kind: EvPlayers, Players: list})
		}
	}
}

// handleExit gestisce l'uscita del processo. done=false: il server è stato
// riavviato e il ciclo prosegue.
func (ls *loopState) handleExit(ctx context.Context, exitErr error) (done bool, err error) {
	s := ls.s
	s.mu.Lock()
	wasStopping := s.stopReq
	s.mu.Unlock()
	ls.drainEvents() // ultimi fatti prima di decidere (EULA, avvio riuscito…)
	// un autosave in volo si annulla: il push che segue legge i file veri a
	// server spento, e due push insieme sullo stesso engine non si fanno
	ls.endCycle()
	ls.waitingFlush = false
	ls.flushTimeout.Stop()
	if ls.eulaBlocked {
		s.releaseLock()
		return true, i18n.Errorf("il server si è fermato perché l'EULA di Minecraft non è accettata: " +
			"apri eula.txt nella cartella del server, metti eula=true e riprova")
	}
	// Un processo morto PRIMA di "Done (…)!" non è un crash di gioco: è
	// un avvio che non funziona (mod incompatibile, Java sbagliato,
	// porta occupata, script rotto). Rilanciarlo due volte non lo
	// aggiusta, fa solo perdere tempo e due push inutili.
	if !wasStopping && !ls.launched {
		s.warn(i18n.S("Il server si è chiuso prima di completare l'avvio: è un problema di configurazione, non un crash. Nessun riavvio automatico."))
		return true, ls.finish(ctx, true, exitErr)
	}
	// crash con riavvio automatico: salva subito lo stato sull'hub, poi
	// rilancia lo script — l'host può anche non essere davanti al PC
	if !wasStopping && !s.isLockLost() && !s.isSpaceGone() && s.cfg.MaxRestarts > 0 && ls.restarts < s.cfg.MaxRestarts {
		ls.restarts++
		s.warn(i18n.Sf("Server terminato in modo anomalo (%s): salvo lo stato e riavvio (tentativo %d/%d).",
			describeExit(exitErr), ls.restarts, s.cfg.MaxRestarts))
		s.setState(StatePushing)
		res, perr := s.eng.Push(ctx, i18n.Sf("push post-crash di %s", s.cfg.Owner), false)
		switch {
		case perr != nil && api.IsLockLost(perr):
			s.lockLostAlert(perr)
			return true, ls.finish(ctx, true, exitErr)
		case perr != nil:
			s.warn(i18n.Sf("Push post-crash non riuscito: %v", perr))
		case !res.NoChange:
			s.recordPush(res, true, time.Now())
		}
		s.setState(StateLaunching)
		newSup, serr := mc.Start(ctx, ls.info, ls.javaExe)
		if serr != nil {
			s.warn(i18n.Sf("Riavvio fallito: %v", serr))
			return true, ls.finish(ctx, true, exitErr)
		}
		ls.sup = newSup
		s.mu.Lock()
		s.sup = newSup
		s.players = map[string]bool{} // col riavvio sono usciti tutti
		s.emptySince = time.Time{}
		s.mu.Unlock()
		s.emit(Event{Kind: EvPlayers, Players: []string{}})
		ls.launched, ls.closing = false, false
		ls.killT.Stop()
		return false, nil
	}
	return true, ls.finish(ctx, !wasStopping, exitErr)
}

// finish chiude la sessione: push finale, rilascio del lock. Con il lock
// perso il push è saltato (verrebbe rifiutato, o peggio sovrascriverebbe la
// sessione di un altro): il mondo resta sul disco locale e la protezione
// delle modifiche locali lo segnalerà al prossimo avvio.
func (ls *loopState) finish(ctx context.Context, crashed bool, exitErr error) error {
	s := ls.s
	s.mu.Lock()
	s.sup = nil
	s.mu.Unlock()
	if s.isSpaceGone() {
		s.warn(i18n.S("Lo spazio non esiste più sull'hub: push finale saltato. Il mondo è rimasto solo su questo PC."))
		return i18n.Errorf("%w: il server è stato fermato e il mondo è rimasto solo sul disco locale", ErrSpaceGone)
	}
	if s.isLockLost() {
		s.warn(i18n.S("Lock perso: push finale saltato. Il mondo è rimasto solo su questo PC."))
		return i18n.Errorf("%w: il server è stato fermato e il mondo è rimasto solo sul disco locale "+
			"(al prossimo avvio MineSync ti chiederà come procedere)", ErrLockLost)
	}
	msg := i18n.Sf("stop di %s", s.cfg.Owner)
	if crashed {
		msg = i18n.Sf("push post-crash di %s", s.cfg.Owner)
		s.warn(i18n.S("Server terminato in modo anomalo: salvataggio dello stato sull'hub."))
	}
	s.setState(StatePushing)
	res, err := s.eng.Push(ctx, msg, false)
	switch {
	case err != nil && api.IsLockLost(err):
		s.lockLostAlert(err)
		return i18n.Errorf("%w: push finale rifiutato, il mondo è rimasto solo sul disco locale: %v", ErrLockLost, err)
	case err != nil:
		s.warn(i18n.Sf("Push finale non riuscito: %v. Il mondo resta sul disco locale; riprova con `minesync push`.", err))
	case !res.NoChange:
		s.recordPush(res, false, time.Now())
		s.note(i18n.Sf("Push finale: generazione %d", res.Gen.N))
	default:
		s.setHubSavedAt(time.Now())
		s.note(i18n.S("Nessuna modifica da salvare."))
	}
	s.releaseLock()
	if crashed {
		return i18n.Errorf("il server Minecraft è crashato (%s, vedi console)", describeExit(exitErr))
	}
	return err
}

// describeExit rende leggibile l'esito del processo per i messaggi di crash.
func describeExit(err error) string {
	if err == nil {
		return i18n.S("uscito da solo senza che fosse chiesto lo stop")
	}
	return i18n.Sf("uscita: %v", err)
}

func (ls *loopState) handleNudge() {
	s := ls.s
	ls.drainEvents() // anche se le righe vengono scartate, i fatti no
	s.mu.Lock()
	sr := s.stopReq
	// auto-stop: server avviato, vuoto da troppo → stop pulito.
	// (il lock si libera e il mondo finisce al sicuro sull'hub)
	var emptyFor time.Duration
	if ls.launched && !sr && s.autoStop > 0 && !s.emptySince.IsZero() {
		emptyFor = time.Since(s.emptySince)
	}
	trigger := emptyFor > 0 && emptyFor >= s.autoStop
	s.mu.Unlock()
	if trigger {
		s.warn(i18n.Sf("Nessun giocatore da %s: arresto automatico e salvataggio finale.", humanDur(emptyFor)))
		s.RequestStop()
	}
	if sr {
		ls.armClose()
	}
	// invio di sblocco per `pause`/`read` dello script: SOLO quando la
	// console tace da un po' (server vivo = riga vuota → errore inutile
	// "Unknown command" in console)
	if ls.closing && time.Since(ls.lastConsole) > 3*time.Second {
		ls.sup.Send("")
	}
}

// recordPush registra un push riuscito: ultima generazione, istante dello
// stato ora sull'hub, evento per la UI (saved=true) e avviso sui region file
// danneggiati.
func (s *Session) recordPush(res syncx.PushResult, saved bool, hubAt time.Time) {
	s.mu.Lock()
	s.lastGen = res.Gen.N
	s.hubSavedAt = hubAt
	s.mu.Unlock()
	if saved {
		s.emit(Event{Kind: EvSaved, Gen: res.Gen.N, HubSavedAt: hubAt})
	}
	s.warnCorrupt(res)
}

func (s *Session) setHubSavedAt(t time.Time) {
	s.mu.Lock()
	s.hubSavedAt = t
	s.mu.Unlock()
}

func (s *Session) isLockLost() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lockLost
}

func (s *Session) isSpaceGone() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.spaceGone
}

// lockLostAlert: il lock non è più nostro. Avviso bloccante e stop pulito del
// server: continuare a giocare su un mondo che non si può più pushare
// significa perdere tutto quello che si fa da qui in poi.
func (s *Session) lockLostAlert(cause error) {
	s.mu.Lock()
	already := s.lockLost || s.released
	s.lockLost = true
	s.mu.Unlock()
	if already {
		return
	}
	s.emit(Event{Kind: EvNote, Warn: true, Alert: true, Note: i18n.Sf(
		"LOCK PERSO (%v): qualcun altro ha preso il controllo dello spazio. Fermo il server: "+
			"quello che fai da ora non potrebbe più essere salvato sull'hub. Il mondo resta su questo PC.", cause)})
	s.RequestStop()
}

// spaceGoneAlert: lo spazio è stato cancellato dall'hub. Come il lock perso:
// avviso bloccante, stop pulito, niente push (non c'è più dove farlo). Prima
// l'heartbeat riceveva 404 per sempre e la sessione diceva soltanto "hub
// irraggiungibile".
func (s *Session) spaceGoneAlert() {
	s.mu.Lock()
	already := s.spaceGone || s.released
	s.spaceGone = true
	s.mu.Unlock()
	if already {
		return
	}
	s.emit(Event{Kind: EvNote, Warn: true, Alert: true, Note: i18n.S(
		"SPAZIO CANCELLATO: questo server non esiste più sull'hub. Fermo il server; il mondo resta su questo PC.")})
	s.RequestStop()
}

// heartbeatLoop rinnova il lock; segnala se l'hub sparisce o il lock è perso.
func (s *Session) heartbeatLoop(ctx context.Context) {
	t := time.NewTicker(s.cfg.HeartbeatEvery)
	defer t.Stop()
	fails := 0
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.mu.Lock()
			players := make([]string, 0, len(s.players))
			for p := range s.players {
				players = append(players, p)
			}
			ready := s.ready
			s.mu.Unlock()
			sort.Strings(players)
			resp, err := s.cfg.Client.LockHeartbeat(ctx, s.cfg.SpaceID, s.cfg.LockSession, players, ready)
			switch {
			case err == nil:
				if fails >= 2 {
					s.note(i18n.S("Hub di nuovo raggiungibile."))
				}
				fails = 0
				s.updateReachable(resp.Reachable)
			case api.IsConflict(err):
				s.lockLostAlert(err)
			case api.IsSpaceGone(err):
				s.spaceGoneAlert()
				return
			default:
				fails++
				if fails == 2 {
					s.warn(i18n.Sf("Hub irraggiungibile (%v). Il gioco prosegue; i salvataggi riprenderanno al ritorno.", err))
				}
			}
		}
	}
}

func (s *Session) releaseLock() {
	s.mu.Lock()
	s.released = true
	gone := s.spaceGone
	s.mu.Unlock()
	if gone {
		return // niente da rilasciare: lo spazio non c'è più
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := s.cfg.Client.LockRelease(ctx, s.cfg.SpaceID, s.cfg.LockSession, false); err != nil {
		s.warn(i18n.Sf("Rilascio del lock non riuscito: %v (scadrà da solo alla fine del TTL).", err))
	} else {
		s.note(i18n.S("Lock rilasciato."))
	}
}
