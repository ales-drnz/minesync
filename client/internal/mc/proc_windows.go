//go:build windows

package mc

import (
	"os/exec"
	"strconv"
)

func setProcAttr(*exec.Cmd) {}

// interruptTree: su Windows non c'è un SIGTERM da mandare all'albero; alla
// cancellazione basta lo "stop" sulla console (vedi Start). Prima qui c'era
// taskkill /F immediato, che uccideva Java senza salvare (R5).
func interruptTree(*exec.Cmd) error { return nil }

// killTree termina cmd e tutti i suoi figli (cmd.exe → java). È l'ULTIMA
// spiaggia, dopo il periodo di grazia.
func killTree(cmd *exec.Cmd) {
	if cmd.Process == nil {
		return
	}
	exec.Command("taskkill", "/T", "/F", "/PID", strconv.Itoa(cmd.Process.Pid)).Run()
	cmd.Process.Kill()
}
