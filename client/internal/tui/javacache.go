package tui

import (
	tea "github.com/charmbracelet/bubbletea"

	"minesync/client/internal/mc"
)

// Cache dei runtime Java (R7): il rilevamento lancia `java -version` (con
// timeout) e gira sempre in un tea.Cmd, mai in View/Update. L'esito resta
// nell'App, così la dashboard non rilancia nulla a ogni frame e la sessione
// riceve il runtime già trovato invece di ripetere il rilevamento.

// javaKey identifica una risoluzione: cambia se cambia la scelta manuale,
// la cartella o la versione di Minecraft del modpack.
type javaKey struct {
	space, path, dir, mcVersion string
}

// javaRes è il runtime risolto per uno spazio.
type javaRes struct {
	java mc.JavaInfo
	req  int // major richiesto dal modpack (0 = ignoto)
}

// javaResolvedMsg porta una risoluzione fatta fuori dal thread UI. javas è
// la lista dei runtime installati se è stato necessario rilevarla (nil se no).
type javaResolvedMsg struct {
	key   javaKey
	res   javaRes
	javas []mc.JavaInfo
}

// javasDetectedMsg porta il rilevamento completo (schermata java, tasto r).
type javasDetectedMsg struct{ javas []mc.JavaInfo }

func (a *App) javaKeyFor(spaceID string, info mc.ServerInfo) javaKey {
	return javaKey{space: spaceID, path: a.cfg.Spaces[spaceID].JavaPath,
		dir: info.Dir, mcVersion: info.MCVersion}
}

// cachedJava restituisce la risoluzione in cache (ok=false se non ancora pronta).
func (a *App) cachedJava(spaceID string, info mc.ServerInfo) (javaRes, bool) {
	r, ok := a.javaCache[a.javaKeyFor(spaceID, info)]
	return r, ok
}

// requestJava avvia (se serve) la risoluzione del runtime per uno spazio.
// nil se è già in cache o in corso.
func (a *App) requestJava(spaceID string, info mc.ServerInfo) tea.Cmd {
	key := a.javaKeyFor(spaceID, info)
	if _, ok := a.javaCache[key]; ok || a.javaPending[key] {
		return nil
	}
	a.javaPending[key] = true
	known, haveKnown := a.javas, a.javasOK // snapshot: il Cmd non legge l'App
	return func() tea.Msg {
		var detected []mc.JavaInfo
		detect := func() []mc.JavaInfo {
			if haveKnown {
				return known
			}
			if detected == nil {
				detected = mc.DetectJavas()
				if detected == nil {
					detected = []mc.JavaInfo{}
				}
			}
			return detected
		}
		j, req := mc.PreviewJava(info, key.path, detect)
		return javaResolvedMsg{key: key, res: javaRes{java: j, req: req}, javas: detected}
	}
}

// detectJavas rileva tutti i runtime installati (fuori dal thread UI).
func detectJavas() tea.Cmd {
	return func() tea.Msg { return javasDetectedMsg{javas: mc.DetectJavas()} }
}

// handleJava aggiorna la cache con gli esiti dei rilevamenti.
func (a *App) handleJava(msg tea.Msg) tea.Cmd {
	switch msg := msg.(type) {
	case javaResolvedMsg:
		delete(a.javaPending, msg.key)
		a.javaCache[msg.key] = msg.res
		if msg.javas != nil && !a.javasOK {
			a.javas, a.javasOK = msg.javas, true
		}
	case javasDetectedMsg:
		// rilevamento esplicito (es. Java appena installato): le risoluzioni
		// automatiche vanno rifatte con la lista nuova
		a.javas, a.javasOK = msg.javas, true
		a.javaCache = map[javaKey]javaRes{}
	}
	return nil
}
