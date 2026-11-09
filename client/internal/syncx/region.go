package syncx

import (
	"encoding/binary"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"minesync/client/internal/i18n"
)

// Validazione dei region file Minecraft (formato Anvil). Un crash o una
// mancanza di corrente durante un salvataggio lascia il file scritto a metà;
// content-addressed, l'hub lo conserverebbe fedelmente e il prossimo che
// scarica erediterebbe il danno. La verifica intercetta la corruzione al
// push, prima che diventi la versione canonica.

const regionSector = 4096

// isRegionFile riconosce i file region (world/region, entities, poi) sia in
// formato Anvil (.mca) sia nel vecchio McRegion (.mcr).
func isRegionFile(rel string) bool {
	l := strings.ToLower(rel)
	return strings.HasSuffix(l, ".mca") || strings.HasSuffix(l, ".mcr")
}

// RegionProblem è un region file trovato danneggiato dalla verifica.
type RegionProblem struct {
	Path   string
	Reason string
}

// VerifyWorld valida TUTTI i region file sotto root (non solo quelli cambiati,
// come fa il push): il controllo integrità su richiesta. Rispetta le stesse
// esclusioni della sincronizzazione. Restituisce i problemi e quanti region
// sono stati esaminati.
func VerifyWorld(root string, m *Matcher) (problems []RegionProblem, checked int, err error) {
	err = filepath.WalkDir(root, func(p string, d fs.DirEntry, werr error) error {
		if werr != nil {
			return werr
		}
		rel, rerr := filepath.Rel(root, p)
		if rerr != nil || rel == "." {
			return nil
		}
		rel = filepath.ToSlash(rel)
		if d.IsDir() {
			if m != nil && m.MatchDir(rel) {
				return filepath.SkipDir
			}
			return nil
		}
		if !d.Type().IsRegular() || !isRegionFile(rel) || (m != nil && m.Match(rel)) {
			return nil
		}
		checked++
		if reason := checkRegion(p); reason != "" {
			problems = append(problems, RegionProblem{Path: rel, Reason: reason})
		}
		return nil
	})
	sort.Slice(problems, func(i, j int) bool { return problems[i].Path < problems[j].Path })
	return problems, checked, err
}

// checkRegion verifica la struttura di un region file senza decomprimere i
// chunk. Restituisce una descrizione del problema, o "" se il file è integro.
// I controlli coprono i danni tipici da salvataggio interrotto: file troncato,
// offset che puntano oltre la fine, chunk sovrapposti, lunghezze incoerenti.
func checkRegion(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return "" // errore di IO, non di contenuto: fuori dalla nostra competenza
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return ""
	}
	size := fi.Size()
	if size == 0 {
		return "" // region vuoto: nessun chunk, valido
	}
	// La dimensione NON deve per forza essere multipla di 4KiB: Minecraft
	// riempie l'ultimo settore solo con sync-chunk-writes=true (il padding
	// serve al dsync). Con la scrittura asincrona l'ultimo settore resta
	// corto e il file è comunque integro: contarlo come danno segnalava
	// come corrotto mezzo mondo a ogni salvataggio. Che i dati ci siano
	// tutti lo garantisce il controllo su ogni chunk, più sotto.
	sectors := (size + regionSector - 1) / regionSector
	if sectors < 2 {
		return i18n.S("header incompleto")
	}
	header := make([]byte, regionSector)
	if _, err := f.ReadAt(header, 0); err != nil {
		return i18n.S("header illeggibile")
	}
	used := make([]bool, sectors)
	used[0], used[1] = true, true // i primi due sector sono le tabelle di header
	lenBuf := make([]byte, 4)
	for i := 0; i < 1024; i++ {
		entry := binary.BigEndian.Uint32(header[i*4:])
		if entry == 0 {
			continue // chunk mai generato in questa posizione
		}
		offset := int64(entry >> 8)
		count := int64(entry & 0xff)
		if count == 0 {
			return i18n.S("voce di chunk malformata")
		}
		// Trappola di Spigot/Paper: un conteggio di ESATTAMENTE 255 significa
		// "almeno 255, la lunghezza vera sta nel payload", e il chunk può
		// occupare molti più settori di quanti ne dichiari. Verificarne la
		// sovrapposizione con i vicini darebbe falsi allarmi di corruzione su
		// ogni mondo scritto da Paper. Vanilla non ha questo meccanismo.
		if count == 255 {
			continue
		}
		if offset < 2 || offset+count > sectors {
			return i18n.S("chunk oltre la fine del file")
		}
		for s := offset; s < offset+count; s++ {
			if used[s] {
				return i18n.S("chunk sovrapposti (scrittura interrotta)")
			}
			used[s] = true
		}
		// la lunghezza dichiarata del chunk deve stare nei sector allocati
		if _, err := f.ReadAt(lenBuf, offset*regionSector); err != nil {
			return i18n.S("dati del chunk illeggibili")
		}
		clen := int64(binary.BigEndian.Uint32(lenBuf))
		if clen < 1 || clen+4 > count*regionSector {
			return i18n.S("lunghezza del chunk incoerente")
		}
		// i dati del chunk devono stare dentro il file: è questo, non
		// l'allineamento, a intercettare la scrittura interrotta a metà
		if offset*regionSector+4+clen > size {
			return i18n.S("dati del chunk oltre la fine del file (scrittura interrotta)")
		}
	}
	return ""
}
