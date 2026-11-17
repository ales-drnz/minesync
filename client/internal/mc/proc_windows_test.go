//go:build windows

package mc

import (
	"os/exec"
	"testing"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Il job creato per il server ha davvero KILL_ON_JOB_CLOSE.
func TestJobKillOnClose(t *testing.T) {
	job, err := newKillOnCloseJob()
	if err != nil {
		t.Fatal(err)
	}
	defer windows.CloseHandle(job)
	var info windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION
	if err := windows.QueryInformationJobObject(job, windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info)), nil); err != nil {
		t.Fatal(err)
	}
	if info.BasicLimitInformation.LimitFlags&windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE == 0 {
		t.Errorf("flag del job: %#x", info.BasicLimitInformation.LimitFlags)
	}
}

var procIsProcessInJob = windows.NewLazySystemDLL("kernel32.dll").NewProc("IsProcessInJob")

func inJob(t *testing.T, proc, job windows.Handle) bool {
	t.Helper()
	var res int32
	r, _, err := procIsProcessInJob.Call(uintptr(proc), uintptr(job), uintptr(unsafe.Pointer(&res)))
	if r == 0 {
		t.Fatal(err)
	}
	return res != 0
}

// Dopo setProcAttr il client e i processi che avvia stanno nel job: se il
// client muore, Windows li termina con lui.
func TestFigliNelJob(t *testing.T) {
	cmd := exec.Command("cmd", "/c", "ping", "-n", "3", "127.0.0.1")
	setProcAttr(cmd)
	if jobErr != nil {
		t.Skipf("job non disponibile: %v", jobErr)
	}
	if !inJob(t, windows.CurrentProcess(), jobHandle) {
		t.Fatal("il client non è nel job")
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer killTree(cmd)
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(cmd.Process.Pid))
	if err != nil {
		t.Fatal(err)
	}
	defer windows.CloseHandle(h)
	if !inJob(t, h, jobHandle) {
		t.Error("lo script non ha ereditato il job")
	}
}
