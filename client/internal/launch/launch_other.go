//go:build !windows

// Package launch (unix): la TUI aperta con doppio click dal file manager non
// ha nessun terminale sotto — /dev/tty non esiste e bubbletea muore con
// "could not open a new TTY". Come su Windows ci si rilancia da soli, qui
// dentro un emulatore di terminale.
package launch

import (
	"os"
	"os/exec"
	"runtime"

	"minesync/client/internal/i18n"
)

// reexecEnv marca il processo figlio: senza, un terminale che parte male
// (o senza tty a sua volta) darebbe una catena infinita di rilanci.
const reexecEnv = "MINESYNC_OWN_WINDOW"

// terminals: emulatori provati in ordine, con il flag che introduce il comando.
// Il primo trovato nel PATH vince. Su KDE è konsole, su GNOME gnome-terminal
// o ptyxis; x-terminal-emulator è l'alias Debian del preferito di sistema.
var terminals = []struct {
	bin  string
	args []string
}{
	{"x-terminal-emulator", []string{"-e"}},
	{"konsole", []string{"-e"}},
	{"gnome-terminal", []string{"--"}},
	{"ptyxis", []string{"--"}},
	{"kgx", []string{"--"}},
	{"tilix", []string{"-e"}},
	{"alacritty", []string{"-e"}},
	{"kitty", []string{"--"}},
	{"wezterm", []string{"start", "--"}},
	{"foot", nil},
	{"xfce4-terminal", []string{"-x"}},
	{"terminator", []string{"-x"}},
	{"xterm", []string{"-e"}},
}

// keepOpen tiene la finestra aperta solo se il client esce male: dopo
// un'uscita normale chiuderla è giusto, su un errore chiuderla nasconde
// il messaggio (che comunque finisce in ~/.minesync/last-error.log).
// Il messaggio arriva come $2 (tradotto), così nessun testo finisce
// interpretato dalla shell.
const keepOpen = `"$1" || { code=$?; echo; printf "$2\n" "$code"; read _; }`

// EnsureTerminal: se siamo senza terminale, si rilancia dentro uno e esce.
// Torna normalmente quando un terminale c'è già (uso normale da shell).
func EnsureTerminal() {
	if len(os.Args) > 1 {
		return // uso da CLI con sottocomandi: eredita il terminale del chiamante
	}
	if os.Getenv(reexecEnv) == "1" {
		return // siamo già il figlio: qualunque cosa succeda, non si rilancia più
	}
	if hasTTY() {
		return
	}
	exe, err := os.Executable()
	if err != nil {
		return
	}
	cmd := terminalCmd(exe)
	if cmd == nil {
		return // nessun emulatore: ci pensa tui.Run a spiegarlo
	}
	cmd.Env = append(os.Environ(), reexecEnv+"=1")
	if err := cmd.Start(); err != nil {
		return
	}
	os.Exit(0)
}

// hasTTY dice se esiste un terminale di controllo, cioè la condizione che
// serve a bubbletea: apre /dev/tty come fa lui.
func hasTTY() bool {
	f, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		return false
	}
	f.Close()
	return true
}

// terminalCmd prepara il comando che apre exe in una finestra di terminale.
func terminalCmd(exe string) *exec.Cmd {
	if runtime.GOOS == "darwin" {
		if path, err := exec.LookPath("open"); err == nil {
			return exec.Command(path, "-a", "Terminal", exe)
		}
		return nil
	}
	cands := terminals
	if pref := os.Getenv("TERMINAL"); pref != "" {
		cands = append([]struct {
			bin  string
			args []string
		}{{pref, []string{"-e"}}}, cands...)
	}
	for _, t := range cands {
		path, err := exec.LookPath(t.bin)
		if err != nil {
			continue
		}
		msg := i18n.S("MineSync è uscito con errore %s. Premi invio per chiudere.")
		args := append(append([]string{}, t.args...), "sh", "-c", keepOpen, "minesync", exe, msg)
		return exec.Command(path, args...)
	}
	return nil
}

// HasTerminal dice se la TUI ha dove disegnarsi: un tty, oppure un emulatore
// da aprire. Serve a dare un errore comprensibile invece di quello di bubbletea.
func HasTerminal() bool {
	return hasTTY() || terminalCmd("x") != nil
}
