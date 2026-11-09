//go:build !windows && !darwin

package i18n

// FromOS rileva la lingua del sistema dalle variabili di locale.
func FromOS() (Lang, bool) { return fromEnv() }
