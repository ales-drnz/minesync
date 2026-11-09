package mc

import (
	"bufio"
	"strings"
	"testing"
)

// Le righe di sistema vanno riconosciute su tutti i loader; la chat NON deve
// mai poter pilotare la macchina a stati. Prima bastava scrivere in chat
// "Tizio left the game" per svuotare la lista giocatori e far scattare
// l'arresto automatico con il server pieno.
func TestPlayerEventIgnoraLaChat(t *testing.T) {
	sistema := []struct {
		line   string
		name   string
		joined bool
	}{
		{"[22:20:14] [Server thread/INFO]: FazenWolf joined the game", "FazenWolf", true},
		{"[22:23:33] [Server thread/INFO]: KitzuGG left the game", "KitzuGG", false},
		{"[12:00:00] [Server thread/INFO] [minecraft/MinecraftServer]: Steve joined the game", "Steve", true},
		{"[Server thread/INFO]: Alex_99 left the game", "Alex_99", false},
		{"[22:20:14] [Server thread/INFO]: .BedrockUser joined the game", ".BedrockUser", true},
	}
	for _, c := range sistema {
		name, joined, ok := PlayerEvent(c.line)
		if !ok || name != c.name || joined != c.joined {
			t.Errorf("riga di sistema non riconosciuta: %q -> (%q,%v,%v)", c.line, name, joined, ok)
		}
	}

	chat := []string{
		"[22:20:14] [Server thread/INFO]: <Bob> alex left the game",
		"[22:20:14] [Server thread/INFO]: <Bob> chi e' appena joined the game?",
		"[22:20:14] [Server thread/INFO]: [Not Secure] <Bob> alex left the game",
		"[22:20:14] [Server thread/INFO]: <alex> FazenWolf joined the game",
	}
	for _, l := range chat {
		if name, _, ok := PlayerEvent(l); ok {
			t.Errorf("chat scambiata per evento di sistema: %q -> %q", l, name)
		}
	}
}

// Stessa difesa per i fatti che governano avvio, spegnimento e salvataggio.
func TestFattiIgnoranoLaChat(t *testing.T) {
	if !IsDone(`[12:00:00] [Server thread/INFO]: Done (41.402s)! For help, type "help"`) {
		t.Error("avvio completato non riconosciuto")
	}
	if !IsSaveConfirmed("[12:00:00] [Server thread/INFO]: Saved the game") {
		t.Error("salvataggio non riconosciuto")
	}
	if !IsSaving("[12:00:00] [Server thread/INFO]: Saving chunks for level ServerLevel[world]") {
		t.Error("avanzamento del salvataggio non riconosciuto")
	}
	if !IsStopping("[12:00:00] [Server thread/INFO]: Stopping server") {
		t.Error("spegnimento non riconosciuto")
	}
	falsi := []string{
		"[12:00:00] [Server thread/INFO]: <Bob> Saved the game",
		"[12:00:00] [Server thread/INFO]: <Bob> Stopping server adesso",
		"[12:00:00] [Server thread/INFO]: <Bob> Done (1.0s)!",
	}
	for _, l := range falsi {
		if IsSaveConfirmed(l) || IsStopping(l) || IsDone(l) {
			t.Errorf("chat scambiata per fatto di sistema: %q", l)
		}
	}
}

// Una riga chilometrica (dump del classpath di ModLauncher, NBT stampato da un
// mod) non deve far smettere di leggere: prima il bufio.Scanner restituiva
// ErrTooLong, il pump usciva, nessuno drenava più la pipe e il server si
// bloccava sulla write senza un messaggio d'errore.
func TestReadLineNonSiArrendeSulleRigheLunghe(t *testing.T) {
	mostro := strings.Repeat("x", maxLine*3)
	input := "prima riga\n" + mostro + "\nDone (1.234s)! For help, type \"help\"\n"
	br := bufio.NewReaderSize(strings.NewReader(input), 4096)

	var righe []string
	for {
		l, ok := readLine(br)
		if !ok {
			break
		}
		righe = append(righe, l)
	}
	if len(righe) != 3 {
		t.Fatalf("lette %d righe, attese 3: %v", len(righe), primeParole(righe))
	}
	if righe[0] != "prima riga" {
		t.Errorf("prima riga alterata: %q", righe[0])
	}
	if len(righe[1]) > maxLine+64 {
		t.Errorf("la riga mostruosa non e' stata troncata: %d byte", len(righe[1]))
	}
	if !IsDone(righe[2]) {
		t.Errorf("la riga DOPO quella lunga e' andata persa o alterata: %q", righe[2])
	}
}

func primeParole(righe []string) []string {
	out := make([]string, len(righe))
	for i, r := range righe {
		if len(r) > 30 {
			r = r[:30] + "…"
		}
		out[i] = r
	}
	return out
}

// I fatti riconosciuti finiscono in coda e non si perdono anche se nessuno
// legge le righe.
func TestClassifyAlimentaLaCoda(t *testing.T) {
	s := &Supervisor{}
	righe := []string{
		"[12:00:00] [Server thread/INFO]: Done (10.0s)! For help, type \"help\"",
		"[12:00:01] [Server thread/INFO]: Pippo joined the game",
		"[12:00:02] [Server thread/INFO]: <Pippo> ciao a tutti",
		"[12:00:03] [Server thread/INFO]: Saved the game",
	}
	for _, l := range righe {
		if e, ok := classify(l); ok {
			s.pushEv(e)
		}
	}
	evs := s.DrainEvents()
	if len(evs) != 3 {
		t.Fatalf("fatti in coda: %d, attesi 3 (la chat non conta)", len(evs))
	}
	if evs[0].Kind != EvStarted || evs[1].Kind != EvJoin || evs[1].Name != "Pippo" || evs[2].Kind != EvSaved {
		t.Errorf("coda inattesa: %+v", evs)
	}
	if len(s.DrainEvents()) != 0 {
		t.Error("la coda non si e' svuotata")
	}
}
