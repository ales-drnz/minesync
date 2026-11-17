//go:build !linux && !darwin && !freebsd && !windows

package syncx

// diskFree: su questi sistemi non si misura (-1 = ignoto, nessun controllo).
func diskFree(string) int64 { return -1 }
