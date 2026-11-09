package syncx

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"
)

// buildRegion costruisce un .mca minimale: header 8KiB + i chunk indicati.
// chunks: mappa indice-slot → (offsetSector, countSector, declaredLen).
func buildRegion(sectors int, chunks map[int][3]uint32) []byte {
	data := make([]byte, sectors*regionSector)
	for slot, c := range chunks {
		binary.BigEndian.PutUint32(data[slot*4:], c[0]<<8|c[1]) // offset|count
		if c[2] > 0 && int(c[0])*regionSector+4 <= len(data) {
			binary.BigEndian.PutUint32(data[int(c[0])*regionSector:], c[2]) // length
			data[int(c[0])*regionSector+4] = 2                              // zlib
		}
	}
	return data
}

func writeTmp(t *testing.T, b []byte) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "r.0.0.mca")
	if err := os.WriteFile(p, b, 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestCheckRegionAcceptsValid(t *testing.T) {
	// due chunk in sector 2 e 3, entrambi coerenti
	good := buildRegion(4, map[int][3]uint32{
		0: {2, 1, 100},
		1: {3, 1, 200},
	})
	if r := checkRegion(writeTmp(t, good)); r != "" {
		t.Fatalf("region valido segnalato come corrotto: %s", r)
	}
	// region vuoto (solo header) è valido
	if r := checkRegion(writeTmp(t, make([]byte, 2*regionSector))); r != "" {
		t.Fatalf("region vuoto segnalato: %s", r)
	}
	// Ultimo settore non riempito: è lo stato normale dei region file con
	// sync-chunk-writes=false, il padding lo scrive solo la modalità dsync.
	// I dati del chunk ci sono tutti, quindi il file è integro.
	unpadded := buildRegion(3, map[int][3]uint32{0: {2, 1, 100}})
	unpadded = unpadded[:2*regionSector+4+100]
	if r := checkRegion(writeTmp(t, unpadded)); r != "" {
		t.Fatalf("region non allineato (valido) segnalato come corrotto: %s", r)
	}
}

func TestCheckRegionDetectsCorruption(t *testing.T) {
	cases := []struct {
		name string
		data []byte
	}{
		// scrittura interrotta davvero: il chunk dichiara 900 byte ma il
		// file finisce prima
		{"troncato a metà chunk", func() []byte {
			b := buildRegion(3, map[int][3]uint32{0: {2, 1, 900}})
			return b[:2*regionSector+4+120]
		}()},
		{"offset oltre la fine", buildRegion(3, map[int][3]uint32{
			0: {9, 1, 100}, // sector 9 non esiste in un file da 3 sector
		})},
		{"chunk sovrapposti", buildRegion(4, map[int][3]uint32{
			0: {2, 2, 100},
			1: {3, 1, 100}, // sector 3 già occupato dal chunk precedente
		})},
		{"lunghezza incoerente", buildRegion(3, map[int][3]uint32{
			0: {2, 1, 999999}, // dichiara più byte dei sector allocati
		})},
	}
	for _, c := range cases {
		if r := checkRegion(writeTmp(t, c.data)); r == "" {
			t.Errorf("%s: corruzione non rilevata", c.name)
		}
	}
}

func TestIsRegionFile(t *testing.T) {
	for _, p := range []string{"world/region/r.0.0.mca", "world/entities/r.-1.0.MCA", "world/poi/r.0.0.mcr"} {
		if !isRegionFile(p) {
			t.Errorf("%q non riconosciuto come region", p)
		}
	}
	for _, p := range []string{"server.properties", "mods/create.jar", "world/level.dat"} {
		if isRegionFile(p) {
			t.Errorf("%q riconosciuto come region per errore", p)
		}
	}
}

// Spigot e Paper usano un conteggio di 255 settori come "vedi la lunghezza
// vera nel payload": il chunk ne occupa di più. Trattarlo alla lettera
// segnalava come corrotto ogni mondo scritto da Paper.
func TestCheckRegionTolleraIl255DiPaper(t *testing.T) {
	data := buildRegion(6, map[int][3]uint32{
		0: {2, 255, 100}, // chunk "grande" alla maniera di Paper
		1: {3, 1, 100},   // sta dentro i settori che il primo dichiarerebbe
	})
	if r := checkRegion(writeTmp(t, data)); r != "" {
		t.Fatalf("mondo Paper segnalato come corrotto: %s", r)
	}
}
