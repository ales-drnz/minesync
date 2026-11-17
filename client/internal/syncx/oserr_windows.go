package syncx

import (
	"errors"
	"syscall"
)

// isSharingViolation: file aperto in esclusiva da un altro processo (il
// server stesso, un antivirus, un backup): ERROR_SHARING_VIOLATION (32) o
// ERROR_LOCK_VIOLATION (33).
func isSharingViolation(err error) bool {
	var en syscall.Errno
	return errors.As(err, &en) && (en == 32 || en == 33)
}
