package mc

import (
	"bufio"
	"context"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"minesync/client/internal/i18n"
)

// errNoLaunch: non si sa come avviare questa cartella.
var errNoLaunch = i18n.NewError("nessun modo di avviare il server: manca sia uno script di avvio sia un jar avviabile")

// Errori di Send.
var (
	ErrNotRunning  = i18n.NewError("il server non è in esecuzione")
	ErrSendTimeout = i18n.NewError("console del server bloccata: comando non inviato")
)

// sendTimeout è l'attesa massima per accodare un comando (variabile per i test).
var sendTimeout = 2 * time.Second

// stopGrace: dopo la cancellazione del context il server ha questo tempo per
// salvare e uscire da solo prima del kill dell'intero albero di processi.
const stopGrace = 60 * time.Second

// EvKind è il tipo di fatto riconosciuto nell'output del server.
type EvKind int

const (
	EvStarted EvKind = iota // "Done (…)!"
	EvStopping
	EvSaved  // salvataggio confermato
	EvSaving // salvataggio in corso (una riga per dimensione)
	EvJoin
	EvLeave
	EvEULA
)

// Ev è un fatto estratto da una riga di console.
type Ev struct {
	Kind EvKind
	Name string // giocatore, per EvJoin/EvLeave
}

// Supervisor gestisce il processo Java: stdin per i comandi, stdout/err in Lines.
//
// Lines è "best effort": se il consumatore è lento (la UI che ridisegna, o un
// push in corso) le righe in eccesso si perdono, perché bloccare il pump
// bloccherebbe il server sulla pipe. I FATTI però non si perdono mai: vengono
// riconosciuti dentro il pump e accodati in Events, da svuotare con
// DrainEvents. Prima bastava perdere la riga "Done (…)!" in mezzo alle decine
// di migliaia dell'avvio di un modpack per non avere più un solo autosave.
type Supervisor struct {
	cmd    *exec.Cmd
	stdin  chan string   // mai chiuso: la fine la segnala exited
	exited chan struct{} // chiuso (una sola volta) quando il processo termina
	Lines  chan string   // output del server, righe già trimmed
	Exited chan error    // valorizzato quando il processo termina

	mu      sync.Mutex
	running bool

	evMu sync.Mutex
	evQ  []Ev
}

// pushEv accoda un fatto (mai bloccante, mai perso).
func (s *Supervisor) pushEv(e Ev) {
	s.evMu.Lock()
	s.evQ = append(s.evQ, e)
	s.evMu.Unlock()
}

// DrainEvents restituisce i fatti accumulati e svuota la coda.
func (s *Supervisor) DrainEvents() []Ev {
	s.evMu.Lock()
	defer s.evMu.Unlock()
	if len(s.evQ) == 0 {
		return nil
	}
	out := s.evQ
	s.evQ = nil
	return out
}

// classify riconosce i fatti in una riga di console.
func classify(line string) (Ev, bool) {
	switch {
	case IsDone(line):
		return Ev{Kind: EvStarted}, true
	case IsStopping(line):
		return Ev{Kind: EvStopping}, true
	case IsSaveConfirmed(line):
		return Ev{Kind: EvSaved}, true
	case IsSaving(line):
		return Ev{Kind: EvSaving}, true
	case IsEULA(line):
		return Ev{Kind: EvEULA}, true
	}
	if name, joined, ok := PlayerEvent(line); ok {
		if joined {
			return Ev{Kind: EvJoin, Name: name}, true
		}
		return Ev{Kind: EvLeave, Name: name}, true
	}
	return Ev{}, false
}

// Start lancia il server nella sua cartella usando info.Launch (lo script del
// pack, oppure un `java -jar` sintetizzato quando lo script non c'è). Se
// javaExe != "" il runtime scelto viene imposto via JAVA_HOME + PATH senza
// toccare lo script: gli script Forge/Fabric chiamano `java` nudo, quindi
// prendono questo.
//
// La cancellazione di ctx non uccide subito il server (perderebbe il mondo):
// prima gli manda "stop" sulla console (e su unix SIGTERM al gruppo, che fa
// salvare la JVM), poi dopo stopGrace termina l'intero albero di processi.
// Su Windows prima c'era taskkill /F immediato (R5).
func Start(ctx context.Context, info ServerInfo, javaExe string) (*Supervisor, error) {
	if len(info.Launch) == 0 {
		return nil, errNoLaunch
	}
	dir := info.Dir
	argv := append([]string{}, info.Launch...)
	// avvio diretto sintetizzato: usa il java scelto invece di quello del PATH
	if argv[0] == "java" && javaExe != "" {
		argv[0] = javaExe
	}
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Dir = dir
	// La console jline di Minecraft, attaccata a una pipe, si crede in un
	// terminale da 80 colonne e TRONCA le righe di log. Dichiarando un
	// terminale dumb molto largo arrivano intere.
	env := append(os.Environ(), "TERM=dumb", "COLUMNS=400", "LINES=1000")
	if javaExe != "" {
		home := filepath.Dir(filepath.Dir(javaExe)) // …/bin/java → …
		env = append(env, "JAVA_HOME="+home)
		env = prependPath(env, filepath.Dir(javaExe))
	}
	cmd.Env = env
	setProcAttr(cmd) // unix: process group (+ Pdeathsig su Linux)

	s := &Supervisor{
		cmd:     cmd,
		stdin:   make(chan string, 16),
		exited:  make(chan struct{}),
		Lines:   make(chan string, 256),
		Exited:  make(chan error, 1),
		running: true,
	}
	cmd.Cancel = func() error {
		s.trySend("stop")
		go func() {
			select {
			case <-s.exited:
			case <-time.After(stopGrace):
				killTree(cmd)
			}
		}()
		return interruptTree(cmd)
	}
	// rete di sicurezza oltre il periodo di grazia: exec uccide il processo
	// diretto se nemmeno killTree è bastato. (Con StdoutPipe le pipe le chiude
	// comunque Wait appena il processo esce.)
	cmd.WaitDelay = stopGrace + 10*time.Second

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}

	// writer di stdin dedicato (evita blocchi dal thread UI); termina quando
	// il processo esce, così non resta una goroutine per ogni riavvio
	go s.writeStdin(stdin)

	var wg sync.WaitGroup
	pump := func(r io.Reader) {
		defer wg.Done()
		br := bufio.NewReaderSize(r, 64*1024)
		for {
			line, ok := readLine(br)
			if !ok {
				return
			}
			if e, is := classify(line); is {
				s.pushEv(e) // i fatti non si perdono mai
			}
			select {
			case s.Lines <- line:
			default: // UI lenta: perdi la riga, mai bloccare il server
			}
		}
	}
	wg.Add(2)
	go pump(stdout)
	go pump(stderr)
	go func() {
		// L'uscita la decide il PROCESSO, non la chiusura delle pipe: certi
		// wrapper (gli ServerStart.sh in stile ServerStarter) lanciano java in
		// background lasciando le pipe aperte, e aspettare quelle significava
		// non accorgersi mai della fine della sessione. Wait chiude le pipe
		// (StdoutPipe/StderrPipe) appena il processo esce, sbloccando i pump.
		err := cmd.Wait()
		s.mu.Lock()
		s.running = false
		s.mu.Unlock()
		close(s.exited)
		s.Exited <- err
	}()
	go func() {
		wg.Wait()
		close(s.Lines)
	}()
	return s, nil
}

// maxLine è la lunghezza oltre la quale una riga di console viene troncata.
// Non si può semplicemente rinunciare a leggere: un bufio.Scanner con
// ErrTooLong smette di drenare la pipe, java si blocca sulla write quando il
// buffer del kernel è pieno e il server resta congelato senza un solo
// messaggio d'errore. Righe chilometriche le producono davvero i dump del
// classpath di ModLauncher e certi mod che stampano un NBT intero.
const maxLine = 64 * 1024

// readLine legge una riga troncando quelle assurde, e non si arrende mai
// finché la pipe non si chiude.
func readLine(br *bufio.Reader) (string, bool) {
	var sb strings.Builder
	truncated := false
	for {
		chunk, err := br.ReadSlice('\n')
		if n := sb.Len(); n < maxLine {
			take := len(chunk)
			if n+take > maxLine {
				take = maxLine - n
				truncated = true
			}
			sb.Write(chunk[:take])
		} else if len(chunk) > 0 {
			truncated = true
		}
		if err == bufio.ErrBufferFull {
			continue // riga più lunga del buffer: si continua a leggere
		}
		if err != nil {
			if sb.Len() == 0 {
				return "", false // pipe chiusa
			}
			break // ultima riga senza newline finale
		}
		break
	}
	line := strings.TrimRight(sb.String(), "\r\n")
	if truncated {
		line += i18n.S(" […riga troncata da MineSync]")
	}
	return line, true
}

func (s *Supervisor) writeStdin(stdin io.WriteCloser) {
	defer stdin.Close()
	w := bufio.NewWriter(stdin)
	for {
		select {
		case line := <-s.stdin:
			w.WriteString(line + "\n")
			if w.Flush() != nil {
				return // pipe chiusa: il processo sta uscendo
			}
		case <-s.exited:
			return
		}
	}
}

// Send invia un comando alla console del server. Prima, a coda piena, il
// comando spariva in silenzio (un "save-on" perso = salvataggi spenti per
// sempre): ora se la coda resta piena oltre sendTimeout (server bloccato che
// non legge stdin) restituisce ErrSendTimeout.
func (s *Supervisor) Send(cmd string) error {
	select {
	case <-s.exited:
		return ErrNotRunning
	default:
	}
	t := time.NewTimer(sendTimeout)
	defer t.Stop()
	select {
	case s.stdin <- cmd:
		return nil
	case <-s.exited:
		return ErrNotRunning
	case <-t.C:
		return ErrSendTimeout
	}
}

// trySend accoda senza attendere (per i percorsi che non possono bloccare).
func (s *Supervisor) trySend(cmd string) {
	select {
	case s.stdin <- cmd:
	default:
	}
}

// Stop chiede lo spegnimento pulito.
func (s *Supervisor) Stop() error { return s.Send("stop") }

// Kill termina il processo E i suoi figli (ultima spiaggia: uno script
// bloccato su pause/read terrebbe java orfano se uccidessimo solo lui).
func (s *Supervisor) Kill() {
	killTree(s.cmd)
}

// Running riporta se il processo è vivo.
func (s *Supervisor) Running() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.running
}

// logPrefixRe isola il messaggio dai prefissi del log ("[12:00:00] [Server
// thread/INFO]: testo"). Serve a non far pilotare la macchina a stati dalla
// chat: un giocatore che scrive "Saved the game" non deve far credere a
// MineSync che il mondo sia stato salvato.
var logPrefixRe = regexp.MustCompile(`^(?:\[[^\]]*\]:? *)+`)

// systemBody restituisce il corpo del messaggio in minuscolo, oppure "" se la
// riga è (o sembra) chat di un giocatore.
func systemBody(line string) string {
	body := logPrefixRe.ReplaceAllString(line, "")
	if strings.ContainsAny(body, "<>") || strings.Contains(line, "[Not Secure]") {
		return ""
	}
	return strings.ToLower(strings.TrimSpace(body))
}

// IsSaveConfirmed riconosce le righe di conferma del flush del mondo.
func IsSaveConfirmed(line string) bool {
	l := systemBody(line)
	return strings.Contains(l, "saved the game") ||
		strings.Contains(l, "all dimensions are saved") ||
		strings.Contains(l, "saved the world")
}

// IsSaving riconosce le righe di avanzamento del salvataggio: su un mondo
// grande arrivano per minuti, una per dimensione, e servono a capire che il
// server sta lavorando invece di essersi piantato.
func IsSaving(line string) bool {
	l := systemBody(line)
	return strings.Contains(l, "saving chunks for level") ||
		strings.Contains(l, "saving the game") ||
		strings.Contains(l, "saving players") ||
		strings.Contains(l, "saving worlds")
}

// IsStopping riconosce l'inizio dello spegnimento del server.
func IsStopping(line string) bool {
	l := systemBody(line)
	return strings.Contains(l, "stopping server") || strings.Contains(l, "stopping the server")
}

// IsDone riconosce la riga "Done (X.XXXs)!" di avvio completato.
func IsDone(line string) bool {
	l := systemBody(line)
	return strings.Contains(l, "done (") && strings.Contains(l, ")!")
}

// IsEULA riconosce il rifiuto di avvio per EULA non accettata: senza questo
// l'uscita immediata sembra un crash e MineSync riprova due volte a vuoto.
func IsEULA(line string) bool {
	l := strings.ToLower(line)
	return strings.Contains(l, "you need to agree to the eula") ||
		strings.Contains(l, "agree to the minecraft eula")
}

// playerEventRe riconosce le righe di sistema di join/leave. È ancorata al
// prefisso del log ("[HH:MM:SS] [Server thread/INFO]: ") perché il testo nudo
// arriva anche dalla chat: senza ancoraggio bastava scrivere "Tizio left the
// game" per cancellare Tizio dalla lista giocatori e far scattare l'autostop
// a server pieno. Il nome è un nick Minecraft valido (o Bedrock via Geyser,
// che ammette il punto iniziale e lo spazio).
var playerEventRe = regexp.MustCompile(`^\[[^\]]*\]:? *(?:\[[^\]]*\]:? *)*([.A-Za-z0-9_ ]{1,32}?) (joined|left) the game\s*$`)

// PlayerEvent estrae join/leave dei giocatori dalle righe di sistema.
func PlayerEvent(line string) (name string, joined, ok bool) {
	// una riga di chat contiene sempre il nome fra parentesi angolari o il
	// marchio [Not Secure]: non è mai un evento di sistema
	if strings.Contains(line, "<") || strings.Contains(line, "[Not Secure]") {
		return "", false, false
	}
	m := playerEventRe.FindStringSubmatch(line)
	if m == nil {
		return "", false, false
	}
	name = strings.TrimSpace(m[1])
	if name == "" {
		return "", false, false
	}
	return name, m[2] == "joined", true
}

// prependPath antepone dir alla variabile PATH nella slice d'ambiente (case
// insensitive: su Windows la chiave è "Path"). Se PATH manca, la crea.
func prependPath(env []string, dir string) []string {
	sep := string(os.PathListSeparator)
	for i, kv := range env {
		k, v, ok := strings.Cut(kv, "=")
		if ok && strings.EqualFold(k, "PATH") {
			env[i] = k + "=" + dir + sep + v
			return env
		}
	}
	return append(env, "PATH="+dir)
}
