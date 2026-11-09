package mc

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

// Coda piena e nessuno che legge: Send deve arrendersi con un errore, non
// scartare in silenzio né bloccare per sempre.
func TestSendTimeout(t *testing.T) {
	old := sendTimeout
	sendTimeout = 50 * time.Millisecond
	defer func() { sendTimeout = old }()

	s := &Supervisor{stdin: make(chan string), exited: make(chan struct{})}
	start := time.Now()
	if err := s.Send("save-on"); !errors.Is(err, ErrSendTimeout) {
		t.Fatalf("atteso ErrSendTimeout, got %v", err)
	}
	if time.Since(start) > time.Second {
		t.Fatal("Send ha atteso troppo")
	}
}

func TestSendAfterExit(t *testing.T) {
	s := &Supervisor{stdin: make(chan string, 1), exited: make(chan struct{})}
	if err := s.Send("list"); err != nil {
		t.Fatalf("con spazio in coda Send deve riuscire: %v", err)
	}
	close(s.exited)
	if err := s.Send("list"); !errors.Is(err, ErrNotRunning) {
		t.Fatalf("a processo terminato atteso ErrNotRunning, got %v", err)
	}
}

// Processo vero: i comandi arrivano, e all'uscita la goroutine di stdin
// termina (Send restituisce ErrNotRunning invece di accodare).
func TestSupervisorRoundTrip(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("script sh")
	}
	script := filepath.Join(t.TempDir(), "run.sh")
	os.WriteFile(script, []byte("read x\necho \"got $x\"\nsleep 0.3\n"), 0o755)
	s, err := Start(context.Background(), ServerInfo{Dir: filepath.Dir(script), Launch: []string{"sh", "run.sh"}}, "")
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Send("ciao"); err != nil {
		t.Fatal(err)
	}
	var got string
	for l := range s.Lines {
		got = l
	}
	if got != "got ciao" {
		t.Fatalf("output %q", got)
	}
	select {
	case <-s.Exited:
	case <-time.After(5 * time.Second):
		t.Fatal("processo non terminato")
	}
	if s.Running() {
		t.Fatal("Running() dopo l'uscita")
	}
	if err := s.Send("x"); !errors.Is(err, ErrNotRunning) {
		t.Fatalf("Send dopo l'uscita: %v", err)
	}
}

// La cancellazione del context manda "stop" sulla console e NON uccide
// subito: uno script che ignora SIGTERM (come cmd.exe su Windows, dove il
// segnale non esiste) riceve lo stop ed esce pulito da solo.
func TestCancelSendsStop(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("script sh")
	}
	script := filepath.Join(t.TempDir(), "run.sh")
	os.WriteFile(script, []byte("trap '' TERM\necho pronto\nwhile read x; do [ \"$x\" = stop ] && echo bye && exit 0; done\n"), 0o755)
	ctx, cancel := context.WithCancel(context.Background())
	s, err := Start(ctx, ServerInfo{Dir: filepath.Dir(script), Launch: []string{"sh", "run.sh"}}, "")
	if err != nil {
		t.Fatal(err)
	}
	<-s.Lines // trap installata: ora il SIGTERM non lo ferma
	start := time.Now()
	cancel()
	var last string
	for l := range s.Lines {
		last = l
	}
	var err2 error
	select {
	case err2 = <-s.Exited:
	case <-time.After(10 * time.Second):
		t.Fatal("processo non terminato dopo stop")
	}
	if time.Since(start) > 10*time.Second {
		t.Fatal("uscita arrivata solo col kill, non con lo stop")
	}
	// l'ultima riga può perdersi se Wait chiude la pipe prima del pump:
	// conta che lo script sia uscito da solo (codice 0), non ucciso
	if err := err2; err != nil && !errors.Is(err, context.Canceled) && last != "bye" {
		t.Fatalf("lo script non ha ricevuto stop: %v (ultima riga %q)", err, last)
	}
}
