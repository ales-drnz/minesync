package selfupdate

import (
	"os"
	"testing"

	"minesync/client/internal/i18n"
)

// I test controllano i messaggi d'errore italiani.
func TestMain(m *testing.M) {
	i18n.Set(i18n.IT)
	os.Exit(m.Run())
}
