package store

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"syscall"
)

// writeAtomic è L'UNICO punto in cui lo store scrive file: crea un temporaneo
// nella stessa directory, ci fa scrivere write, fa fsync del file, lo rinomina
// sulla destinazione e fa fsync della directory. Così un blackout lascia o il
// file vecchio o quello nuovo completo — mai uno a lunghezza zero.
// Se write restituisce errore la destinazione non viene toccata.
func writeAtomic(path string, write func(w io.Writer) error) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	done := false
	defer func() {
		if !done {
			tmp.Close()
			os.Remove(name)
		}
	}()
	if err := write(tmp); err != nil {
		return err
	}
	if err := tmp.Sync(); err != nil {
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := renameReplace(name, path); err != nil {
		return err
	}
	done = true
	return syncDir(dir)
}

// writeFileAtomic scrive data in path in modo atomico e durevole.
func writeFileAtomic(path string, data []byte) error {
	return writeAtomic(path, func(w io.Writer) error {
		_, err := w.Write(data)
		return err
	})
}

func writeJSON(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(path, b)
}

func readJSON(path string, v any) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, v)
}

// renameReplace rinomina src su dst. Solo su Windows, dove il rename su un
// file esistente può fallire, si rimuove la destinazione e si riprova: su
// Unix il rename è atomico e fallisce solo per errori veri (EIO, ENOSPC), e
// in quel caso cancellare la destinazione vorrebbe dire perderla.
func renameReplace(src, dst string) error {
	err := os.Rename(src, dst)
	if err != nil && runtime.GOOS == "windows" {
		os.Remove(dst)
		err = os.Rename(src, dst)
	}
	return err
}

// syncDir rende durevole il rename (la voce di directory). Su Windows non si
// può aprire una directory per fsync; alcuni filesystem di rete rispondono
// EINVAL: in entrambi i casi non c'è altro da fare.
func syncDir(dir string) error {
	if runtime.GOOS == "windows" {
		return nil
	}
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	if err := d.Sync(); err != nil && !errors.Is(err, syscall.EINVAL) {
		return err
	}
	return nil
}
