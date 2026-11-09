//go:build !windows

package mc

import (
	"os/exec"
	"syscall"
)

// interruptTree è il primo passo alla cancellazione del contesto (vedi
// Start): exec.CommandContext ucciderebbe solo il processo diretto, e se lo
// script non fa `exec` quello è la shell — java resterebbe ORFANO a scrivere
// il mondo e tenere la porta mentre MineSync crede di aver chiuso, pusha e
// rilascia il lock. Qui si avvisa tutto il gruppo, con garbo (SIGTERM: il
// server salva); il kill vero arriva solo dopo il periodo di grazia.
func interruptTree(cmd *exec.Cmd) error {
	if cmd.Process == nil {
		return nil
	}
	return syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
}

func killTree(cmd *exec.Cmd) {
	if cmd.Process == nil {
		return
	}
	syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) // tutto il gruppo
	cmd.Process.Kill()
}
