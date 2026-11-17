//go:build windows

package mc

import (
	"os/exec"
	"strconv"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
)

// setProcAttr: prima di avviare il server MineSync entra in un Job Object con
// JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE (3.2.0). I figli ereditano il job (lo
// script cmd.exe, e java figlio suo), e l'unico handle del job lo tiene questo
// processo: se MineSync muore senza fermare la sessione (crash, chiusura
// forzata da Gestione attività, kill), Windows chiude l'handle e termina
// tutto l'albero. Prima java restava ORFANO a tenere il mondo e la porta.
//
// Si entra nel job prima di Start, non dopo: un albero assegnato a processo
// già partito lascerebbe fuori i figli nati nel frattempo. Il job permette il
// breakaway (CREATE_BREAKAWAY_FROM_JOB) per un eventuale processo che debba
// sopravvivere al client. Se il job non si riesce a creare (Windows molto
// vecchi con il client già dentro un job) resta il comportamento di prima.
//
// La via normale resta lo stop pulito: "stop" sulla console e, dopo il
// periodo di grazia, taskkill (killTree).
func setProcAttr(*exec.Cmd) { ensureJob() }

var (
	jobOnce sync.Once
	jobErr  error
	// jobHandle non si chiude mai: chiuderlo ucciderebbe il client stesso.
	jobHandle windows.Handle
)

// ensureJob mette (una volta sola) il processo corrente nel job kill-on-close.
func ensureJob() error {
	jobOnce.Do(func() {
		job, err := newKillOnCloseJob()
		if err != nil {
			jobErr = err
			return
		}
		if err := windows.AssignProcessToJobObject(job, windows.CurrentProcess()); err != nil {
			windows.CloseHandle(job)
			jobErr = err
			return
		}
		jobHandle = job
	})
	return jobErr
}

// newKillOnCloseJob crea un job anonimo che termina i suoi processi quando
// l'ultimo handle si chiude.
func newKillOnCloseJob() (windows.Handle, error) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return 0, err
	}
	var info windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION
	info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE |
		windows.JOB_OBJECT_LIMIT_BREAKAWAY_OK
	if _, err := windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info))); err != nil {
		windows.CloseHandle(job)
		return 0, err
	}
	return job, nil
}

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
