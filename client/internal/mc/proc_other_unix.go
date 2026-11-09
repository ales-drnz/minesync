//go:build !windows && !linux

package mc

import (
	"os/exec"
	"syscall"
)

// setProcAttr mette lo script in un process group proprio, così il kill
// di sicurezza raggiunge anche java (figlio di sh), non solo sh.
// (Pdeathsig esiste solo su Linux.)
func setProcAttr(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}
