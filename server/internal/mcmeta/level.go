package mcmeta

import (
	"io"
	"strconv"
)

// LevelInfo riassume i dati globali del mondo estratti da level.dat.
type LevelInfo struct {
	Name        string `json:"name,omitempty"`
	Version     string `json:"version,omitempty"` // versione Minecraft, es. "1.20.1"
	DataVersion int    `json:"dataVersion,omitempty"`
	Seed        string `json:"seed,omitempty"` // stringa: un int64 perderebbe precisione in JS
	Difficulty  int    `json:"difficulty"`     // 0 pacifica … 3 difficile; -1 se assente
	Hardcore    bool   `json:"hardcore"`
	GameType    int    `json:"gameType"`           // 0 sopravvivenza, 1 creativa, …
	AgeTicks    int64  `json:"ageTicks,omitempty"` // tempo totale di gioco del mondo
	Day         int64  `json:"day,omitempty"`      // giorno di gioco (età / 24000)
	Spawn       []int  `json:"spawn,omitempty"`    // [x, y, z]
}

// ParseLevel legge level.dat (NBT gzip) ed estrae i campi principali.
func ParseLevel(r io.Reader) (LevelInfo, error) {
	root, err := parseNBT(r)
	if err != nil {
		return LevelInfo{}, err
	}
	data := compound(root, "Data")
	if data == nil {
		data = root // alcune versioni molto vecchie non incapsulano in "Data"
	}
	li := LevelInfo{Difficulty: -1}
	li.Name = nbtString(data, "LevelName")
	if v := compound(data, "Version"); v != nil { // 1.9+: versione Minecraft leggibile
		li.Version = nbtString(v, "Name")
	}
	if dv, ok := nbtInt(data, "DataVersion"); ok {
		li.DataVersion = int(dv)
	}
	// seed: nuovo (WorldGenSettings.seed, 1.16+) o vecchio (RandomSeed)
	if wgs := compound(data, "WorldGenSettings"); wgs != nil {
		if s, ok := nbtInt(wgs, "seed"); ok {
			li.Seed = strconv.FormatInt(s, 10)
		}
	}
	if li.Seed == "" {
		if s, ok := nbtInt(data, "RandomSeed"); ok {
			li.Seed = strconv.FormatInt(s, 10)
		}
	}
	if d, ok := nbtInt(data, "Difficulty"); ok {
		li.Difficulty = int(d)
	}
	if h, ok := nbtInt(data, "hardcore"); ok {
		li.Hardcore = h != 0
	}
	if g, ok := nbtInt(data, "GameType"); ok {
		li.GameType = int(g)
	}
	if t, ok := nbtInt(data, "Time"); ok {
		li.AgeTicks = t
		li.Day = t / 24000 // ogni giorno Minecraft dura 24000 tick
	}
	sx, okx := nbtInt(data, "SpawnX")
	sy, oky := nbtInt(data, "SpawnY")
	sz, okz := nbtInt(data, "SpawnZ")
	if okx && oky && okz {
		li.Spawn = []int{int(sx), int(sy), int(sz)}
	}
	return li, nil
}
