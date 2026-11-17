package session

import (
	"context"
	"errors"
	"time"

	"minesync/client/internal/api"
	"minesync/client/internal/i18n"
	"minesync/client/internal/mc"
	"minesync/client/internal/syncx"
)

// Autosave con outbox (3.2).
//
// Prima: save-off → push intero (scansione + upload dai file vivi) →
// save-on, tutto dentro il ciclo della sessione. Con un uplink lento il server
// restava in save-off per quasi tutto il tempo (il tick successivo ripartiva
// appena dopo il save-on), il ciclo era bloccato (crash, autostop, kill e
// console in ritardo) e un file cambiato dopo la scansione faceva fallire il
// blob per hash, ritentato inutilmente con lo stesso hash.
//
// Ora il ciclo di salvataggio è:
//
//  1. save-off + save-all flush e attesa della conferma VERA (vedi
//     mc.IsSaveConfirmed; la scadenza si sposta a ogni riga "Saving…", con un
//     tetto di flushHardCap);
//  2. in una goroutine (il ciclo della sessione non si blocca mai):
//     quiete della cartella (i mod che scrivono anche in save-off), poi
//     syncx.Engine.Snapshot che copia nell'outbox i blob che l'hub non ha;
//  3. save-on SUBITO (sempre, anche su errore o panic);
//  4. upload in background dall'outbox: 2 worker, banda limitata; a fine
//     upload la base locale avanza e l'outbox si svuota.
//
// Mai due cicli insieme: i tick che arrivano durante un ciclo si saltano, e
// alla fine se l'intervallo è già passato ne parte subito un altro. Lo stop
// annulla il ciclo (i blob già caricati restano sull'hub) e il push finale
// legge i file veri a server spento, a piena velocità.

// cycle è un ciclo di autosave in corso.
type cycle struct {
	cancel context.CancelFunc
	done   chan struct{}
}

// cycleMsg è un passo del ciclo, verso il ciclo della sessione.
type cycleMsg struct {
	done bool // false: snapshot fatto e save-on inviato, upload in corso
	res  syncx.PushResult
	err  error
	at   time.Time // istante dello snapshot
	sync bool      // ripiego sincrono (outbox senza spazio)
}

// beginSafeSave avvia il ciclo di salvataggio sicuro: save-off + save-all
// flush.
//
// Il `flush` c'è di proposito. Senza, `save-all` si limita ad ACCODARE le
// scritture dei chunk e ritorna subito: lo snapshot partiva mentre il mondo
// era ancora in scrittura. Con `flush` il server attende davvero la fine e fa
// fsync (è la sequenza che usano tutti i tool di backup seri).
func (ls *loopState) beginSafeSave() bool {
	s := ls.s
	s.mu.Lock()
	busy := s.stopReq || s.lockLost || s.spaceGone
	s.mu.Unlock()
	if busy || ls.cycle != nil || ls.waitingFlush || ls.closing || !ls.launched || !ls.sup.Running() {
		return false
	}
	s.setState(StateSaving)
	now := time.Now()
	ls.sup.Send("save-off")
	ls.sup.ExpectSave()
	ls.sup.Send("save-all flush")
	ls.waitingFlush = true
	ls.flushStart, ls.lastSaveStart = now, now
	ls.flushTimeout.Reset(flushWait)
	return true
}

// startCycle: salvataggio confermato (o scaduta l'attesa), parte la
// goroutine del ciclo. Se nel frattempo è stato chiesto lo stop non si fa
// niente: il salvataggio finale lo fa lo stop stesso, e il push finale arriva
// comunque.
func (ls *loopState) startCycle() {
	s := ls.s
	cctx, cancel := context.WithCancel(ls.ctx)
	s.mu.Lock()
	if s.stopReq || s.lockLost || s.spaceGone || ls.closing {
		s.mu.Unlock()
		cancel()
		return
	}
	s.cycleCancel = cancel
	s.mu.Unlock()
	c := &cycle{cancel: cancel, done: make(chan struct{})}
	ls.cycle = c
	sup := ls.sup
	go func() {
		defer close(c.done)
		defer cancel()
		s.runCycle(cctx, sup, ls.cycleMsg)
	}()
}

// runCycle: quiete → snapshot → save-on → upload (vedi il commento in cima).
func (s *Session) runCycle(ctx context.Context, sup *mc.Supervisor, out chan<- cycleMsg) {
	saveOnSent := false
	saveOn := func() {
		if !saveOnSent {
			saveOnSent = true
			sup.Send("save-on")
		}
	}
	defer func() {
		if r := recover(); r != nil {
			saveOn()
			out <- cycleMsg{done: true, err: i18n.Errorf("errore interno dell'autosave: %v", r)}
		}
	}()
	defer saveOn() // SEMPRE: un save-off dimenticato = mondo mai più salvato

	msg := i18n.Sf("autosave di %s", s.cfg.Owner)
	start := time.Now()
	if !s.eng.Quiesce(ctx, quiesceStable, quiesceCap, quiescePoll) && ctx.Err() == nil {
		s.note(i18n.Sf("La cartella cambia ancora dopo %s: snapshot comunque (i file che cambiano durante la lettura vengono riletti).",
			humanDur(quiesceCap)))
	}
	snap, err := s.eng.Snapshot(ctx)
	if errors.Is(err, syncx.ErrOutboxNoSpace) {
		// niente posto per la copia: il vecchio push sincrono, ancora in
		// save-off (lento ma coerente)
		s.warn(i18n.S("Poco spazio su disco per lo snapshot dell'autosave: carico direttamente, il server resta in save-off fino alla fine del caricamento."))
		res, perr := s.eng.Push(ctx, msg, false)
		saveOn()
		out <- cycleMsg{done: true, res: res, err: perr, at: start, sync: true}
		return
	}
	saveOn()
	if err != nil || snap.NoChange {
		m := cycleMsg{done: true, err: err}
		if snap != nil {
			m.at, m.res = snap.At, syncx.PushResult{NoChange: true, Gen: api.GenSummary{N: snap.Parent}}
		}
		out <- m
		return
	}
	out <- cycleMsg{at: snap.At}

	s.mu.Lock()
	s.uploading = true
	s.mu.Unlock()
	s.bg.Store(true)
	opts := syncx.UploadOpts{Workers: bgWorkers, LimitBps: s.eng.UploadLimit(s.cfg.UploadLimitKBps)}
	res, err := s.eng.PushSnapshot(ctx, snap, msg, opts)
	s.bg.Store(false)
	s.mu.Lock()
	s.uploading = false
	s.mu.Unlock()
	out <- cycleMsg{done: true, res: res, err: err, at: snap.At}
}

// handleCycle applica un passo del ciclo (nel ciclo della sessione).
func (ls *loopState) handleCycle(m cycleMsg) {
	s := ls.s
	if !m.done {
		if !ls.stopping() {
			s.setState(StateRunning) // save-on inviato: si gioca, l'upload va in background
		}
		s.emit(Event{Kind: EvUpload, Uploading: true, HubSavedAt: s.HubSavedAt()})
		return
	}
	ls.dropCycle()
	switch err := m.err; {
	case err != nil && api.IsLockLost(err):
		s.lockLostAlert(err) // l'outbox resta: il mondo è su questo PC
	case err != nil && errors.Is(err, context.Canceled):
		// stop o crash: ci pensa il push che segue
	case err != nil:
		s.warn(i18n.Sf("Autosave non riuscito: %v", err))
	case m.res.NoChange:
		s.setHubSavedAt(m.at)
		s.note(i18n.S("Autosave: nessuna modifica."))
	default:
		s.recordPush(m.res, true, m.at)
		s.note(i18n.Sf("Autosave: generazione %d (%s)", m.res.Gen.N, humanBytes(m.res.Bytes)))
	}
	s.emit(Event{Kind: EvUpload, HubSavedAt: s.HubSavedAt()})
	if ls.stopping() || s.isLockLost() {
		return
	}
	s.setState(StateRunning)
	// coalescenza: un manuale in coda, o un intervallo già scaduto durante
	// l'upload, fanno partire subito il prossimo ciclo
	if ls.saveQueued || time.Since(ls.lastSaveStart) >= s.cfg.AutosaveEvery {
		manual := ls.saveQueued
		ls.saveQueued = false
		if ls.beginSafeSave() {
			ls.autosave.Reset(s.cfg.AutosaveEvery)
			if manual {
				s.note(i18n.S("Salvataggio manuale in corso"))
			} else {
				s.note(i18n.S("Autosave in corso"))
			}
		}
	}
}

// dropCycle dimentica il ciclo finito (la goroutine sta uscendo).
func (ls *loopState) dropCycle() {
	if ls.cycle == nil {
		return
	}
	<-ls.cycle.done
	ls.cycle = nil
	ls.s.mu.Lock()
	ls.s.cycleCancel = nil
	ls.s.mu.Unlock()
}

// endCycle annulla il ciclo in corso e ne aspetta la fine (uscita del
// processo, contesto chiuso): il push che segue non deve sovrapporsi.
func (ls *loopState) endCycle() {
	if ls.cycle == nil {
		return
	}
	ls.cycle.cancel()
	ls.dropCycle()
	for {
		select {
		case <-ls.cycleMsg:
		default:
			s := ls.s
			s.emit(Event{Kind: EvUpload, HubSavedAt: s.HubSavedAt()})
			return
		}
	}
}
