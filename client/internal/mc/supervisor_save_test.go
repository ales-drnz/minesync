package mc

import "testing"

// A: la conferma di salvataggio si riconosce solo come corpo ESATTO di una
// riga INFO del thread del server, nei formati veri dei vari server.
func TestConfermaSalvataggioFormatiVeri(t *testing.T) {
	veri := []string{
		"[12:00:00] [Server thread/INFO]: Saved the game",
		"[12:00:00] [Server thread/INFO] [minecraft/MinecraftServer]: Saved the game",
		"[29Jan2024 12:00:00.123] [Server thread/INFO] [net.minecraft.server.MinecraftServer/]: Saved the game",
		"[12:00:00] [Server thread/INFO] (Minecraft) Saved the game",
		"[12:00:00 INFO]: Saved the game",
		"> [12:00:00 INFO]: Saved the game",
		"[12:00:00] [Server thread/INFO]: ThreadedAnvilChunkStorage: All dimensions are saved",
		"[12:00:00] [Server thread/INFO]: Saved the game\r",
	}
	for _, l := range veri {
		if !IsSaveConfirmed(l) {
			t.Errorf("conferma vera non riconosciuta: %q", l)
		}
	}
}

// A: tutti i modi noti di falsificarla dalla chat.
func TestConfermaSalvataggioNonFalsificabile(t *testing.T) {
	falsi := []string{
		"[12:00:00] [Server thread/INFO]: * Steve Saved the game",                             // /me
		"[12:00:00] [Server thread/INFO]: [Steve] Saved the game",                             // /say
		"[12:00:00] [Server thread/INFO] [minecraft/MinecraftServer]: [Steve] Saved the game", // /say su Forge
		"[12:00:00 INFO]: [Steve] Saved the game",                                             // /say su Paper
		"[12:00:00] [Server thread/INFO]: Steve was slain by Zombie using [Saved the game]",   // oggetto rinominato
		"[12:00:00] [Server thread/INFO]: Steve » Saved the game",                             // mod di chat
		"[12:00:00] [Server thread/INFO]: <Steve> Saved the game",
		"[12:00:00] [Server thread/INFO]: [Not Secure] <Steve> Saved the game",
		"[12:00:00] [Async Chat Thread - #0/INFO]: Saved the game", // non è il thread del server
		"[12:00:00] [Server thread/WARN]: Saved the game",
		"Saved the game",
		"[12:00:00] [Server thread/INFO]: Saved the game, scherzo",
	}
	for _, l := range falsi {
		if IsSaveConfirmed(l) {
			t.Errorf("conferma falsa accettata: %q", l)
		}
	}
}

// A: senza un flush in attesa una conferma non diventa un fatto; con il
// flush in attesa conta UNA volta sola.
func TestConfermaSoloConFlushInAttesa(t *testing.T) {
	s := &Supervisor{}
	line := "[12:00:00] [Server thread/INFO]: Saved the game"
	if _, ok := s.classify(line); ok {
		t.Error("conferma accettata senza save-all flush in attesa")
	}
	s.ExpectSave()
	if e, ok := s.classify(line); !ok || e.Kind != EvSaved {
		t.Error("conferma con flush in attesa ignorata")
	}
	if _, ok := s.classify(line); ok {
		t.Error("una seconda conferma per lo stesso flush")
	}
	// gli altri fatti non dipendono dal flush
	if e, ok := s.classify("[12:00:00] [Server thread/INFO]: Stopping server"); !ok || e.Kind != EvStopping {
		t.Error("stop non riconosciuto")
	}
}
