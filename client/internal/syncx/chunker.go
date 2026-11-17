// Chunking content-defined (FastCDC) per il delta sync dei file grandi.
//
// I region file di Minecraft (.mca, spesso 4–30 MB) cambiano di pochi kB a
// ogni autosave ma prima viaggiavano interi. Spezzandoli in chunk con confini
// decisi dal CONTENUTO (rolling hash gear), un cambiamento locale invalida
// solo i chunk che tocca: l'hub ha già gli altri e chiede solo quelli nuovi.
//
// ATTENZIONE: l'algoritmo deve restare IDENTICO tra versioni del client
// (stessa gear table, stesse soglie), o file uguali producono chunk diversi
// e il dedup sparisce. Non toccare seed e parametri senza una migrazione.
package syncx

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"hash"
	"io"
	"os"

	"minesync/client/internal/api"
)

const (
	// ChunkThreshold: sotto questa taglia un file resta un blob unico
	// (l'overhead per-chunk non ripaga).
	ChunkThreshold = 2 << 20

	chunkMin = 256 << 10 // mai tagliare prima
	chunkAvg = 512 << 10 // taglio medio atteso (2^19)
	chunkMax = 2 << 20   // taglio forzato

	chunkAvgBits = 19
)

// Maschere FastCDC con "normalized chunking": prima del punto medio si taglia
// con una maschera più esigente (bits+2), dopo con una più permissiva
// (bits-2) — la distribuzione delle taglie si stringe attorno alla media.
// I bit stanno in cima alla parola: il gear hash shifta a sinistra, quindi
// solo i bit alti vedono la finestra completa (~64 byte) di contenuto.
const (
	maskS = ((1 << (chunkAvgBits + 2)) - 1) << (64 - (chunkAvgBits + 2))
	maskL = ((1 << (chunkAvgBits - 2)) - 1) << (64 - (chunkAvgBits - 2))
)

// gearTable: 256 valori pseudo-casuali DETERMINISTICI (splitmix64 con seed
// fisso). Generata una volta a runtime, identica ovunque e per sempre.
var gearTable = func() [256]uint64 {
	var t [256]uint64
	x := uint64(0x3ee2_58f2_a7b9_c11d) // seed storico di MineSync: non cambiare
	for i := range t {
		x += 0x9e37_79b9_7f4a_7c15
		z := x
		z = (z ^ (z >> 30)) * 0xbf58_476d_1ce4_e5b9
		z = (z ^ (z >> 27)) * 0x94d0_49bb_1331_11eb
		t[i] = z ^ (z >> 31)
	}
	return t
}()

// chunkWriter spezza uno stream in chunk FastCDC calcolando al volo lo
// SHA-256 di ogni chunk (e chi lo usa può affiancare quello dell'intero).
type chunkWriter struct {
	chunks []api.Chunk
	h      hash.Hash // hash del chunk corrente
	n      int64     // byte nel chunk corrente
	gear   uint64
}

func newChunkWriter() *chunkWriter {
	return &chunkWriter{h: sha256.New()}
}

func (c *chunkWriter) Write(p []byte) (int, error) {
	start := 0
	for i, b := range p {
		c.gear = c.gear<<1 + gearTable[b]
		c.n++
		if c.n < chunkMin {
			continue
		}
		mask := uint64(maskS)
		if c.n > chunkAvg {
			mask = maskL
		}
		if c.gear&mask == 0 || c.n >= chunkMax {
			c.h.Write(p[start : i+1])
			c.cut()
			start = i + 1
		}
	}
	c.h.Write(p[start:])
	return len(p), nil
}

func (c *chunkWriter) cut() {
	c.chunks = append(c.chunks, api.Chunk{
		Hash: hex.EncodeToString(c.h.Sum(nil)), Size: c.n,
	})
	c.h.Reset()
	c.n = 0
	c.gear = 0
}

// Close chiude l'ultimo chunk parziale (se c'è).
func (c *chunkWriter) Close() []api.Chunk {
	if c.n > 0 {
		c.cut()
	}
	return c.chunks
}

// HashAndChunkFile calcola in UNA passata lo SHA-256 dell'intero file e,
// se il file supera la soglia, la sua lista di chunk.
func HashAndChunkFile(path string, size int64) (whole string, chunks []api.Chunk, err error) {
	f, err := os.Open(path)
	if err != nil {
		return "", nil, err
	}
	defer f.Close()
	wholeH := sha256.New()
	if size < ChunkThreshold {
		if _, err := io.CopyBuffer(wholeH, f, make([]byte, 1<<20)); err != nil {
			return "", nil, err
		}
		return hex.EncodeToString(wholeH.Sum(nil)), nil, nil
	}
	cw := newChunkWriter()
	r := bufio.NewReaderSize(f, 1<<20)
	buf := make([]byte, 1<<20)
	for {
		n, rerr := r.Read(buf)
		if n > 0 {
			wholeH.Write(buf[:n])
			cw.Write(buf[:n])
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return "", nil, rerr
		}
	}
	return hex.EncodeToString(wholeH.Sum(nil)), cw.Close(), nil
}

// teeChunkWriter è un chunkWriter che tiene anche i byte del chunk corrente
// e li consegna, insieme al suo hash, a onCut. Stesso algoritmo e stessi
// confini di chunkWriter (lo verifica un test).
type teeChunkWriter struct {
	*chunkWriter
	buf   []byte
	onCut func(hash string, data []byte) error
	err   error
}

func (t *teeChunkWriter) Write(p []byte) (int, error) {
	if t.err != nil {
		return 0, t.err
	}
	start := 0
	for i, b := range p {
		t.gear = t.gear<<1 + gearTable[b]
		t.n++
		if t.n < chunkMin {
			continue
		}
		mask := uint64(maskS)
		if t.n > chunkAvg {
			mask = maskL
		}
		if t.gear&mask == 0 || t.n >= chunkMax {
			t.h.Write(p[start : i+1])
			t.buf = append(t.buf, p[start:i+1]...)
			t.cut()
			t.emit()
			start = i + 1
		}
	}
	t.h.Write(p[start:])
	t.buf = append(t.buf, p[start:]...)
	return len(p), t.err
}

// emit consegna l'ultimo chunk tagliato.
func (t *teeChunkWriter) emit() {
	if t.err == nil {
		t.err = t.onCut(t.chunks[len(t.chunks)-1].Hash, t.buf)
	}
	t.buf = t.buf[:0]
}

// Close chiude l'ultimo chunk parziale e lo consegna.
func (t *teeChunkWriter) Close() ([]api.Chunk, error) {
	if t.n > 0 {
		t.cut()
		t.emit()
	}
	return t.chunks, t.err
}

// hashChunkTee è HashAndChunkFile che, se tee non è nil, consegna a tee ogni
// blob letto (il file intero se piccolo, altrimenti ogni chunk). Così lo
// snapshot legge ogni file UNA volta sola: hash, chunk e copia nell'outbox.
func hashChunkTee(path string, size int64, tee func(hash string, data []byte) error) (string, []api.Chunk, error) {
	if tee == nil {
		return HashAndChunkFile(path, size)
	}
	f, err := os.Open(path)
	if err != nil {
		return "", nil, err
	}
	defer f.Close()
	if size < ChunkThreshold {
		data, err := io.ReadAll(io.LimitReader(f, ChunkThreshold))
		if err != nil {
			return "", nil, err
		}
		h := hashBytes(data)
		if int64(len(data)) != size {
			// cambiato tra lo stat e la lettura: hashStable lo vede dallo
			// stat successivo e rilegge, inutile copiarlo
			return h, nil, nil
		}
		return h, nil, tee(h, data)
	}
	wholeH := sha256.New()
	tw := &teeChunkWriter{chunkWriter: newChunkWriter(), onCut: tee}
	buf := make([]byte, 1<<20)
	for {
		n, rerr := f.Read(buf)
		if n > 0 {
			wholeH.Write(buf[:n])
			if _, err := tw.Write(buf[:n]); err != nil {
				return "", nil, err
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return "", nil, rerr
		}
	}
	chunks, err := tw.Close()
	if err != nil {
		return "", nil, err
	}
	return hex.EncodeToString(wholeH.Sum(nil)), chunks, nil
}

func hashBytes(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}
