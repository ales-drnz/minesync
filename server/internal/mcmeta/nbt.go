// Package mcmeta legge i metadati di un mondo Minecraft dai file che l'hub
// conserva come blob: level.dat (NBT), server.properties, statistiche dei
// giocatori, ruoli e metadati delle mod. Nessuna dipendenza esterna.
package mcmeta

import (
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"errors"
	"io"
	"math"
)

// nbtMaxBytes: limite di sicurezza. level.dat è nell'ordine dei kB.
const nbtMaxBytes = 16 << 20

// Il formato NBT (Java, big-endian): un tag è [tipo:1][nome:UTF][payload].
// Qui serve solo leggerlo in un albero generico (mappe e slice) per estrarne
// i campi che ci interessano — non lo riscriviamo mai.
type nbtReader struct {
	b     []byte
	pos   int
	nodes int // tag decodificati finora (tetto nbtMaxNodes)
}

// nbtMaxNodes: tetto ai tag di un file. Un level.dat vero ne ha qualche
// migliaio (decine di migliaia con i registri delle mod); il limite evita
// che un file ostile allochi gigabyte di any.
const nbtMaxNodes = 1 << 18

func (r *nbtReader) read(n int) ([]byte, error) {
	if n < 0 || r.pos+n > len(r.b) {
		return nil, io.ErrUnexpectedEOF
	}
	v := r.b[r.pos : r.pos+n]
	r.pos += n
	return v, nil
}

func (r *nbtReader) u8() (byte, error) {
	b, err := r.read(1)
	if err != nil {
		return 0, err
	}
	return b[0], nil
}

func (r *nbtReader) u16() (int, error) {
	b, err := r.read(2)
	if err != nil {
		return 0, err
	}
	return int(binary.BigEndian.Uint16(b)), nil
}

func (r *nbtReader) str() (string, error) {
	n, err := r.u16()
	if err != nil {
		return "", err
	}
	b, err := r.read(n)
	return string(b), err
}

// payload decodifica il contenuto di un tag del tipo indicato.
func (r *nbtReader) payload(typ byte, depth int) (any, error) {
	if depth > 64 {
		return nil, errors.New("nbt troppo profondo")
	}
	if r.nodes++; r.nodes > nbtMaxNodes {
		return nil, errors.New("nbt con troppi nodi")
	}
	switch typ {
	case 1: // Byte
		b, err := r.u8()
		return int64(int8(b)), err
	case 2: // Short
		b, err := r.read(2)
		if err != nil {
			return nil, err
		}
		return int64(int16(binary.BigEndian.Uint16(b))), nil
	case 3: // Int
		b, err := r.read(4)
		if err != nil {
			return nil, err
		}
		return int64(int32(binary.BigEndian.Uint32(b))), nil
	case 4: // Long
		b, err := r.read(8)
		if err != nil {
			return nil, err
		}
		return int64(binary.BigEndian.Uint64(b)), nil
	case 5: // Float
		b, err := r.read(4)
		if err != nil {
			return nil, err
		}
		return float64(math.Float32frombits(binary.BigEndian.Uint32(b))), nil
	case 6: // Double
		b, err := r.read(8)
		if err != nil {
			return nil, err
		}
		return math.Float64frombits(binary.BigEndian.Uint64(b)), nil
	case 7: // Byte_Array — scartato (consumato)
		n, err := r.read(4)
		if err != nil {
			return nil, err
		}
		_, err = r.read(int(int32(binary.BigEndian.Uint32(n))))
		return nil, err
	case 8: // String
		return r.str()
	case 9: // List
		et, err := r.u8()
		if err != nil {
			return nil, err
		}
		nb, err := r.read(4)
		if err != nil {
			return nil, err
		}
		n := int(int32(binary.BigEndian.Uint32(nb)))
		// ogni elemento occupa almeno un byte (TAG_End non ha payload ma
		// non è ammesso in una lista non vuota): una lunghezza oltre i byte
		// rimasti è certamente falsa
		if n < 0 || n > len(r.b)-r.pos || (n > 0 && et == 0) {
			return nil, errors.New("lista NBT non valida")
		}
		out := make([]any, 0, minInt(n, 256))
		for i := 0; i < n; i++ {
			v, err := r.payload(et, depth+1)
			if err != nil {
				return nil, err
			}
			out = append(out, v)
		}
		return out, nil
	case 10: // Compound
		m := map[string]any{}
		for {
			t, err := r.u8()
			if err != nil {
				return nil, err
			}
			if t == 0 { // TAG_End
				break
			}
			name, err := r.str()
			if err != nil {
				return nil, err
			}
			v, err := r.payload(t, depth+1)
			if err != nil {
				return nil, err
			}
			m[name] = v
		}
		return m, nil
	case 11: // Int_Array — scartato
		nb, err := r.read(4)
		if err != nil {
			return nil, err
		}
		_, err = r.read(int(int32(binary.BigEndian.Uint32(nb))) * 4)
		return nil, err
	case 12: // Long_Array — scartato
		nb, err := r.read(4)
		if err != nil {
			return nil, err
		}
		_, err = r.read(int(int32(binary.BigEndian.Uint32(nb))) * 8)
		return nil, err
	default:
		return nil, errors.New("tag NBT sconosciuto")
	}
}

// parseNBT decodifica un file NBT (eventualmente gzip) nel suo albero generico.
func parseNBT(rd io.Reader) (map[string]any, error) {
	data, err := io.ReadAll(io.LimitReader(rd, nbtMaxBytes))
	if err != nil {
		return nil, err
	}
	if len(data) >= 2 && data[0] == 0x1f && data[1] == 0x8b { // magic gzip
		zr, err := gzip.NewReader(bytes.NewReader(data))
		if err != nil {
			return nil, err
		}
		data, err = io.ReadAll(io.LimitReader(zr, nbtMaxBytes))
		if err != nil {
			return nil, err
		}
	}
	r := &nbtReader{b: data}
	t, err := r.u8()
	if err != nil {
		return nil, err
	}
	if t != 10 {
		return nil, errors.New("root NBT non è un compound")
	}
	if _, err := r.str(); err != nil { // nome del root (di solito vuoto)
		return nil, err
	}
	v, err := r.payload(10, 0)
	if err != nil {
		return nil, err
	}
	m, _ := v.(map[string]any)
	return m, nil
}

// --- navigazione comoda dell'albero ---

func compound(m map[string]any, key string) map[string]any {
	c, _ := m[key].(map[string]any)
	return c
}
func nbtString(m map[string]any, key string) string {
	s, _ := m[key].(string)
	return s
}
func nbtInt(m map[string]any, key string) (int64, bool) {
	v, ok := m[key].(int64)
	return v, ok
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}
