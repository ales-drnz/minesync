//go:build !windows

package tui

import (
	"os"
	"syscall"

	"minesync/client/internal/selfupdate"
)

// relaunch rimpiazza il processo corrente con il binario aggiornato, mantenendo
// lo stesso terminale (execve). Non torna mai in caso di successo.
func relaunch() error {
	exe, err := selfupdate.TargetExe()
	if err != nil {
		return err
	}
	return syscall.Exec(exe, os.Args, os.Environ())
}
