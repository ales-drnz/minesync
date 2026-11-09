package tui

import (
	"strings"
	"testing"

	"github.com/muesli/reflow/wrap"
)

func TestWrapLongAnsiLine(t *testing.T) {
	raw := "\x1b[38;2;219;228;238m[11:22:51] [Server thread/INFO] [minecraft/MinecraftServer]: Saving chunks for level 'ServerLevel[world]'/minecraft:overworld\x1b[0m"
	out := wrap.String(raw, 88)
	segs := strings.Split(out, "\n")
	t.Logf("segmenti: %d", len(segs))
	for i, s := range segs {
		t.Logf("  [%d] %q", i, s)
	}
	joined := strings.Join(segs, "")
	if !strings.Contains(joined, "overworld") {
		t.Fatal("contenuto perso nel wrap!")
	}
}
