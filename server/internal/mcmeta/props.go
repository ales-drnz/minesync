package mcmeta

import (
	"bufio"
	"io"
	"strings"
)

// ServerInfo sono le impostazioni rilevanti da server.properties.
type ServerInfo struct {
	MOTD         string `json:"motd,omitempty"`
	Gamemode     string `json:"gamemode,omitempty"`
	Difficulty   string `json:"difficulty,omitempty"`
	MaxPlayers   string `json:"maxPlayers,omitempty"`
	ViewDistance string `json:"viewDistance,omitempty"`
	PvP          bool   `json:"pvp"`
	Hardcore     bool   `json:"hardcore"`
	Whitelist    bool   `json:"whitelist"`
	OnlineMode   bool   `json:"onlineMode"`
	Port         string `json:"port,omitempty"`
	LevelName    string `json:"levelName,omitempty"`
}

// ParseProperties legge un file .properties in una mappa chiave→valore.
func ParseProperties(r io.Reader) map[string]string {
	out := map[string]string{}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 1<<20)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, "!") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		out[strings.TrimSpace(k)] = strings.TrimSpace(v)
	}
	return out
}

// ParseServer estrae le impostazioni tipiche di server.properties.
func ParseServer(r io.Reader) ServerInfo {
	p := ParseProperties(r)
	return ServerInfo{
		MOTD:         p["motd"],
		Gamemode:     p["gamemode"],
		Difficulty:   p["difficulty"],
		MaxPlayers:   p["max-players"],
		ViewDistance: p["view-distance"],
		PvP:          p["pvp"] != "false", // default true
		Hardcore:     p["hardcore"] == "true",
		Whitelist:    p["white-list"] == "true",
		OnlineMode:   p["online-mode"] != "false", // default true
		Port:         p["server-port"],
		LevelName:    p["level-name"],
	}
}
