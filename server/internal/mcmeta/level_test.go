package mcmeta

import (
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"testing"
)

// --- costruttore NBT minimale, solo per i test ---

type nbtBuf struct{ b bytes.Buffer }

func (w *nbtBuf) name(t byte, name string) {
	w.b.WriteByte(t)
	binary.Write(&w.b, binary.BigEndian, uint16(len(name)))
	w.b.WriteString(name)
}
func (w *nbtBuf) str(name, v string) {
	w.name(8, name)
	binary.Write(&w.b, binary.BigEndian, uint16(len(v)))
	w.b.WriteString(v)
}
func (w *nbtBuf) int(name string, v int32) {
	w.name(3, name)
	binary.Write(&w.b, binary.BigEndian, v)
}
func (w *nbtBuf) long(name string, v int64) {
	w.name(4, name)
	binary.Write(&w.b, binary.BigEndian, v)
}
func (w *nbtBuf) byte_(name string, v int8) {
	w.name(1, name)
	w.b.WriteByte(byte(v))
}
func (w *nbtBuf) end() { w.b.WriteByte(0) }

func TestParseLevel(t *testing.T) {
	// costruisce root{ Data{ ... , Version{Name}, WorldGenSettings{seed} } }
	inner := &nbtBuf{}
	inner.str("LevelName", "MioMondo")
	inner.byte_("hardcore", 0)
	inner.byte_("Difficulty", 2)
	inner.int("GameType", 0)
	inner.long("Time", 24000*42) // 42 giorni di gioco
	inner.int("SpawnX", 100)
	inner.int("SpawnY", 64)
	inner.int("SpawnZ", -200)
	inner.int("DataVersion", 3465)
	// Version { Name="1.20.1" }
	inner.name(10, "Version")
	inner.str("Name", "1.20.1")
	inner.end()
	// WorldGenSettings { seed=123456789 }
	inner.name(10, "WorldGenSettings")
	inner.long("seed", 123456789)
	inner.end()
	inner.end() // fine Data

	root := &nbtBuf{}
	root.name(10, "") // root compound senza nome
	root.name(10, "Data")
	root.b.Write(inner.b.Bytes())
	root.end() // fine root

	// gzip, come il vero level.dat
	var gz bytes.Buffer
	zw := gzip.NewWriter(&gz)
	zw.Write(root.b.Bytes())
	zw.Close()

	li, err := ParseLevel(&gz)
	if err != nil {
		t.Fatal(err)
	}
	if li.Name != "MioMondo" || li.Version != "1.20.1" || li.Seed != "123456789" {
		t.Fatalf("campi base sbagliati: %+v", li)
	}
	if li.Difficulty != 2 || li.Hardcore || li.DataVersion != 3465 {
		t.Fatalf("difficoltà/hardcore/dataversion: %+v", li)
	}
	if li.Day != 42 || li.AgeTicks != 24000*42 {
		t.Fatalf("età mondo: %+v", li)
	}
	if len(li.Spawn) != 3 || li.Spawn[0] != 100 || li.Spawn[2] != -200 {
		t.Fatalf("spawn: %+v", li.Spawn)
	}
}
