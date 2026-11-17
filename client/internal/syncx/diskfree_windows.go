package syncx

import (
	"syscall"
	"unsafe"
)

var procDiskFree = syscall.NewLazyDLL("kernel32.dll").NewProc("GetDiskFreeSpaceExW")

// diskFree: byte liberi (per l'utente, quote comprese) sul volume che
// contiene path, -1 se non si sa.
func diskFree(path string) int64 {
	p, err := syscall.UTF16PtrFromString(existingDir(path))
	if err != nil {
		return -1
	}
	var avail, total, free uint64
	r, _, _ := procDiskFree.Call(uintptr(unsafe.Pointer(p)),
		uintptr(unsafe.Pointer(&avail)), uintptr(unsafe.Pointer(&total)), uintptr(unsafe.Pointer(&free)))
	if r == 0 {
		return -1
	}
	return int64(avail)
}
