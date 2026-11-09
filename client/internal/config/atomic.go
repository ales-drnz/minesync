package config

import (
	"os"
	"path/filepath"
	"runtime"
)

// Scrittura atomica e durevole, unica per tutto il client (config, cache di
// scansione, file scaricati, blob pre-scaricati).
//
// Lo schema è quello classico: si scrive un file temporaneo nella stessa
// cartella, lo si porta su disco (fsync), lo si rinomina sopra la
// destinazione e infine si fa fsync della cartella, perché il rename stesso
// sopravviva a un blackout. Senza i due fsync, dopo una mancanza di corrente
// si può ritrovare il file a lunghezza zero: proprio quello che si voleva
// evitare con il temporaneo.
//
// La destinazione NON si cancella mai prima del rename: su POSIX il rename
// la sostituisce atomicamente, e cancellarla prima apriva una finestra in cui
// il file non esisteva affatto (un crash lì = config.json o file del mondo
// persi). Solo su Windows, dove il rename può fallire se la destinazione è
// occupata, si ritenta togliendola di mezzo.

// WriteFileAtomic scrive data in path in modo atomico (tmp + fsync + rename +
// fsync della cartella).
func WriteFileAtomic(path string, data []byte, perm os.FileMode) error {
	tmp := path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, perm)
	if err != nil {
		return err
	}
	_, err = f.Write(data)
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(tmp)
		return err
	}
	return ReplaceFile(tmp, path)
}

// ReplaceFile rinomina tmp (già scritto e sincronizzato dal chiamante) sopra
// dst e sincronizza la cartella. Se fallisce, tmp viene rimosso.
func ReplaceFile(tmp, dst string) error {
	err := os.Rename(tmp, dst)
	if err != nil && runtime.GOOS == "windows" {
		// Windows: la destinazione può essere bloccata (antivirus,
		// indicizzatore) o di sola lettura. Solo qui, e solo dopo un primo
		// fallimento, la si toglie di mezzo e si ritenta.
		if rerr := os.Remove(dst); rerr == nil || os.IsNotExist(rerr) {
			err = os.Rename(tmp, dst)
		}
	}
	if err != nil {
		os.Remove(tmp)
		return err
	}
	return SyncDir(filepath.Dir(dst))
}

// SyncDir porta su disco le voci di una cartella (rename, creazioni). Su
// Windows le cartelle non si possono aprire per l'fsync: no-op.
func SyncDir(dir string) error {
	if runtime.GOOS == "windows" {
		return nil
	}
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	err = d.Sync()
	if cerr := d.Close(); err == nil {
		err = cerr
	}
	return err
}
