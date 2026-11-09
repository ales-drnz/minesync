//go:build windows

// Package launch (windows): il doppio click crea sempre una console, quindi
// qui non serve rilanciarsi.
package launch

// HasTerminal: su Windows il doppio click crea sempre una console, quindi la
// TUI ha sempre dove disegnarsi.
func HasTerminal() bool { return true }

// EnsureTerminal è un no-op su Windows: la console esiste già.
func EnsureTerminal() {}
