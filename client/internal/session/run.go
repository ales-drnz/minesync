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
			s.recordPush(res, true)
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

	info := mc.Inspect(s.cfg.LocalPath)
	if len(info.Launch) == 0 {
		return fail(i18n.Errorf("non so come avviare il server in %s: non c'e' nessuno script di avvio "+
			"(run.sh, start.sh, ServerStart.sh…) ne' un jar avviabile (fabric-server-launch.jar, server.jar…)",
			s.cfg.LocalPath))
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
		return fail(i18n.Errorf("java non trovato: installane uno (Minecraft %s vuole Java %s) o selezionalo dalle impostazioni dello spazio",
			orDefault(info.MCVersion, i18n.S("moderno")), orDefault(itoaOr(reqMajor), "21")))
	case reqMajor > 0 && java.Major < reqMajor:
		s.warn(i18n.Sf("Java %s è troppo vecchio: Minecraft %s richiede Java %d. Il server morirà con UnsupportedClassVersionError — installa Java %d.",
			orDefault(java.Version, "?"), info.MCVersion, reqMajor, reqMajor))
	case reqMajor > 0 && java.Major > reqMajor:
		s.warn(i18n.Sf("Uso Java %s, ma questo modpack (Minecraft %s) è fatto per Java %d: se l'avvio fallisce è il primo indiziato.",
			orDefault(java.Version, "?"), info.MCVersion, reqMajor))
	case java.Major > 0:
		s.note(i18n.Sf("Java %s ok", java.Version))
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

// loopState è lo stato del ciclo principale della sessione (server avviato).
type loopState struct {
	s       *Session
	info    mc.ServerInfo
	javaExe string
	sup     *mc.Supervisor

	autosave     *time.Ticker
	nudge        *time.Ticker
	flushTimeout *time.Timer
	settle       *time.Timer // attesa IO asincrono dopo la conferma di salvataggio
	killT        *time.Timer

	waitingFlush bool
	launched     bool
	eulaBlocked  bool
	restarts     int

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
		autosave:     time.NewTicker(s.cfg.AutosaveEvery),
		nudge:        time.NewTicker(2 * time.Second),
		flushTimeout: time.NewTimer(time.Hour),
		settle:       time.NewTimer(time.Hour),
		killT:        time.NewTimer(24 * time.Hour),
		lastConsole:  time.Now(),
	}
	ls.flushTimeout.Stop()
	ls.settle.Stop()
	ls.killT.Stop()
	return ls
}

func (ls *loopState) stopTimers() {
	ls.autosave.Stop()
	ls.nudge.Stop()
	ls.flushTimeout.Stop()
	ls.settle.Stop()
	ls.killT.Stop()
}

func (ls *loopState) loop(ctx context.Context) error {
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
			if ls.beginSafeSave() {
				s.note(i18n.S("Autosave in corso"))
			}
		case <-s.saveNow:
			if ls.beginSafeSave() {
				s.note(i18n.S("Salvataggio manuale in corso"))
			}
		case <-ls.settle.C:
			ls.autosavePush(ctx)
		case <-ls.flushTimeout.C:
			if ls.waitingFlush {
				ls.waitingFlush = false
				if !ls.stopping() {
					s.warn(i18n.Sf("Nessuna conferma di salvataggio entro %s: push comunque avviato.", humanDur(flushWait)))
				}
				ls.autosavePush(ctx)
			}
		}
	}
}

// handleCancel: contesto ucciso (Ctrl+C duro). Prova comunque uno stop rapido.
func (ls *loopState) handleCancel(ctx context.Context) error {
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
// righe: quelle si perdono quando la UI è lenta o c'è un push in corso, i
// fatti no.
func (ls *loopState) drainEvents() {
	s := ls.s
	for _, e := range ls.sup.DrainEvents() {
		switch e.Kind {
		case mc.EvStarted:
			if !ls.launched {
				ls.launched = true
				s.setState(StateRunning)
				s.note(i18n.Sf("Server avviato (porta %s)", orDefault(ls.info.Port, "25565")))
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
			// invece di pushare un mondo ancora in scrittura
			if ls.waitingFlush {
				ls.flushTimeout.Reset(flushWait)
			}
		case mc.EvSaved:
			if ls.waitingFlush {
				ls.waitingFlush = false
				ls.flushTimeout.Stop()
				ls.settle.Reset(3 * time.Second) // lascia atterrare l'IO asincrono
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
	if !wasStopping && !s.isLockLost() && s.cfg.MaxRestarts > 0 && ls.restarts < s.cfg.MaxRestarts {
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
			s.recordPush(res, true)
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
		ls.launched, ls.waitingFlush, ls.closing = false, false, false
		ls.flushTimeout.Stop()
		ls.settle.Stop()
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
		s.recordPush(res, false)
		s.note(i18n.Sf("Push finale: generazione %d", res.Gen.N))
	default:
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

// beginSafeSave avvia il ciclo di salvataggio sicuro: save-off + save-all
// flush.
//
// Il `flush` c'è di proposito, e prima non c'era. Senza, `save-all` si limita
// ad ACCODARE le scritture dei chunk e ritorna subito: il push partiva mentre
// il mondo era ancora in scrittura, e ogni tanto catturava region a metà. Con
// `flush` il server attende davvero la fine e fa fsync (è la sequenza che
// usano tutti i tool di backup seri). Il prezzo è un blocco di qualche
// secondo sui mondi grandi — accettabile una volta ogni cinque minuti, molto
// meno costoso di un salvataggio incoerente. Il watchdog non è un problema:
// il server si ferma solo per il tempo del salvataggio.
//
// Il push parte alla conferma + un breve settle per le scritture asincrone
// che restano (playerdata e level.dat non si fermano mai a server acceso);
// l'eventuale file cambiato in corsa viene rifiutato dall'hub via hash e il
// push viene ritentato.
func (ls *loopState) beginSafeSave() bool {
	s := ls.s
	s.mu.Lock()
	busy := s.state == StateSaving || s.state == StatePushing || s.stopReq || s.lockLost
	s.mu.Unlock()
	if busy || ls.closing || !ls.launched || !ls.sup.Running() {
		return false
	}
	s.setState(StateSaving)
	ls.sup.Send("save-off")
	ls.sup.Send("save-all flush")
	ls.waitingFlush = true
	ls.flushTimeout.Reset(flushWait)
	return true
}

// autosavePush esegue il push col mondo congelato, poi riattiva i salvataggi.
// Un tentativo extra assorbe le scritture asincrone dei modpack che sfuggono
// al save-off (hash cambiato tra scansione e upload → l'hub rifiuta, e noi
// ci riproviamo con una scansione fresca).
//
// Se nel frattempo è stato chiesto lo stop (o il server si sta già
// spegnendo) non si pusha niente: il mondo sta cambiando sotto i piedi per
// il salvataggio finale e il push finale arriva comunque. E niente save-on
// a un server che si sta fermando.
func (ls *loopState) autosavePush(ctx context.Context) {
	s := ls.s
	if ls.stopping() || s.isLockLost() {
		s.setState(StateStopping)
		return
	}
	s.setState(StatePushing)
	msg := i18n.Sf("autosave di %s", s.cfg.Owner)
	res, err := s.eng.Push(ctx, msg, false)
	if err != nil && !api.IsLockLost(err) && !ls.stopping() {
		select {
		case <-time.After(2 * time.Second):
			if !ls.stopping() {
				res, err = s.eng.Push(ctx, msg, false)
			}
		case <-ctx.Done():
		}
	}
	if ls.stopping() {
		// stop arrivato durante il push: niente save-on, ci pensa lo stop
		s.setState(StateStopping)
		if err == nil && !res.NoChange {
			s.recordPush(res, true)
		}
		return
	}
	ls.sup.Send("save-on") // SEMPRE, anche su errore
	switch {
	case err != nil && api.IsLockLost(err):
		s.lockLostAlert(err)
		return
	case err != nil:
		s.warn(i18n.Sf("Autosave non riuscito: %v", err))
	case res.NoChange:
		s.note(i18n.S("Autosave: nessuna modifica."))
	default:
		s.recordPush(res, true)
		s.note(i18n.Sf("Autosave: generazione %d (%s)", res.Gen.N, humanBytes(res.Bytes)))
	}
	s.setState(StateRunning)
}

// recordPush registra un push riuscito: ultima generazione, evento per la
// UI (saved=true) e avviso sui region file danneggiati.
func (s *Session) recordPush(res syncx.PushResult, saved bool) {
	s.mu.Lock()
	s.lastGen = res.Gen.N
	s.mu.Unlock()
	if saved {
		s.emit(Event{Kind: EvSaved, Gen: res.Gen.N})
	}
	s.warnCorrupt(res)
}

func (s *Session) isLockLost() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lockLost
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
	s.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := s.cfg.Client.LockRelease(ctx, s.cfg.SpaceID, s.cfg.LockSession, false); err != nil {
		s.warn(i18n.Sf("Rilascio del lock non riuscito: %v (scadrà da solo alla fine del TTL).", err))
	} else {
		s.note(i18n.S("Lock rilasciato."))
	}
}
