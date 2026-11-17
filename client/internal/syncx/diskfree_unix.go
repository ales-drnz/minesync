//go:build linux || darwin || freebsd

package syncx

import "syscall"

// diskFree: byte liberi (per l'utente) sul volume che contiene path, -1 se
// non si sa.
func diskFree(path string) int64 {
	var st syscall.Statfs_t
	if err := syscall.Statfs(existingDir(path), &st); err != nil {
		return -1
	}
	return int64(uint64(st.Bavail) * uint64(st.Bsize))
}
