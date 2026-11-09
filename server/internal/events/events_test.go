package events

import (
	"path/filepath"
	"testing"

	"minesync/server/internal/i18n"
)

// Il log su disco tiene msg in italiano più key/args; riletto (numeri come
// float64 da JSON) si rende in qualsiasi lingua.
func TestEventRoundTripLocalized(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.jsonl")
	b := NewBus(path)
	b.Publish(Event{Type: "gc", Actor: "alex", Text: i18n.M("%s ha eliminato la versione #%d", "alex", 3)})
	b.Publish(Event{Type: "push", Msg: "vecchio evento senza key"})

	got := NewBus(path).Recent(0)
	if len(got) != 2 {
		t.Fatalf("eventi riletti: %d", len(got))
	}
	if got[0].Msg != "alex ha eliminato la versione #3" {
		t.Fatalf("msg salvato: %q", got[0].Msg)
	}
	if en := got[0].Localized(i18n.EN).Msg; en != "alex deleted version #3" {
		t.Fatalf("EN: %q", en)
	}
	if old := got[1].Localized(i18n.EN).Msg; old != "vecchio evento senza key" {
		t.Fatalf("evento vecchio: %q", old)
	}
}
