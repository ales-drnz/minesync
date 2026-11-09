package tui

import (
	"fmt"
	"strings"
	"testing"
)

func TestConsoleBufferFilterAndSearch(t *testing.T) {
	var b consoleBuffer
	b.append("[INFO] avvio") // prima del dimensionamento: niente wrap
	if len(b.wrapped) != 0 {
		t.Fatal("senza larghezza non si deve wrappare")
	}
	b.setWidth(80)
	b.append("[WARN] lento")
	b.append("[ERROR] boom")
	b.append("Steve joined the game")
	if got := len(b.wrapped); got != 4 {
		t.Fatalf("tutte le righe visibili: %d", got)
	}

	b.cycleFilter() // avvisi+errori
	if c := b.content(); strings.Contains(c, "avvio") || !strings.Contains(c, "lento") || !strings.Contains(c, "boom") {
		t.Fatalf("filtro avvisi: %q", c)
	}
	b.cycleFilter() // solo errori
	if c := b.content(); strings.Contains(c, "lento") || !strings.Contains(c, "boom") {
		t.Fatalf("filtro errori: %q", c)
	}
	b.cycleFilter() // di nuovo tutto
	if b.filter != 0 {
		t.Fatalf("il filtro deve ciclare, è %d", b.filter)
	}

	if !b.setSearch("STEVE") {
		t.Fatal("setSearch deve riportare il cambio")
	}
	if b.setSearch("STEVE") {
		t.Fatal("stessa ricerca: nessun cambio")
	}
	if c := b.content(); !strings.Contains(c, "Steve") || strings.Contains(c, "boom") {
		t.Fatalf("ricerca case-insensitive: %q", c)
	}
	// una riga nuova che non passa la ricerca non compare
	b.append("[INFO] altro")
	if strings.Contains(b.content(), "altro") {
		t.Fatal("riga fuori ricerca visibile")
	}
	b.setSearch("")
	if !strings.Contains(b.content(), "altro") {
		t.Fatal("tolta la ricerca la riga deve tornare")
	}
}

func TestConsoleBufferWrapAndCaps(t *testing.T) {
	var b consoleBuffer
	b.setWidth(20)
	b.append(strings.Repeat("parola ", 10))
	if len(b.wrapped) < 3 {
		t.Fatalf("riga lunga non wrappata: %d segmenti", len(b.wrapped))
	}
	for i := 0; i < consoleMaxLines+500; i++ {
		b.append(fmt.Sprintf("riga %d", i))
	}
	if len(b.lines) != consoleMaxLines {
		t.Fatalf("righe grezze: %d, tetto %d", len(b.lines), consoleMaxLines)
	}
	if len(b.wrapped) > consoleMaxWrapped {
		t.Fatalf("righe wrappate oltre il tetto: %d", len(b.wrapped))
	}
	// il resize rifà il wrap mantenendo l'ultima riga
	b.setWidth(80)
	if !strings.Contains(b.content(), fmt.Sprintf("riga %d", consoleMaxLines+499)) {
		t.Fatal("ultima riga persa dopo il resize")
	}
}

func TestConsoleBufferTitle(t *testing.T) {
	var b consoleBuffer
	if b.title(false, true) != "console" {
		t.Fatalf("titolo base: %q", b.title(false, true))
	}
	b.filter = 2
	b.search = "x"
	got := b.title(false, false)
	for _, want := range []string{"solo errori", "cerca: “x”", "End per tornare live"} {
		if !strings.Contains(got, want) {
			t.Errorf("titolo %q: manca %q", got, want)
		}
	}
}

func TestClassifyLog(t *testing.T) {
	for line, lvl := range map[string]int{
		"[Server thread/ERROR] x":        2,
		"java.lang.NullPointerException": 2,
		"[Server thread/WARN] y":         1,
		"[Server thread/INFO] z":         0,
	} {
		if got := classifyLog(line).lvl; got != lvl {
			t.Errorf("classifyLog(%q) = %d, atteso %d", line, got, lvl)
		}
	}
}
