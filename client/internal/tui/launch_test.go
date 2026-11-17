package tui

import (
	"testing"

	"minesync/client/internal/session"
)

// Il Play parte spesso da una cartella ancora vuota: dopo il pull la sessione
// comunica Java, script e porta veri, e i riquadri devono aggiornarsi invece
// di restare su "mancante!".
func TestPlayAggiornaJavaDopoIlPull(t *testing.T) {
	p := &playScreen{script: "?", port: "25565"}
	if got := p.viewServer(); !contains(got, "mancante!") {
		t.Fatalf("prima del pull il riquadro dovrebbe dire mancante: %q", got)
	}
	p.applyEvent(session.Event{Kind: session.EvLaunch, Java: "21.0.7", Script: "start.bat", Port: "25570"})
	if p.java != "21.0.7" || p.script != "start.bat" || p.port != "25570" {
		t.Fatalf("dopo EvLaunch: java=%q script=%q port=%q", p.java, p.script, p.port)
	}
	if got := p.viewServer(); contains(got, "mancante!") {
		t.Fatalf("dopo il pull il riquadro dice ancora mancante: %q", got)
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
