package syncx

import (
	"context"
	"path"
	"path/filepath"
	"strings"

	"minesync/client/internal/api"
	"minesync/client/internal/i18n"
)

// Validazione di tutto ciò che arriva dall'hub prima di usarlo sul disco.
//
// L'hub è fidato ma non infallibile (e su una rete L2 può essere
// impersonato): un manifest con "../../.bashrc" o "/etc/x" non deve poter
// scrivere fuori dalla cartella dello spazio, e un hash corto non deve far
// esplodere il client su Hash[:12].

// ErrBadManifest: il manifest dell'hub contiene percorsi o hash non validi.
var ErrBadManifest = i18n.NewError("manifest dell'hub non valido")

// validHash: SHA-256 esadecimale minuscolo, 64 caratteri.
func validHash(h string) bool {
	if len(h) != 64 {
		return false
	}
	for i := 0; i < len(h); i++ {
		c := h[i]
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// validRel: percorso relativo "pulito", con separatore "/", che resta dentro
// la cartella dello spazio su qualunque sistema operativo.
func validRel(rel string) bool {
	if rel == "" || strings.ContainsAny(rel, "\\:\x00") || strings.HasPrefix(rel, "/") {
		return false
	}
	if path.Clean(rel) != rel {
		return false // "a//b", "./a", "a/", "a/../b"
	}
	for _, seg := range strings.Split(rel, "/") {
		if seg == ".." || seg == "." {
			return false
		}
	}
	return filepath.IsLocal(filepath.FromSlash(rel))
}

// validateManifest controlla percorsi, hash e dimensioni di un manifest
// ricevuto dall'hub.
func validateManifest(m api.Manifest) error {
	for rel, fm := range m {
		if !validRel(rel) {
			return i18n.Errorf("%w: percorso %q non ammesso", ErrBadManifest, rel)
		}
		if !validHash(fm.Hash) {
			return i18n.Errorf("%w: hash non valido per %q", ErrBadManifest, rel)
		}
		if fm.Size < 0 {
			return i18n.Errorf("%w: dimensione negativa per %q", ErrBadManifest, rel)
		}
		var sum int64
		for _, c := range fm.Chunks {
			if !validHash(c.Hash) || c.Size < 0 {
				return i18n.Errorf("%w: chunk non valido in %q", ErrBadManifest, rel)
			}
			sum += c.Size
		}
		if len(fm.Chunks) > 0 && sum != fm.Size {
			return i18n.Errorf("%w: i chunk di %q non coprono il file", ErrBadManifest, rel)
		}
	}
	return nil
}

// remoteManifest scarica un manifest dall'hub e lo valida.
func (e *Engine) remoteManifest(ctx context.Context, gen int) (api.ManifestResp, error) {
	m, err := e.Client.Manifest(ctx, e.SpaceID, gen)
	if err != nil {
		return m, err
	}
	if m.Files == nil {
		m.Files = api.Manifest{}
	}
	return m, validateManifest(m.Files)
}
