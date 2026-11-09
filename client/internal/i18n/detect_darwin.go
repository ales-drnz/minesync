//go:build darwin

package i18n

import (
	"context"
	"os/exec"
	"time"
)

// FromOS: prima le variabili di locale (il Terminale di macOS di solito
// imposta LANG), poi le lingue preferite di sistema.
func FromOS() (Lang, bool) {
	if l, ok := fromEnv(); ok {
		return l, true
	}
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	out, err := exec.CommandContext(ctx, "defaults", "read", "-g", "AppleLanguages").Output()
	if err != nil {
		return "", false
	}
	return parseAppleLanguages(string(out))
}
