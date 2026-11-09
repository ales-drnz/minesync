package syncx

import (
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"unicode/utf8"

	"minesync/client/internal/api"
	"minesync/client/internal/config"
	"minesync/client/internal/i18n"
)

// cacheEntry ricorda hash (e chunk, per i file grandi) di un file per
// evitare di ricalcolarli quando size+mtime non cambiano. Corrupt è l'esito
// della validazione region: stabile per (size,mtime), quindi si memorizza.
type cacheEntry struct {
	Size    int64       `json:"s"`
	Mtime   int64       `json:"m"` // ns unix
	Hash    string      `json:"h"`
	Chunks  []api.Chunk `json:"c,omitempty"`
	Corrupt string      `json:"bad,omitempty"` // "" = integro
	Exec    bool        `json:"x,omitempty"`   // bit di esecuzione noto (serve a Windows)
}

// Cache è la cache hash locale di uno spazio.
type Cache map[string]cacheEntry

// cacheFile è il formato su disco: oltre agli hash memorizza la cartella a cui
// si riferiscono e la generazione da cui il locale discende.
//
// La cartella serve perché la cache era valida per (dimensione, mtime): se si
// ricollega lo spazio a un'ALTRA cartella, o si ripristina un backup che
// conserva le date, gli hash vecchi vengono creduti buoni e il manifest
// finisce per dichiarare contenuti che sul disco non ci sono più.
//
// La generazione serve a sapere da dove si parte: senza, ogni push era un
// "vince l'ultimo" sull'intero albero e chi non aveva pullato cancellava la
// serata degli altri senza che nessuno se ne accorgesse.
type cacheFile struct {
	Root    string `json:"root"`
	Gen     int    `json:"gen"`
	Entries Cache  `json:"entries"`
}

// CacheMeta accompagna la cache: da dove viene e a che generazione è ferma.
type CacheMeta struct {
	Root string
	Gen  int
}

// LoadCache legge una cache da disco (vuota se assente o corrotta).
func LoadCache(path string) Cache {
	c, _ := LoadCacheMeta(path, "")
	return c
}

// LoadCacheMeta legge cache e metadati. Se root non è vuoto e non combacia con
// quello memorizzato, la cache viene buttata: è di un'altra cartella.
func LoadCacheMeta(path, root string) (Cache, CacheMeta) {
	b, err := os.ReadFile(path)
	if err != nil {
		return Cache{}, CacheMeta{}
	}
	var cf cacheFile
	if json.Unmarshal(b, &cf) == nil && cf.Entries != nil {
		if root != "" && cf.Root != "" && !sameDir(cf.Root, root) {
			return Cache{}, CacheMeta{} // cache di un'altra cartella: inservibile
		}
		return cf.Entries, CacheMeta{Root: cf.Root, Gen: cf.Gen}
	}
	// formato vecchio (mappa nuda): si accetta, senza metadati
	var c Cache
	if json.Unmarshal(b, &c) != nil || c == nil {
		return Cache{}, CacheMeta{}
	}
	return c, CacheMeta{}
}

func sameDir(a, b string) bool {
	ca, err1 := filepath.Abs(a)
	cb, err2 := filepath.Abs(b)
	if err1 != nil || err2 != nil {
		return a == b
	}
	if runtime.GOOS == "windows" || runtime.GOOS == "darwin" {
		return strings.EqualFold(filepath.Clean(ca), filepath.Clean(cb))
	}
	return filepath.Clean(ca) == filepath.Clean(cb)
}

// SaveCacheMeta scrive cache e metadati (in modo atomico e durevole: la
// generazione di base è ciò che protegge dai push distruttivi, non deve
// sparire con un blackout).
func SaveCacheMeta(path string, c Cache, meta CacheMeta) error {
	if c == nil {
		c = Cache{}
	}
	b, err := json.Marshal(cacheFile{Root: meta.Root, Gen: meta.Gen, Entries: c})
	if err != nil {
		return err
	}
	return config.WriteFileAtomic(path, b, 0o644)
}

// Scan percorre root e produce il manifest locale, riusando la cache.
// onFile (opzionale) è chiamato per ogni file esaminato.
func Scan(root string, m *Matcher, prior Cache, onFile func(rel string, hashed bool)) (api.Manifest, Cache, error) {
	man := api.Manifest{}
	next := Cache{}
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, rerr := filepath.Rel(root, p)
		if rerr != nil || rel == "." {
			return nil
		}
		rel = filepath.ToSlash(rel)
		if d.IsDir() {
			if m.MatchDir(rel) {
				return filepath.SkipDir
			}
			return nil
		}
		if m.Match(rel) || strings.HasSuffix(rel, partSuffix) {
			return nil // escluso, o temporaneo di un download interrotto
		}
		if !utf8.ValidString(rel) {
			return i18n.Errorf("il nome %q non è UTF-8 valido: rinominalo, "+
				"altrimenti verrebbe caricato storpiato e poi cancellato", rel)
		}
		if !validRel(rel) {
			// stessa regola che il pull applica al manifest dell'hub: un nome
			// con ':' o '\' (lecito su Linux) bloccherebbe il pull di tutti
			return i18n.Errorf("il nome %q contiene caratteri non ammessi (':' o '\\'): "+
				"rinominalo, su Windows non potrebbe esistere", rel)
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		// I collegamenti simbolici a FILE si seguono e si sincronizza il
		// contenuto: sono normalissimi (un JDK incluso nel pack ne ha un
		// centinaio, per deduplicare le licenze) e trattarli come un errore
		// bloccava l'intera sincronizzazione.
		//
		// Quelli a CARTELLA no: WalkDir non ci scende dentro, quindi tutto il
		// sottoalbero resterebbe invisibile alla scansione e il push
		// successivo lo cancellerebbe per tutti. Chi ha
		// "world -> /mnt/dati/world" deve saperlo subito, non scoprirlo dopo.
		if d.Type()&fs.ModeSymlink != 0 {
			target, terr := os.Stat(p)
			switch {
			case terr != nil:
				return nil // link rotto: non c'è contenuto da sincronizzare
			case target.IsDir():
				return i18n.Errorf("%s è un collegamento a una cartella: MineSync non può "+
					"sincronizzarne il contenuto, sostituiscilo con la cartella vera", rel)
			}
			info = target // dimensione, data e permessi sono quelli del file puntato
		} else if !d.Type().IsRegular() {
			return nil // fifo, socket, device: non sono contenuto
		}
		size, mtime := info.Size(), info.ModTime().UnixNano()
		var hash, corrupt string
		var chunks []api.Chunk
		hashed := false
		// cache valida solo se ha anche i chunk quando servirebbero
		// (le cache pre-1.7 non li avevano: quei file si ri-hashano una volta)
		if ce, ok := prior[rel]; ok && ce.Size == size && ce.Mtime == mtime &&
			(size < ChunkThreshold || len(ce.Chunks) > 0) && !mtimeUnreliable(rel) {
			hash, chunks, corrupt = ce.Hash, ce.Chunks, ce.Corrupt
		} else {
			hash, chunks, err = HashAndChunkFile(p, size)
			if err != nil {
				return err
			}
			if isRegionFile(rel) {
				corrupt = checkRegion(p) // validazione insieme all'hash, una volta
			}
			hashed = true
		}
		ex := isExec(rel, info)
		if runtime.GOOS == "windows" {
			// NTFS non ha il bit di esecuzione: dedurlo dall'estensione
			// perdeva l'eseguibilità di tutto ciò che non finisce in .sh
			// (i java dei runtime inclusi nei pack, per dirne una). Se il
			// file non è cambiato, si conserva quello che sapevamo già.
			if ce, ok := prior[rel]; ok && ce.Size == size && ce.Mtime == mtime {
				ex = ce.Exec
			}
		}
		next[rel] = cacheEntry{Size: size, Mtime: mtime, Hash: hash, Chunks: chunks, Corrupt: corrupt, Exec: ex}
		man[rel] = api.FileMeta{Hash: hash, Size: size, Exec: ex, Chunks: chunks}
		if onFile != nil {
			onFile(rel, hashed)
		}
		return nil
	})
	if err != nil {
		return nil, nil, err
	}
	return man, next, nil
}

// mtimeUnreliable dice se per questo file la coppia (dimensione, data) non è
// una prova affidabile che il contenuto non sia cambiato.
//
// Su Windows lo è per i region file, e la conseguenza è grave: finché il
// server tiene aperto il region file, la data di modifica non viene aggiornata
// (bug noto di Paper, #9142 — i dati sono su disco, è il metadato a restare
// indietro). Un backup incrementale basato su dimensione+data salta quindi in
// silenzio proprio le region appena modificate: l'autosave caricava sull'hub
// un mondo vecchio senza dire niente a nessuno. Costa una ri-lettura, ma un
// mondo sbagliato costa molto di più.
func mtimeUnreliable(rel string) bool {
	return runtime.GOOS == "windows" && isRegionFile(rel)
}

// isExec: su unix legge il bit; su Windows deduce dagli script .sh
// (così il bit sopravvive a un push fatto da Windows).
func isExec(rel string, info fs.FileInfo) bool {
	if runtime.GOOS != "windows" {
		return info.Mode()&0o111 != 0
	}
	return strings.HasSuffix(rel, ".sh")
}
