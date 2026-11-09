//go:build linux

package mc

import (
	"os/exec"
	"syscall"
)

// setProcAttr mette lo script in un process group proprio, così il kill
// di sicurezza raggiunge anche java (figlio di sh), non solo sh.
//
// Pdeathsig è l'ultima spiaggia contro il server orfano (R2): se MineSync
// muore senza riuscire a fermare la sessione (kill -9, crash del runtime),
// il kernel manda SIGTERM allo script. Limiti noti: arriva solo al figlio
// diretto (sh; java lo riceve se lo script fa `exec java` o se sh lo
// propaga) e scatta alla morte del thread che ha creato il processo. La via
// normale resta lo stop pulito gestito dalla TUI.
func setProcAttr(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pdeathsig: syscall.SIGTERM}
}
