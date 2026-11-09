package i18n

import (
	"errors"
	"testing"
)

func TestParse(t *testing.T) {
	for in, want := range map[string]Lang{
		"it": IT, "it_IT.UTF-8": IT, "it-IT": IT, "IT": IT,
		"en": EN, "en-US,en;q=0.9": EN, "en_GB.UTF-8": EN,
	} {
		if got, ok := Parse(in); !ok || got != want {
			t.Errorf("Parse(%q) = %q %v", in, got, ok)
		}
	}
	for _, in := range []string{"", "C", "POSIX", "de_DE.UTF-8", "C.UTF-8"} {
		if _, ok := Parse(in); ok {
			t.Errorf("Parse(%q) riconosciuto", in)
		}
	}
}

func TestFromAcceptLanguage(t *testing.T) {
	cases := map[string]Lang{
		"":                        IT,
		"de-DE,de;q=0.9":          IT,
		"de-DE,en;q=0.8,it;q=0.5": EN,
		"it-IT,it;q=0.9,en;q=0.8": IT,
		"en;q=0, it":              IT,
		"fr, en-GB;q=0.7":         EN,
	}
	for h, want := range cases {
		if got := FromAcceptLanguage(h, IT); got != want {
			t.Errorf("FromAcceptLanguage(%q) = %q, atteso %q", h, got, want)
		}
	}
}

func TestErrorfWrapAndLocalize(t *testing.T) {
	base := Errorf("non trovato")
	err := Errorf("generazione %d: %w", 4, base)
	if !errors.Is(err, base) {
		t.Fatal("errors.Is non attraversa Errorf")
	}
	if got := Localize(EN, err); got != "generation 4: not found" {
		t.Fatalf("EN: %q", got)
	}
	if got := Localize(IT, err); got != "generazione 4: non trovato" {
		t.Fatalf("IT: %q", got)
	}
	if got := Localize(EN, errors.New("plain")); got != "plain" {
		t.Fatalf("errore normale: %q", got)
	}
}

func TestDefaultFromEnv(t *testing.T) {
	t.Setenv("MINESYNC_LANG", "")
	t.Setenv("LC_ALL", "")
	t.Setenv("LC_MESSAGES", "")
	t.Setenv("LANG", "it_IT.UTF-8")
	if got := fromEnv(); got != IT {
		t.Fatalf("LANG=it: %q", got)
	}
	t.Setenv("MINESYNC_LANG", "en")
	if got := fromEnv(); got != EN {
		t.Fatalf("MINESYNC_LANG=en: %q", got)
	}
	t.Setenv("MINESYNC_LANG", "")
	t.Setenv("LANG", "C.UTF-8")
	if got := fromEnv(); got != EN {
		t.Fatalf("fallback: %q", got)
	}
}
