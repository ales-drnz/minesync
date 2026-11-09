package syncx

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"time"

	"minesync/client/internal/api"
	"minesync/client/internal/config"
	"minesync/client/internal/i18n"
)

// Protezione delle modifiche locali mai pushate (D1).
//
// Il pull è un checkout: allinea la cartella al manifest dell'hub. Se però il
// locale contiene lavoro che non è mai arrivato sull'hub (push finale fallito:
// hub giù, lock perso, base vecchia…), il checkout lo sovrascriverebbe in
// silenzio con la versione vecchia. Prima di toccare qualunque cosa si
// confronta quindi il locale con la generazione da cui discende (BaseGen,
// memorizzata nei metadati della cache): se differisce, il pull si rifiuta e
// restituisce DirtyLocalError.
//
//   - !Diverged() (l'hub è ancora fermo a BaseGen): le modifiche locali sono
//     un fast-forward, basta pusharle prima (la sessione lo fa da sola);
//   - Diverged(): nel frattempo qualcun altro ha pushato. Serve una scelta
//     esplicita: Engine.DiscardLocal scarta le modifiche locali, dopo averne
//     fatto una copia in BackupRoot.

// ErrDirtyLocal: la cartella locale ha modifiche non presenti sull'hub.
var ErrDirtyLocal = i18n.NewError("modifiche locali non pushate")

// DirtyLocalError descrive le modifiche locali che un pull distruggerebbe.
type DirtyLocalError struct {
	BaseGen int      // generazione a cui il locale era allineato (0 = ignota)
	HubHead int      // HEAD attuale dell'hub
	Changed []string // file modificati o aggiunti in locale dopo BaseGen
	Removed []string // file cancellati in locale dopo BaseGen
}

func (e *DirtyLocalError) Error() string {
	what := i18n.Sf("%d file modificati o aggiunti, %d cancellati", len(e.Changed), len(e.Removed))
	if !e.Diverged() {
		return i18n.Sf("la cartella locale ha modifiche mai caricate sull'hub (%s): "+
			"falle arrivare con un push prima di scaricare", what)
	}
	base := i18n.S("da una generazione sconosciuta")
	if e.BaseGen > 0 {
		base = i18n.Sf("dalla generazione #%d", e.BaseGen)
	}
	return i18n.Sf("la cartella locale ha modifiche mai caricate sull'hub (%s) e parte %s, "+
		"ma l'hub nel frattempo è alla #%d: un pull le sovrascriverebbe. "+
		"Scegli se scartarle (ne viene fatta una copia di backup)", what, base, e.HubHead)
}

// Diverged: l'hub è andato avanti rispetto alla base del locale, quindi le
// modifiche locali non si possono semplicemente pushare.
func (e *DirtyLocalError) Diverged() bool { return e.HubHead != e.BaseGen }

func (e *DirtyLocalError) Unwrap() error { return ErrDirtyLocal }

// BackupRoot è la cartella dei backup delle modifiche locali scartate:
// accanto alla cartella dello spazio, mai dentro (non deve essere
// sincronizzata).
func BackupRoot(localPath string) string {
	return filepath.Join(filepath.Dir(filepath.Clean(localPath)), ".minesync-backup")
}

// genPulling: valore di CacheMeta.Gen mentre un pull è in corso. Se il pull
// si interrompe, resta così: il locale è un misto di vecchio e nuovo, si può
// solo ripetere il pull, mai pushare (cancellerebbe sull'hub i file non
// ancora scaricati).
const genPulling = -1

// checkDirty confronta il locale con la sua generazione di base. Restituisce
// nil se il locale è pulito (o allineato all'hub, o reduce da un pull
// interrotto, che si può ripetere senza perdite).
func (e *Engine) checkDirty(ctx context.Context, local api.Manifest, remote api.ManifestResp) (*DirtyLocalError, error) {
	if sameContent(local, remote.Files, e.Matcher) {
		return nil, nil // già allineato all'hub, qualunque fosse la base
	}
	base := e.meta.Gen
	if base == genPulling {
		return nil, nil // pull interrotto: il locale era pulito quando è partito
	}
	var baseFiles api.Manifest
	known := true // base nota: anche i file spariti in locale sono modifiche
	switch {
	case base > 0 && base == remote.Gen:
		baseFiles = remote.Files
	case base > 0:
		m, err := e.remoteManifest(ctx, base)
		var ae *api.APIError
		switch {
		case err == nil:
			baseFiles = m.Files
		case errors.As(err, &ae) && ae.Status == 404:
			// generazione di base non più sull'hub (retention): base ignota,
			// si confronta con HEAD come per una cartella mai sincronizzata
		default:
			return nil, err
		}
	}
	if baseFiles == nil {
		if len(local) == 0 {
			return nil, nil // cartella vuota: niente da perdere
		}
		// Base ignota: si confronta con HEAD. Un file dell'hub assente in
		// locale qui non prova niente (quasi sempre non è mai stato
		// scaricato) e il pull lo ripristina senza perdite: contano solo i
		// file locali che l'hub non ha o ha diversi.
		baseFiles, known = remote.Files, false
	} else if sameContent(local, baseFiles, e.Matcher) {
		return nil, nil
	}
	d := &DirtyLocalError{BaseGen: base, HubHead: remote.Head}
	for rel, fm := range local {
		if b, ok := baseFiles[rel]; !ok || b.Hash != fm.Hash {
			d.Changed = append(d.Changed, rel)
		}
	}
	for rel := range baseFiles {
		if e.Matcher.Match(rel) {
			continue
		}
		if _, ok := local[rel]; !ok {
			d.Removed = append(d.Removed, rel)
		}
	}
	if len(d.Changed) == 0 && (len(d.Removed) == 0 || !known) {
		return nil, nil
	}
	sort.Strings(d.Changed)
	sort.Strings(d.Removed)
	return d, nil
}

// sameContent confronta solo il contenuto (hash), ignorando il bit di
// esecuzione (su Windows non è affidabile) e i file remoti ora esclusi.
func sameContent(local, other api.Manifest, m *Matcher) bool {
	n := 0
	for rel, o := range other {
		if m.Match(rel) {
			continue
		}
		n++
		if l, ok := local[rel]; !ok || l.Hash != o.Hash {
			return false
		}
	}
	return n == len(local)
}

// backupLocal copia i file locali elencati in una nuova cartella di backup
// (percorsi relativi conservati). Restituisce la cartella creata, "" se non
// c'era niente da copiare.
func (e *Engine) backupLocal(rels []string) (string, error) {
	if len(rels) == 0 {
		return "", nil
	}
	dir := filepath.Join(BackupRoot(e.LocalPath), e.SpaceID+"-"+time.Now().Format("20060102-150405"))
	for _, rel := range rels {
		src := filepath.Join(e.LocalPath, filepath.FromSlash(rel))
		dst := filepath.Join(dir, filepath.FromSlash(rel))
		if err := copyFile(src, dst); err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return dir, i18n.Errorf("backup di %s: %w", rel, err)
		}
	}
	return dir, nil
}

// copyFile copia src in dst (creando le cartelle), con fsync.
func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	st, err := in.Stat()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	tmp := dst + ".tmp"
	out, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, st.Mode().Perm())
	if err != nil {
		return err
	}
	_, err = io.Copy(out, in)
	if err == nil {
		err = out.Sync()
	}
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(tmp)
		return err
	}
	return config.ReplaceFile(tmp, dst)
}
