//go:build windows

package i18n

import (
	"syscall"
	"unsafe"
)

var (
	kernel32                     = syscall.NewLazyDLL("kernel32.dll")
	procGetUserDefaultUILanguage = kernel32.NewProc("GetUserDefaultUILanguage")
	procGetUserDefaultLocaleName = kernel32.NewProc("GetUserDefaultLocaleName")
)

// FromOS: lingua dell'interfaccia di Windows, poi il locale dell'utente; le
// variabili POSIX (es. da Git Bash/MSYS) solo come ultima risorsa.
func FromOS() (Lang, bool) {
	if procGetUserDefaultUILanguage.Find() == nil {
		id, _, _ := procGetUserDefaultUILanguage.Call()
		switch id & 0x3ff { // primary language id del LANGID
		case 0x10:
			return IT, true
		case 0x09:
			return EN, true
		}
	}
	if procGetUserDefaultLocaleName.Find() == nil {
		buf := make([]uint16, 85) // LOCALE_NAME_MAX_LENGTH
		n, _, _ := procGetUserDefaultLocaleName.Call(uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
		if n > 0 {
			if l, ok := Parse(syscall.UTF16ToString(buf)); ok {
				return l, true
			}
		}
	}
	return fromEnv()
}
