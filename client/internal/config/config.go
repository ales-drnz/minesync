// Package config: configurazione del client in ~/.minesync/config.json.
package config

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// DefaultServer è l'hub precompilato al primo avvio. Vuoto di default (nessun
// indirizzo cablato nel sorgente): chi distribuisce il client per la propria
// rete lo valorizza in fase di build con
// -ldflags "-X minesync/client/internal/config.DefaultServer=http://<ip-hub>:8084".
var DefaultServer = ""

// SpaceConfig lega uno spazio remoto a una cartella locale.
type SpaceConfig struct {
	LocalPath string `json:"localPath"`
	// JavaPath: eseguibile java scelto per questo server. "" = automatico
	// (MineSync sceglie il runtime compatibile col modpack).
	JavaPath string `json:"javaPath,omitempty"`
}

// Config è il file di configurazione del client. Nessuna credenziale:
// l'identità arriva dalla rete ZeroTier.
type Config struct {
	Server string                 `json:"server"` // es. http://<ip-hub>:8084
	Name   string                 `json:"name"`   // nome con cui l'hub ci riconosce
	Spaces map[string]SpaceConfig `json:"spaces"`
	// Lang: lingua dell'interfaccia ("it" | "en"); "" = automatica (sistema).
	// La variabile d'ambiente MINESYNC_LANG ha la precedenza.
	Lang string `json:"lang,omitempty"`
}

// Dir restituisce ~/.minesync (creandola).
func Dir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	d := filepath.Join(home, ".minesync")
	return d, os.MkdirAll(d, 0o755)
}

// CacheDir restituisce ~/.minesync/cache (creandola).
func CacheDir() (string, error) {
	d, err := Dir()
	if err != nil {
		return "", err
	}
	c := filepath.Join(d, "cache")
	return c, os.MkdirAll(c, 0o755)
}

func path() (string, error) {
	d, err := Dir()
	if err != nil {
		return "", err
	}
	return filepath.Join(d, "config.json"), nil
}

// Load carica la config (vuota se assente).
func Load() (*Config, error) {
	p, err := path()
	if err != nil {
		return nil, err
	}
	c := &Config{Spaces: map[string]SpaceConfig{}}
	b, err := os.ReadFile(p)
	if os.IsNotExist(err) {
		return c, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(b, c); err != nil {
		return nil, err
	}
	if c.Spaces == nil {
		c.Spaces = map[string]SpaceConfig{}
	}
	return c, nil
}

// Save scrive la config su disco.
func (c *Config) Save() error {
	p, err := path()
	if err != nil {
		return err
	}
	b, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	return WriteFileAtomic(p, b, 0o600)
}

// Ready riporta se la config basta per connettersi.
func (c *Config) Ready() bool { return c.Server != "" }
