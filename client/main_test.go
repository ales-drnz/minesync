package main

import (
	"context"
	"strings"
	"testing"

	"minesync/client/internal/i18n"
)

func TestCLIMessagesBothLanguages(t *testing.T) {
	defer i18n.Set(i18n.Current())

	i18n.Set(i18n.EN)
	if u := usage(); !strings.Contains(u, "Usage:") || !strings.Contains(u, "MINESYNC_LANG") || strings.Contains(u, "Uso:") {
		t.Errorf("usage in inglese:\n%s", u)
	}
	if err := cmdLink(context.Background(), []string{"solo-uno"}); err == nil || err.Error() != "usage: minesync link <space> <dir>" {
		t.Errorf("EN: %v", err)
	}

	i18n.Set(i18n.IT)
	if u := usage(); !strings.Contains(u, "Uso:") {
		t.Errorf("usage in italiano:\n%s", u)
	}
	if err := cmdLink(context.Background(), []string{"solo-uno"}); err == nil || err.Error() != "uso: minesync link <space> <dir>" {
		t.Errorf("IT: %v", err)
	}
}
