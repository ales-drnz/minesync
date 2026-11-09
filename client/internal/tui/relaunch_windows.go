//go:build windows

package tui

import (
	"errors"
	"os"
	"os/exec"

	"minesync/client/internal/selfupdate"
)

// relaunch avvia il binario aggiornato ereditando la stessa console (Windows
// non ha execve). Il padre ASPETTA il figlio ed esce col suo codice: se
// uscisse subito, la shell tornerebbe al prompt e leggerebbe la console
// insieme alla nuova TUI (R10).
func relaunch() error {
	exe, err := selfupdate.TargetExe()
	if err != nil {
		return err
	}
	cmd := exec.Command(exe, os.Args[1:]...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	cmd.Env = os.Environ()
	err = cmd.Run()
	var ee *exec.ExitError
	switch {
	case err == nil:
		os.Exit(0)
	case errors.As(err, &ee):
		os.Exit(ee.ExitCode())
	}
	return err // il figlio non è partito: lo segnala il chiamante
}
