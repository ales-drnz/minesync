package notify

import (
	"os"
	"testing"

	"minesync/server/internal/i18n"
)

// I test esistenti verificano i testi italiani: lingua dell'hub fissata.
func TestMain(m *testing.M) {
	i18n.SetDefault(i18n.IT)
	os.Exit(m.Run())
}
