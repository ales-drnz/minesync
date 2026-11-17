//go:build linux || darwin

package store

import "syscall"

// diskStat misura il volume che contiene path (statfs): byte liberi per
// gli utenti non privilegiati e byte totali.
func diskStat(path string) (free, total uint64, err error) {
	var fs syscall.Statfs_t
	if err := syscall.Statfs(path, &fs); err != nil {
		return 0, 0, err
	}
	bs := uint64(fs.Bsize)
	return uint64(fs.Bavail) * bs, uint64(fs.Blocks) * bs, nil
}
