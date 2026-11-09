package mcmeta

import (
	"encoding/json"
	"io"
	"strings"
)

// PlayerStats sono le statistiche di gioco di un giocatore, da stats/<uuid>.json.
type PlayerStats struct {
	PlayTimeTicks int64 `json:"playTimeTicks"`
	Deaths        int64 `json:"deaths"`
	MobKills      int64 `json:"mobKills"`
	PlayerKills   int64 `json:"playerKills"`
	Jumps         int64 `json:"jumps"`
	WalkCm        int64 `json:"walkCm"` // distanza a piedi, in centimetri
}

// ParsePlayerStats legge le statistiche "custom" di un file stats/<uuid>.json.
func ParsePlayerStats(r io.Reader) (PlayerStats, error) {
	var raw struct {
		Stats map[string]map[string]int64 `json:"stats"`
	}
	if err := json.NewDecoder(r).Decode(&raw); err != nil {
		return PlayerStats{}, err
	}
	c := raw.Stats["minecraft:custom"]
	playtime := c["minecraft:play_time"]
	if playtime == 0 {
		playtime = c["minecraft:play_one_minute"] // nome storico, sempre in tick
	}
	return PlayerStats{
		PlayTimeTicks: playtime,
		Deaths:        c["minecraft:deaths"],
		MobKills:      c["minecraft:mob_kills"],
		PlayerKills:   c["minecraft:player_kills"],
		Jumps:         c["minecraft:jump"],
		WalkCm:        c["minecraft:walk_one_cm"],
	}, nil
}

// ParseNameMap legge un file tipo usercache/whitelist (array di {uuid, name})
// in una mappa uuid→nome. Gli UUID sono normalizzati senza trattini, minuscoli.
func ParseNameMap(r io.Reader) map[string]string {
	var arr []struct {
		UUID string `json:"uuid"`
		Name string `json:"name"`
	}
	if json.NewDecoder(r).Decode(&arr) != nil {
		return nil
	}
	out := make(map[string]string, len(arr))
	for _, e := range arr {
		if e.UUID != "" {
			out[normUUID(e.UUID)] = e.Name
		}
	}
	return out
}

// ParseUUIDSet legge un file (whitelist/ops) restituendo l'insieme degli UUID.
func ParseUUIDSet(r io.Reader) map[string]bool {
	var arr []struct {
		UUID string `json:"uuid"`
	}
	if json.NewDecoder(r).Decode(&arr) != nil {
		return nil
	}
	out := make(map[string]bool, len(arr))
	for _, e := range arr {
		if e.UUID != "" {
			out[normUUID(e.UUID)] = true
		}
	}
	return out
}

// normUUID uniforma un UUID: minuscolo, senza trattini (i file stats sono
// nominati con i trattini, usercache può usarli o no).
func normUUID(u string) string {
	return strings.ToLower(strings.ReplaceAll(u, "-", ""))
}

// NormUUID è la versione esportata (l'api normalizza i nomi dei file stats).
func NormUUID(u string) string { return normUUID(u) }
