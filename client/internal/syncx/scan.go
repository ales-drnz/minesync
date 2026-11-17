package syncx

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"
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
	// Racy: il file era stato modificato a ridosso della scansione (vedi
	// racyWindow): l'hash è giusto ma alla prossima scansione si ricalcola.
	Racy bool `json:"r,omitempty"`
}

// blobs elenca i blob che servono all'hub per questo file.
func (ce cacheEntry) blobs() []string {
	if len(ce.Chunks) == 0 {
		return []string{ce.Hash}
	}
	out := make([]string, len(ce.Chunks))
	for i, c := range ce.Chunks {
		out[i] = c.Hash
	}
	return out
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
	Root      string `json:"root"`
	Gen       int    `json:"gen"`
	GenDigest string `json:"genDigest,omitempty"`
	PrevGen   int    `json:"prevGen,omitempty"`
	UpBps     int64  `json:"upBps,omitempty"`
	Entries   Cache  `json:"entries"`
}

// CacheMeta accompagna la cache: da dove viene e a che generazione è ferma.
type CacheMeta struct {
	Root string
	Gen  int
	// GenDigest: digest della generazione Gen come l'ha data l'hub. Il
	// numero da solo non basta: dopo un ripristino del NAS o uno spazio
	// ricreato la "generazione 12" può essere un'altra. "" = ignoto (cache
	// di una versione precedente, o hub che non lo fornisce).
	GenDigest string
	// PrevGen: con Gen == genPulling, la generazione da cui il pull
	// interrotto era partito (0 = ignota).
	PrevGen int
	// UpBps: velocità di upload misurata sull'ultimo push a piena velocità
	// (byte/s, 0 = mai misurata). Serve al limite automatico dell'autosave.
	UpBps int64
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
		return cf.Entries, CacheMeta{Root: cf.Root, Gen: cf.Gen, GenDigest: cf.GenDigest,
			PrevGen: cf.PrevGen, UpBps: cf.UpBps}
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
	b, err := json.Marshal(cacheFile{Root: meta.Root, Gen: meta.Gen, GenDigest: meta.GenDigest,
		PrevGen: meta.PrevGen, UpBps: meta.UpBps, Entries: c})
	if err != nil {
		return err
	}
	return config.WriteFileAtomic(path, b, 0o644)
}

// racyWindow: un file modificato meno di così prima della scansione può
// cambiare ancora senza che (dimensione, data) se ne accorgano: su FAT/exFAT
// la data ha una granularità di 2 s, e una scrittura nello stesso "tick" della
// scansione lascerebbe in cache un hash vecchio creduto buono per sempre. Una
// voce così si memorizza ma si ri-hasha alla scansione successiva.
const racyWindow = 2 * time.Second

// stableTries: letture di un file che cambia mentre lo si legge, prima di
// arrendersi e lasciarlo fuori (con la versione dell'hub).
const stableTries = 4

// errUnstable: il file ha continuato a cambiare durante tutte le letture.
var errUnstable = i18n.NewError("il file cambia mentre lo leggo")

// ScanResult è l'esito di una scansione.
type ScanResult struct {
	Manifest api.Manifest
	Cache    Cache
	// Unreadable: file che esistono ma non si sono potuti leggere (bloccati
	// da un altro processo, antivirus, permessi) o che cambiavano di continuo.
	// Non sono nel manifest: chi pusha conserva la versione dell'hub. Le
	// cartelle illeggibili finiscono con "/".
	Unreadable []string
	// BadNames: file saltati perché il nome non può esistere su Windows
	// (verrebbero rifiutati dall'hub e bloccherebbero il pull di tutti).
	BadNames []string
	// CaseDups: file saltati perché differiscono da un altro solo per le
	// maiuscole (su Windows e macOS sarebbero lo stesso file).
	CaseDups []string
}

// scanOpts personalizza la scansione (lo snapshot dell'autosave).
type scanOpts struct {
	// trust: condizione in più perché una voce di cache valida venga creduta
	// senza rileggere il file (lo snapshot pretende anche che i suoi blob
	// siano sull'hub o nell'outbox).
	trust func(ce cacheEntry) bool
	// tee riceve ogni blob (file intero o chunk) letto durante l'hash: lo
	// snapshot copia nell'outbox quelli che l'hub non ha.
	tee func(hash string, data []byte) error
	// now: istante della scansione (zero = adesso), per la finestra "racy".
	now time.Time
}

// Scan percorre root e produce il manifest locale, riusando la cache.
// onFile (opzionale) è chiamato per ogni file esaminato. I file saltati
// (illeggibili, nomi non ammessi) non compaiono: per sapere quali sono usare
// ScanTree.
func Scan(root string, m *Matcher, prior Cache, onFile func(rel string, hashed bool)) (api.Manifest, Cache, error) {
	res, err := scanTree(root, m, prior, onFile, scanOpts{})
	return res.Manifest, res.Cache, err
}

// ScanTree è Scan con il dettaglio dei file saltati.
func ScanTree(root string, m *Matcher, prior Cache, onFile func(rel string, hashed bool)) (ScanResult, error) {
	return scanTree(root, m, prior, onFile, scanOpts{})
}

func scanTree(root string, m *Matcher, prior Cache, onFile func(rel string, hashed bool), opt scanOpts) (ScanResult, error) {
	res := ScanResult{Manifest: api.Manifest{}, Cache: Cache{}}
	now := opt.now
	if now.IsZero() {
		now = time.Now()
	}
	// un errore del tee (outbox piena, annullamento) ferma la scansione: non
	// va scambiato per un file illeggibile
	var teeErr error
	tee := opt.tee
	if tee != nil {
		tee = func(h string, data []byte) error {
			if err := opt.tee(h, data); err != nil {
				teeErr = err
				return err
			}
			return nil
		}
	}
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			if p != root && isUnreadable(err) {
				// cartella illeggibile: si salta, senza buttare via tutto
				if rel, rerr := filepath.Rel(root, p); rerr == nil {
					res.Unreadable = append(res.Unreadable, filepath.ToSlash(rel)+"/")
				}
				if d != nil && d.IsDir() {
					return filepath.SkipDir
				}
				return nil
			}
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
		if !validRel(rel) || WindowsInvalid(rel) != "" {
			// stessa regola dell'hub: un nome con ':' o '?', o un CON.txt
			// (leciti su Linux) bloccherebbe il pull di chi usa Windows.
			// Si salta con un avviso invece di fermare tutto.
			res.BadNames = append(res.BadNames, rel)
			return nil
		}
		info, err := d.Info()
		if err != nil {
			if os.IsNotExist(err) {
				return nil // sparito durante la scansione
			}
			if isUnreadable(err) {
				res.Unreadable = append(res.Unreadable, rel)
				return nil
			}
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
		if ce, ok := prior[rel]; ok && ce.Size == size && ce.Mtime == mtime && !ce.Racy &&
			(size < ChunkThreshold || len(ce.Chunks) > 0) && !mtimeUnreliable(rel) &&
			(opt.trust == nil || opt.trust(ce)) {
			hash, chunks, corrupt = ce.Hash, ce.Chunks, ce.Corrupt
		} else {
			var st fs.FileInfo
			hash, chunks, st, err = hashStable(p, info, tee)
			if teeErr != nil {
				return teeErr
			}
			if err != nil {
				if os.IsNotExist(err) {
					return nil // cancellato mentre lo leggevamo
				}
				if isUnreadable(err) || errors.Is(err, errUnstable) {
					res.Unreadable = append(res.Unreadable, rel)
					return nil
				}
				return err
			}
			size, mtime = st.Size(), st.ModTime().UnixNano()
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
		racy := now.Sub(time.Unix(0, mtime)) < racyWindow
		res.Cache[rel] = cacheEntry{Size: size, Mtime: mtime, Hash: hash, Chunks: chunks, Corrupt: corrupt, Exec: ex, Racy: racy}
		res.Manifest[rel] = api.FileMeta{Hash: hash, Size: size, Exec: ex, Chunks: chunks}
		if onFile != nil {
			onFile(rel, hashed)
		}
		return nil
	})
	if err != nil {
		return ScanResult{}, err
	}
	res.CaseDups = dropCaseDups(res.Manifest, res.Cache)
	return res, nil
}

// hashStable calcola hash e chunk di un file assicurandosi di non leggerne
// una versione "strappata": (dimensione, data) prima e dopo la lettura
// devono coincidere, altrimenti si rilegge (fino a stableTries volte).
// Restituisce lo stat corrispondente al contenuto letto.
func hashStable(p string, before fs.FileInfo, tee func(string, []byte) error) (string, []api.Chunk, fs.FileInfo, error) {
	for try := 0; try < stableTries; try++ {
		if try > 0 {
			time.Sleep(time.Duration(try) * 50 * time.Millisecond)
			st, err := os.Stat(p)
			if err != nil {
				return "", nil, nil, err
			}
			before = st
		}
		hash, chunks, err := hashChunkTee(p, before.Size(), tee)
		if err != nil {
			return "", nil, nil, err
		}
		after, err := os.Stat(p)
		if err != nil {
			return "", nil, nil, err
		}
		if after.Size() == before.Size() && after.ModTime().Equal(before.ModTime()) {
			return hash, chunks, after, nil
		}
	}
	return "", nil, nil, errUnstable
}

// isUnreadable: errori di lettura che riguardano il singolo file (bloccato
// da un altro processo su Windows, antivirus, permessi), non la scansione.
func isUnreadable(err error) bool {
	if err == nil || os.IsNotExist(err) {
		return false
	}
	if errors.Is(err, fs.ErrPermission) || isSharingViolation(err) {
		return true
	}
	var pe *fs.PathError
	return errors.As(err, &pe)
}

// dropCaseDups toglie dal manifest (e dalla cache) i percorsi che
// differiscono da un altro solo per maiuscole/minuscole: su Windows e macOS
// sono lo stesso file e il pull di chi li usa ne perderebbe uno. Si tiene il
// primo in ordine alfabetico. Restituisce quelli tolti.
func dropCaseDups(man api.Manifest, cache Cache) []string {
	rels := make([]string, 0, len(man))
	for rel := range man {
		rels = append(rels, rel)
	}
	sort.Strings(rels)
	seen := make(map[string]bool, len(rels))
	var dups []string
	for _, rel := range rels {
		k := strings.ToLower(rel)
		if seen[k] {
			dups = append(dups, rel)
			delete(man, rel)
			delete(cache, rel)
			continue
		}
		seen[k] = true
	}
	return dups
}

// reportScanIssues trasforma i file saltati in avvisi leggibili (uno per
// categoria, con il primo esempio).
func reportScanIssues(res ScanResult, warn func(string)) {
	if warn == nil {
		return
	}
	if n := len(res.Unreadable); n > 0 {
		warn(i18n.Sf("%d file non leggibili (bloccati da un altro programma o dall'antivirus?), es. %s: per questi resta la versione dell'hub.",
			n, res.Unreadable[0]))
	}
	if n := len(res.BadNames); n > 0 {
		warn(i18n.Sf("%d file saltati perché il nome non è ammesso su Windows (caratteri come : ? * \" < > |, nomi riservati come CON o NUL, punto o spazio finale), es. %s: rinominali.",
			n, res.BadNames[0]))
	}
	if n := len(res.CaseDups); n > 0 {
		warn(i18n.Sf("%d file saltati perché differiscono da un altro solo per le maiuscole, es. %s: su Windows e macOS sarebbero lo stesso file.",
			n, res.CaseDups[0]))
	}
}

// keepRemoteFor completa il manifest locale con la versione dell'hub dei
// file che la scansione non ha potuto leggere: senza, il push li
// cancellerebbe per tutti. Una cartella illeggibile ("dir/") tiene tutto il
// suo contenuto.
func keepRemoteFor(local, remote api.Manifest, unreadable []string) {
	if len(unreadable) == 0 {
		return
	}
	var dirs []string
	for _, u := range unreadable {
		if strings.HasSuffix(u, "/") {
			dirs = append(dirs, u)
			continue
		}
		if fm, ok := remote[u]; ok {
			local[u] = fm
		}
	}
	if len(dirs) == 0 {
		return
	}
	for rel, fm := range remote {
		for _, d := range dirs {
			if strings.HasPrefix(rel, d) {
				if _, ok := local[rel]; !ok {
					local[rel] = fm
				}
				break
			}
		}
	}
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
