package mcmeta

import (
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"testing"
)

// seedLevel è un level.dat minimo valido (non compresso).
func seedLevel() []byte {
	w := &nbtBuf{}
	w.name(10, "")
	w.name(10, "Data")
	w.str("LevelName", "mondo")
	w.long("RandomSeed", 42)
	w.int("GameType", 0)
	// lista di 3 int
	w.name(9, "Lista")
	w.b.WriteByte(3)
	binary.Write(&w.b, binary.BigEndian, int32(3))
	for i := int32(0); i < 3; i++ {
		binary.Write(&w.b, binary.BigEndian, i)
	}
	w.end()
	w.end()
	return w.b.Bytes()
}

// FuzzParseNBT: nessun input deve far andare in panic il parser o fargli
// allocare memoria sproporzionata.
func FuzzParseNBT(f *testing.F) {
	lvl := seedLevel()
	f.Add(lvl)
	var gz bytes.Buffer
	zw := gzip.NewWriter(&gz)
	zw.Write(lvl)
	zw.Close()
	f.Add(gz.Bytes())
	f.Add([]byte{10, 0, 0, 0})
	// lista con lunghezza enorme e pochi byte
	f.Add([]byte{10, 0, 0, 9, 0, 1, 'l', 10, 0x7f, 0xff, 0xff, 0xff, 0})
	// lista di TAG_End non vuota
	f.Add([]byte{10, 0, 0, 9, 0, 1, 'l', 0, 0, 0, 0, 5, 0})
	// array con lunghezza negativa
	f.Add([]byte{10, 0, 0, 11, 0, 1, 'a', 0xff, 0xff, 0xff, 0xff, 0})
	f.Fuzz(func(t *testing.T, data []byte) {
		parseNBT(bytes.NewReader(data))
		ParseLevel(bytes.NewReader(data))
	})
}

// R18: una lista che dichiara più elementi dei byte rimasti è rifiutata
// subito, e il numero di nodi ha un tetto.
func TestNBTListBounds(t *testing.T) {
	if _, err := parseNBT(bytes.NewReader([]byte{10, 0, 0, 9, 0, 1, 'l', 10, 0x00, 0xff, 0xff, 0xff, 0})); err == nil {
		t.Fatal("lista con 16M elementi su pochi byte accettata")
	}
	// 300k byte singoli in una lista: oltre il tetto di nodi
	n := 300000
	w := &nbtBuf{}
	w.name(10, "")
	w.name(9, "l")
	w.b.WriteByte(1)
	binary.Write(&w.b, binary.BigEndian, int32(n))
	w.b.Write(make([]byte, n))
	w.end()
	if _, err := parseNBT(bytes.NewReader(w.b.Bytes())); err == nil {
		t.Fatal("tetto ai nodi non applicato")
	}
	if _, err := parseNBT(bytes.NewReader(seedLevel())); err != nil {
		t.Fatalf("level valido rifiutato: %v", err)
	}
}

// S9: la homepage delle mod accetta solo http/https.
func TestSafeURL(t *testing.T) {
	for in, want := range map[string]string{
		"https://example.com/mod":  "https://example.com/mod",
		"http://example.com":       "http://example.com",
		"javascript:alert(1)":      "",
		"JavaScript:alert(1)":      "",
		"data:text/html,x":         "",
		"//evil.example":           "",
		"ftp://example.com":        "",
		"  https://example.com/  ": "https://example.com/",
	} {
		if got := safeURL(in); got != want {
			t.Errorf("safeURL(%q) = %q, atteso %q", in, got, want)
		}
	}
	m := parseFabricJSON([]byte(`{"id":"x","contact":{"homepage":"javascript:alert(1)"}}`))
	if m.Homepage != "" {
		t.Fatalf("homepage pericolosa conservata: %q", m.Homepage)
	}
}
