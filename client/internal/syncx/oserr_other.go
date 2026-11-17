//go:build !windows

package syncx

// isSharingViolation: solo Windows blocca i file aperti da altri processi.
func isSharingViolation(error) bool { return false }
