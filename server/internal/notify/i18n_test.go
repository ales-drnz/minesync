package notify

import (
	"strings"
	"testing"

	"minesync/server/internal/i18n"
	"minesync/server/internal/store"
)

// Il bot parla la lingua dell'hub (MINESYNC_LANG/LANG).
func TestMessagesEnglish(t *testing.T) {
	st, _, tg, _ := setup(t)
	tg.lang = i18n.EN
	msg := tg.openMsg("miomondo", &store.LockInfo{Owner: "steve"})
	if !strings.Contains(msg, "<b>miomondo</b> is open") || !strings.Contains(msg, "hosted by <b>steve</b>") {
		t.Fatalf("openMsg EN: %q", msg)
	}
	st.CreateSpace("SkyFactory", "minecraft", nil)
	if msg := tg.statusMsg(); !strings.Contains(msg, "Server status") || !strings.Contains(msg, "SkyFactory</b> — closed") {
		t.Fatalf("statusMsg EN: %q", msg)
	}
}
