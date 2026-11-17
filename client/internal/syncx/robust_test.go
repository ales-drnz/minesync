package syncx

import (
	"bytes"
	"context"
	"errors"
	"io/fs"
	"math/rand"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"minesync/client/internal/api"
	"minesync/client/internal/syncx/fakehub"
)

// età: porta i file indietro nel tempo (fuori dalla finestra racy).
func invecchia(t *testing.T, root string) {
	t.Helper()
	old := time.Now().Add(-time.Hour)
	filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			os.Chtimes(p, old, old)
		}
		return nil
	})
}

func randBytes(n int, seed int64) []byte {
	b := make([]byte, n)
	rand.New(rand.NewSource(seed)).Read(b)
	return b
}

// C5: nomi non ammessi su Windows, su qualunque sistema.
func TestWindowsInvalid(t *testing.T) {
	bad := []string{"a?b", "x/CON", "con.txt", "Com1.dat", "LPT9", "nul.tar.gz", "fine.", "spazio ", "a<b", "a>b",
		"a\"b", "a|b", "a*b", "dir/ctl\x01", "aux/ok.txt"}
	good := []string{"ok.txt", "world/region/r.0.0.mca", "console.log", "COM10", "LPT0.txt", "con-fig.toml", ".minesync", "a.b.c"}
	for _, p := range bad {
		if WindowsInvalid(p) == "" {
			t.Errorf("%q accettato", p)
		}
	}
	for _, p := range good {
		if s := WindowsInvalid(p); s != "" {
			t.Errorf("%q rifiutato (%q)", p, s)
		}
	}
}

// C5: la scansione salta (con avviso) nomi non ammessi e doppioni di
// maiuscole, senza fermarsi.
func TestScanSaltaNomiNonAmmessiEDoppioni(t *testing.T) {
	if runtime.GOOS == "windows" || runtime.GOOS == "darwin" {
		t.Skip("servono nomi che questo filesystem non ammette")
	}
	dir := t.TempDir()
	for _, f := range []string{"ok.txt", "a?b.txt", "CON.txt", "Foo.txt", "foo.txt", "World/x.dat", "world/x.dat"} {
		p := filepath.Join(dir, filepath.FromSlash(f))
		os.MkdirAll(filepath.Dir(p), 0o755)
		os.WriteFile(p, []byte(f), 0o644)
	}
	res, err := ScanTree(dir, NewMatcher(nil), Cache{}, nil)
	if err != nil {
		t.Fatalf("la scansione si è fermata: %v", err)
	}
	want := []string{"Foo.txt", "World/x.dat", "ok.txt"}
	if len(res.Manifest) != len(want) {
		t.Fatalf("manifest = %v, atteso %v", keys(res.Manifest), want)
	}
	for _, w := range want {
		if _, ok := res.Manifest[w]; !ok {
			t.Errorf("manca %s", w)
		}
	}
	if len(res.BadNames) != 2 || len(res.CaseDups) != 2 {
		t.Errorf("bad=%v dups=%v", res.BadNames, res.CaseDups)
	}
	var warns []string
	reportScanIssues(res, func(s string) { warns = append(warns, s) })
	if len(warns) != 2 {
		t.Errorf("avvisi: %v", warns)
	}
}

func keys(m api.Manifest) []string {
	var out []string
	for k := range m {
		out = append(out, k)
	}
	return out
}

// D: un file modificato a ridosso della scansione (FAT/exFAT: 2 s di
// granularità) non si crede dalla cache la volta dopo.
func TestCacheRacyRiHashata(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "level.dat")
	os.WriteFile(p, []byte("uno"), 0o644)
	_, cache, err := Scan(dir, NewMatcher(nil), Cache{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !cache["level.dat"].Racy {
		t.Fatal("voce appena scritta non marcata racy")
	}
	hashed := 0
	count := func(_ string, h bool) {
		if h {
			hashed++
		}
	}
	// stesso contenuto ma "riscritto nello stesso tick": deve rileggerlo
	if _, cache, err = Scan(dir, NewMatcher(nil), cache, count); err != nil || hashed != 1 {
		t.Fatalf("voce racy creduta dalla cache (ri-hash: %d, err %v)", hashed, err)
	}
	invecchia(t, dir)
	_, cache, _ = Scan(dir, NewMatcher(nil), cache, nil)
	hashed = 0
	Scan(dir, NewMatcher(nil), cache, count)
	if hashed != 0 {
		t.Errorf("file vecchio ri-hashato %d volte", hashed)
	}
}

// Snapshot: un file che cambia mentre lo si legge viene riletto, mai
// fotografato a metà.
func TestHashStableRilegge(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "cobble.json")
	os.WriteFile(p, []byte("versione uno"), 0o644)
	old := time.Now().Add(-time.Minute)
	os.Chtimes(p, old, old)
	info, _ := os.Stat(p)
	calls := 0
	tee := func(h string, data []byte) error {
		calls++
		if calls == 1 {
			// un mod scrive proprio adesso
			os.WriteFile(p, []byte("versione due, più lunga"), 0o644)
		}
		return nil
	}
	hash, _, st, err := hashStable(p, info, tee)
	if err != nil {
		t.Fatal(err)
	}
	if want := hashBytes([]byte("versione due, più lunga")); hash != want || st.Size() != int64(len("versione due, più lunga")) {
		t.Errorf("hash del contenuto strappato o vecchio (%d letture)", calls)
	}
	if calls < 2 {
		t.Error("il file cambiato non è stato riletto")
	}
}

// Un file illeggibile non ferma la scansione e il push conserva la versione
// dell'hub (prima: push abortito).
func TestFileIlleggibileTieneLaVersioneHub(t *testing.T) {
	if runtime.GOOS == "windows" || os.Getuid() == 0 {
		t.Skip("permessi non applicabili")
	}
	hub := fakehub.New()
	defer hub.Close()
	hub.Commit(map[string][]byte{"bloccato.dat": []byte("hub"), "a.txt": []byte("a")})
	eng := newTestEngine(t, hub)
	ctx := context.Background()
	if _, err := eng.Pull(ctx); err != nil {
		t.Fatal(err)
	}
	var warns []string
	eng.Warn = func(s string) { warns = append(warns, s) }
	writeLocal(t, eng, "a.txt", "nuovo")
	writeLocal(t, eng, "bloccato.dat", "locale")
	p := filepath.Join(eng.LocalPath, "bloccato.dat")
	os.Chmod(p, 0)
	defer os.Chmod(p, 0o644)
	res, err := eng.Push(ctx, "x", false)
	if err != nil {
		t.Fatalf("push abortito da un file illeggibile: %v", err)
	}
	got := hub.Files(res.Gen.N)
	if string(got["a.txt"]) != "nuovo" || string(got["bloccato.dat"]) != "hub" {
		t.Errorf("generazione: %q", got)
	}
	if len(warns) == 0 || !strings.Contains(warns[0], "bloccato.dat") {
		t.Errorf("nessun avviso sul file illeggibile: %v", warns)
	}
}

// E: chmod rifiutato dal filesystem (EPERM) → ignorato con un solo avviso.
func TestChmodNonSupportatoIgnorato(t *testing.T) {
	if !chmodUnsupported(&fs.PathError{Op: "chmod", Path: "x", Err: syscall.EPERM}) {
		t.Error("EPERM non riconosciuto")
	}
	if runtime.GOOS == "windows" || os.Getuid() == 0 {
		t.Skip("serve un file di un altro utente")
	}
	st, err := os.Stat("/etc/passwd")
	if err != nil {
		t.Skip(err)
	}
	var warns int
	e := &Engine{Warn: func(string) { warns++ }}
	for i := 0; i < 3; i++ {
		if err := e.chmod("/etc/passwd", st.Mode().Perm()); err != nil {
			t.Fatalf("chmod: %v", err)
		}
	}
	if warns != 1 {
		t.Errorf("avvisi = %d, atteso 1", warns)
	}
}

// F: un pull interrotto non rende "pulita" la cartella: al pull ripetuto i
// file locali che non sono né la versione di partenza né quella dell'hub
// finiscono nel backup prima di essere sovrascritti.
func TestPullInterrottoSalvaLeModifiche(t *testing.T) {
	hub := fakehub.New()
	defer hub.Close()
	hub.Commit(map[string][]byte{"a.txt": []byte("a1"), "b.txt": []byte("b1"), "c.txt": []byte("c1")})
	eng := newTestEngine(t, hub)
	ctx := context.Background()
	if _, err := eng.Pull(ctx); err != nil {
		t.Fatal(err)
	}
	hub.Commit(map[string][]byte{"a.txt": []byte("a2"), "b.txt": []byte("b2"), "c.txt": []byte("c2")})
	hub.Lock()
	hub.FailBlobs[fakehub.Hash([]byte("b2"))] = true
	hub.Unlock()
	if _, err := eng.Pull(ctx); err == nil {
		t.Fatal("il pull doveva interrompersi")
	}
	writeLocal(t, eng, "b.txt", "lavoro mio") // modifica dopo l'interruzione
	hub.Lock()
	hub.FailBlobs = map[string]bool{}
	hub.Unlock()
	plan, err := eng.Pull(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if plan.Backup == "" {
		t.Fatal("nessun backup dopo il pull interrotto")
	}
	if b, err := os.ReadFile(filepath.Join(plan.Backup, "b.txt")); err != nil || string(b) != "lavoro mio" {
		t.Errorf("backup di b.txt = %q (%v)", b, err)
	}
	for _, f := range []string{"a.txt", "c.txt"} {
		if _, err := os.Stat(filepath.Join(plan.Backup, f)); err == nil {
			t.Errorf("%s (versione di partenza o dell'hub) non doveva finire nel backup", f)
		}
	}
	if readLocal(t, eng, "b.txt") != "b2" {
		t.Error("pull non completato")
	}
}

// C1: dopo il pull la base ha anche il digest; il push lo dichiara.
func TestDigestBaseDichiarato(t *testing.T) {
	hub := fakehub.New()
	defer hub.Close()
	hub.Commit(map[string][]byte{"a.txt": []byte("a")})
	eng := newTestEngine(t, hub)
	ctx := context.Background()
	if _, err := eng.Pull(ctx); err != nil {
		t.Fatal(err)
	}
	if _, meta := LoadCacheMeta(eng.CachePath, eng.LocalPath); meta.GenDigest != hub.Digest(1) {
		t.Fatalf("digest non salvato: %q", meta.GenDigest)
	}
	writeLocal(t, eng, "a.txt", "b")
	res, err := eng.Push(ctx, "x", false)
	if err != nil {
		t.Fatal(err)
	}
	hub.Lock()
	pd := hub.LastParentDigest
	hub.Unlock()
	if pd != hub.Digest(1) {
		t.Errorf("parentDigest = %q", pd)
	}
	if _, meta := LoadCacheMeta(eng.CachePath, eng.LocalPath); meta.Gen != res.Gen.N || meta.GenDigest != hub.Digest(res.Gen.N) {
		t.Errorf("meta dopo il push: %+v", meta)
	}
}

// C1: NAS ripristinato, la "generazione 1" è un'altra. Stesso numero non
// basta: niente fast-forward, push rifiutato come base vecchia.
func TestDigestDiversoBaseIgnota(t *testing.T) {
	hub := fakehub.New()
	defer hub.Close()
	hub.Commit(map[string][]byte{"a.txt": []byte("a")})
	eng := newTestEngine(t, hub)
	ctx := context.Background()
	if _, err := eng.Pull(ctx); err != nil {
		t.Fatal(err)
	}
	writeLocal(t, eng, "a.txt", "serata mia")
	hub.ReplaceGen(1, map[string][]byte{"a.txt": []byte("altro mondo"), "b.txt": []byte("b")})

	_, err := eng.Pull(ctx)
	var dirty *DirtyLocalError
	if !errors.As(err, &dirty) || !dirty.Diverged() {
		t.Fatalf("pull: %v, atteso DirtyLocalError divergente (base ignota)", err)
	}
	if _, err := eng.Push(ctx, "x", false); !errors.Is(err, ErrStaleBase) {
		t.Fatalf("push: %v, atteso ErrStaleBase", err)
	}
	// e se la guardia locale non lo vede (corsa), il 409 dell'hub è lo stesso errore
	if _, err := eng.begin(ctx, 1, strings.Repeat("0", 64), "x", api.Manifest{}, nil, false); !errors.Is(err, ErrStaleBase) {
		t.Fatalf("begin con digest sbagliato: %v", err)
	}
}

// C1: un hub vecchio (senza digest) continua a funzionare come prima.
func TestHubSenzaDigest(t *testing.T) {
	hub := fakehub.New()
	defer hub.Close()
	hub.NoDigest = true
	hub.Commit(map[string][]byte{"a.txt": []byte("a")})
	eng := newTestEngine(t, hub)
	ctx := context.Background()
	if _, err := eng.Pull(ctx); err != nil {
		t.Fatal(err)
	}
	writeLocal(t, eng, "a.txt", "b")
	if _, err := eng.Push(ctx, "x", false); err != nil {
		t.Fatal(err)
	}
}

// C6: begin compresso; hub vecchio → ripiego in chiaro.
func TestBeginCompressoERipiego(t *testing.T) {
	for _, old := range []bool{false, true} {
		hub := fakehub.New()
		hub.PlainBeginOnly = old
		eng := newTestEngine(t, hub)
		writeLocal(t, eng, "a.txt", strings.Repeat("config ", 1000))
		if _, err := eng.Push(context.Background(), "x", false); err != nil {
			t.Fatalf("old=%v: %v", old, err)
		}
		hub.Lock()
		begins, gz := hub.PushBegins, hub.GzipBegins
		hub.Unlock()
		if !old && (begins != 1 || gz != 1) {
			t.Errorf("begin=%d gzip=%d", begins, gz)
		}
		if old && (begins != 1 || gz != 0) {
			t.Errorf("hub vecchio: begin riusciti=%d gzip=%d, atteso 1 in chiaro dopo il rifiuto", begins, gz)
		}
		hub.Close()
	}
}

// C6: un blob rifiutato (hash) non si ritenta con lo stesso hash.
func TestBlobRifiutatoNonRitentato(t *testing.T) {
	hub := fakehub.New()
	defer hub.Close()
	eng := newTestEngine(t, hub)
	writeLocal(t, eng, "a.txt", "contenuto")
	hub.Lock()
	hub.RejectBlobs[fakehub.Hash([]byte("contenuto"))] = true
	hub.Unlock()
	_, err := eng.Push(context.Background(), "x", false)
	if !errors.Is(err, ErrBlobRejected) {
		t.Fatalf("errore = %v", err)
	}
	hub.Lock()
	n := hub.BlobPuts
	hub.Unlock()
	if n != 1 {
		t.Errorf("PUT = %d, atteso 1", n)
	}
}

// C4/I: hub con il disco pieno → errore chiaro e riconoscibile.
func TestHubDiscoPieno(t *testing.T) {
	hub := fakehub.New()
	defer hub.Close()
	hub.DiskFull = true
	eng := newTestEngine(t, hub)
	writeLocal(t, eng, "a.txt", "x")
	_, err := eng.Push(context.Background(), "x", false)
	if !api.IsDiskFull(err) || !strings.Contains(err.Error(), "NAS") {
		t.Fatalf("errore = %v", err)
	}
}

// C4: il pull non parte se sul disco locale non c'è posto.
func TestPullSenzaSpazioLocale(t *testing.T) {
	old := diskFreeFn
	diskFreeFn = func(string) int64 { return 10 }
	defer func() { diskFreeFn = old }()
	hub := fakehub.New()
	defer hub.Close()
	hub.Commit(map[string][]byte{"a.txt": bytes.Repeat([]byte("x"), 1000)})
	eng := newTestEngine(t, hub)
	_, err := eng.Pull(context.Background())
	if !errors.Is(err, ErrLocalDiskFull) {
		t.Fatalf("errore = %v", err)
	}
	if _, err := os.Stat(filepath.Join(eng.LocalPath, "a.txt")); err == nil {
		t.Error("scaricato comunque")
	}
}

// Outbox: lo snapshot congela il contenuto; i cambiamenti dopo non entrano
// nell'upload, che legge solo dall'outbox. Dopo il successo l'outbox è vuota.
func TestSnapshotCongelaEdUploadDallOutbox(t *testing.T) {
	hub := fakehub.New()
	defer hub.Close()
	hub.Commit(map[string][]byte{"level.dat": []byte("v1")})
	eng := newTestEngine(t, hub)
	ctx := context.Background()
	if _, err := eng.Pull(ctx); err != nil {
		t.Fatal(err)
	}
	big := randBytes(3<<20, 7) // a chunk
	writeLocal(t, eng, "level.dat", "v2")
	writeLocal(t, eng, "world/region/r.0.0.mca", string(big))
	snap, err := eng.Snapshot(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if snap.NoChange || snap.Blobs < 3 {
		t.Fatalf("snapshot: %+v", snap)
	}
	if _, err := os.Stat(filepath.Join(eng.OutboxDir(), pendingName)); err != nil {
		t.Error("pending.json mancante")
	}
	// il mondo riparte e cambia tutto
	writeLocal(t, eng, "level.dat", "v3 dopo lo snapshot")
	writeLocal(t, eng, "world/region/r.0.0.mca", "rimpicciolito")
	res, err := eng.PushSnapshot(ctx, snap, "autosave", UploadOpts{Workers: 2})
	if err != nil {
		t.Fatal(err)
	}
	got := hub.Files(res.Gen.N)
	if string(got["level.dat"]) != "v2" {
		t.Errorf("level.dat = %q, atteso lo stato dello snapshot", got["level.dat"])
	}
	if fm := hub.Manifest(res.Gen.N)["world/region/r.0.0.mca"]; fm.Size != int64(len(big)) || fm.Hash != hashBytes(big) {
		t.Errorf("region: %+v", fm)
	}
	if entries, _ := os.ReadDir(eng.OutboxDir()); len(entries) != 0 {
		t.Errorf("outbox non svuotata: %d voci", len(entries))
	}
	if _, meta := LoadCacheMeta(eng.CachePath, eng.LocalPath); meta.Gen != res.Gen.N {
		t.Errorf("base non avanzata: %d", meta.Gen)
	}
	// il push successivo vede le modifiche fatte dopo lo snapshot
	res2, err := eng.Push(ctx, "x", false)
	if err != nil || res2.NoChange || string(hub.Files(res2.Gen.N)["level.dat"]) != "v3 dopo lo snapshot" {
		t.Errorf("push dopo lo snapshot: %+v %v", res2, err)
	}
}

// Outbox: se l'hub chiede un blob che lo snapshot credeva già sul posto e il
// file vivo è cambiato, lo snapshot si abbandona (niente blob sbagliati).
func TestSnapshotBlobFuoriOutboxCambiato(t *testing.T) {
	hub := fakehub.New()
	defer hub.Close()
	hub.Commit(map[string][]byte{"a.txt": []byte("a1"), "b.txt": []byte("b1")})
	eng := newTestEngine(t, hub)
	ctx := context.Background()
	if _, err := eng.Pull(ctx); err != nil {
		t.Fatal(err)
	}
	writeLocal(t, eng, "b.txt", "b2")
	snap, err := eng.Snapshot(ctx)
	if err != nil {
		t.Fatal(err)
	}
	hub.DropBlob(fakehub.Hash([]byte("a1"))) // GC sull'hub: ora lo chiede
	writeLocal(t, eng, "a.txt", "cambiato")
	if _, err := eng.PushSnapshot(ctx, snap, "x", UploadOpts{}); !errors.Is(err, errSnapshotStale) {
		t.Fatalf("errore = %v", err)
	}
}

// Outbox senza spazio: errore dedicato (la sessione ripiega sul push
// sincrono).
func TestSnapshotSenzaSpazio(t *testing.T) {
	old := diskFreeFn
	diskFreeFn = func(string) int64 { return outboxMargin + 10 }
	defer func() { diskFreeFn = old }()
	hub := fakehub.New()
	defer hub.Close()
	eng := newTestEngine(t, hub)
	writeLocal(t, eng, "a.txt", strings.Repeat("x", 100))
	if _, err := eng.Snapshot(context.Background()); !errors.Is(err, ErrOutboxNoSpace) {
		t.Fatalf("errore = %v", err)
	}
}

// Il limiter rispetta la banda (con la raffica iniziale).
func TestRateLimiter(t *testing.T) {
	l := newRateLimiter(400 << 10)
	start := time.Now()
	var wg sync.WaitGroup
	for w := 0; w < 2; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 10; i++ {
				l.wait(context.Background(), 16<<10)
			}
		}()
	}
	wg.Wait()
	// 320 KiB a 400 KiB/s, meno ~100 KiB di raffica: almeno ~0.5 s
	if el := time.Since(start); el < 400*time.Millisecond {
		t.Errorf("troppo veloce: %s", el)
	}
	if newRateLimiter(0) != nil {
		t.Error("limite 0 = nessun limiter")
	}
}

func TestUploadLimit(t *testing.T) {
	e := &Engine{CachePath: filepath.Join(t.TempDir(), "c.json")}
	t.Setenv("MINESYNC_UPLOAD_LIMIT", "")
	if l := e.UploadLimit(0); l != 0 {
		t.Errorf("senza misura: %d", l)
	}
	e.upBps.Store(10 << 20)
	if l := e.UploadLimit(0); l != 7<<20 {
		t.Errorf("auto: %d", l)
	}
	e.upBps.Store(10 << 10)
	if l := e.UploadLimit(0); l != autoLimitMin {
		t.Errorf("auto minimo: %d", l)
	}
	if l := e.UploadLimit(300); l != 300<<10 {
		t.Errorf("config: %d", l)
	}
	if l := e.UploadLimit(-1); l != 0 {
		t.Errorf("config illimitata: %d", l)
	}
	t.Setenv("MINESYNC_UPLOAD_LIMIT", "50")
	if l := e.UploadLimit(300); l != 50<<10 {
		t.Errorf("env: %d", l)
	}
}

// Quiete: un file scritto dopo l'inizio dell'attesa la prolunga.
func TestQuiesceAspettaLeScritture(t *testing.T) {
	hub := fakehub.New()
	defer hub.Close()
	eng := newTestEngine(t, hub)
	writeLocal(t, eng, "a.txt", "x")
	go func() {
		time.Sleep(150 * time.Millisecond)
		writeLocal(t, eng, "tardi.dat", "scritto dopo la conferma")
	}()
	start := time.Now()
	if !eng.Quiesce(context.Background(), 300*time.Millisecond, 3*time.Second, 20*time.Millisecond) {
		t.Fatal("non si è fermata")
	}
	if el := time.Since(start); el < 400*time.Millisecond {
		t.Errorf("quiete dichiarata dopo %s, prima della scrittura tardiva + stabilità", el)
	}
	// una cartella che non smette mai: scade
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		for i := 0; ; i++ {
			select {
			case <-stop:
				return
			case <-time.After(30 * time.Millisecond):
				writeLocal(t, eng, "sempre.dat", strings.Repeat("x", i%50+1))
			}
		}
	}()
	if eng.Quiesce(context.Background(), 300*time.Millisecond, 600*time.Millisecond, 20*time.Millisecond) {
		t.Error("quiete con una cartella che cambia di continuo")
	}
}

// Il tee dei chunk produce gli stessi confini e lo stesso contenuto del
// chunker normale.
func TestTeeChunkerIdentico(t *testing.T) {
	data := randBytes(5<<20, 3)
	p := filepath.Join(t.TempDir(), "r.mca")
	os.WriteFile(p, data, 0o644)
	h1, c1, err := HashAndChunkFile(p, int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	var got []byte
	h2, c2, err := hashChunkTee(p, int64(len(data)), func(h string, b []byte) error {
		if hashBytes(b) != h {
			t.Error("hash del chunk consegnato sbagliato")
		}
		got = append(got, b...)
		return nil
	})
	if err != nil || h1 != h2 || len(c1) != len(c2) {
		t.Fatalf("tee diverso: %v", err)
	}
	for i := range c1 {
		if c1[i] != c2[i] {
			t.Fatalf("chunk %d diverso", i)
		}
	}
	if !bytes.Equal(got, data) {
		t.Error("i byte consegnati non ricompongono il file")
	}
}
