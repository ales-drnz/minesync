package store

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"
	"time"
)

func setHook(t *testing.T, h func(phase string)) {
	t.Helper()
	gcTestHook = h
	t.Cleanup(func() { gcTestHook = func(string) {} })
}

// --- C1: identità delle generazioni ---

func TestGenerationDigest(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	g := pushFiles(t, s, "v", "alex", 0, map[string][]byte{"b": []byte("2"), "a": []byte("1")})
	full, _ := s.Generation("v", 1)
	if g.Digest == "" || g.Digest != ManifestDigest(full.Files) || full.Digest != g.Digest {
		t.Fatalf("digest della generazione: summary %q, gen %q", g.Digest, full.Digest)
	}
	// la codifica canonica non dipende dall'ordine di inserimento
	m := Manifest{}
	m["a"], m["b"] = full.Files["a"], full.Files["b"]
	if ManifestDigest(m) != g.Digest {
		t.Fatal("digest dipendente dall'ordine delle chiavi")
	}
	if want := string(canonicalFiles(Manifest{"<&>": {Hash: "h", Size: 1}})); want != `{"<&>":{"h":"h","s":1}}` {
		t.Fatalf("codifica canonica inattesa: %s", want)
	}
	if ManifestDigest(nil) != emptyDigest || len(emptyDigest) != 64 {
		t.Fatal("digest del manifest vuoto")
	}
	gens, _ := s.Generations("v", 0)
	if gens[0].Digest != g.Digest {
		t.Fatal("la storia non riporta il digest")
	}
	_, d, err := s.ManifestDigestAt("v", 0)
	if err != nil || d != emptyDigest {
		t.Fatalf("digest della generazione 0: %q %v", d, err)
	}

	// generazione scritta prima della 3.2 (senza digest): calcolato in lettura
	var raw map[string]any
	b, _ := os.ReadFile(s.genPath("v", 1))
	json.Unmarshal(b, &raw)
	delete(raw, "digest")
	b, _ = json.Marshal(raw)
	os.WriteFile(s.genPath("v", 1), b, 0o644)
	_, d, err = s.ManifestDigestAt("v", 1)
	if err != nil || d != g.Digest {
		t.Fatalf("digest calcolato per una generazione vecchia: %q (atteso %q) %v", d, g.Digest, err)
	}
}

func TestParentDigestStaleBase(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	g1 := pushFiles(t, s, "v", "alex", 0, map[string][]byte{"a": []byte("1")})
	man := manifestOf(map[string][]byte{"a": []byte("2")})
	try := func(parent int, digest string) error {
		_, _, err := s.BeginPush("v", PushOptions{Author: "alex", Parent: parent, ParentDigest: digest, Files: man, NoLock: true})
		return err
	}
	if err := try(1, g1.Digest); err != nil {
		t.Fatalf("base giusta rifiutata: %v", err)
	}
	if err := try(1, ""); err != nil {
		t.Fatalf("client 3.1 (senza digest) rifiutato: %v", err)
	}
	var sb *StaleBaseError
	if err := try(1, strings.Repeat("0", 64)); !errors.As(err, &sb) || !errors.Is(err, ErrConflict) {
		t.Fatalf("stessa generazione, storia diversa: %v", err)
	}
	// hub ripristinato a una generazione precedente: il genitore non esiste
	if err := try(7, g1.Digest); !errors.As(err, &sb) {
		t.Fatalf("genitore inesistente: %v", err)
	}
	// spazio vuoto, base vuota dichiarata
	s.CreateSpace("w", "generic", nil)
	if _, _, err := s.BeginPush("w", PushOptions{Author: "a", Parent: 0, ParentDigest: emptyDigest, Files: man, NoLock: true}); err != nil {
		t.Fatalf("base vuota: %v", err)
	}
}

// --- C5: nomi non validi su Windows ---

func TestWindowsInvalidNamesRejected(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	ok := []string{"world/region/r.0.0.mca", "config/a b.txt", "COM0", "LPT10.txt", "console.log", "CONx", ".minesync"}
	bad := []string{"a:b", "x/<y>", `q"`, "p|q", "w?", "s*", "ctl\x01", "con", "World/NUL.txt", "aux.tar.gz",
		"COM1", "lpt9.log", "dir./file", "trail ", "x/y."}
	for _, p := range ok {
		if err := validateManifest(Manifest{p: {Hash: strings.Repeat("a", 64), Size: 1}}); err != nil {
			t.Errorf("%q rifiutato: %v", p, err)
		}
	}
	var bp *BadPathError
	for _, p := range bad {
		_, _, err := begin(s, "v", "alex", "m", 0, Manifest{p: {Hash: strings.Repeat("a", 64), Size: 1}}, nil)
		if !errors.As(err, &bp) || bp.Path != p || !errors.Is(err, ErrBadRequest) {
			t.Errorf("%q accettato o errore sbagliato: %v", p, err)
		}
	}
	// duplicati a meno di maiuscole: si nomina il secondo (in ordine)
	h := FileMeta{Hash: strings.Repeat("a", 64), Size: 1}
	_, _, err := begin(s, "v", "alex", "m", 0, Manifest{"World/a": h, "world/a": h, "z": h}, nil)
	if !errors.As(err, &bp) || bp.Path != "world/a" || bp.Dup != "World/a" {
		t.Fatalf("duplicato maiuscole/minuscole: %v", err)
	}
}

// --- C3: la sessione è l'autorità, il nome solo un'etichetta ---

func TestLockSessionIsAuthority(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	lk, _, err := s.AcquireLock("v", "alex", nil, 90)
	if err != nil {
		t.Fatal(err)
	}
	// rinominato in ZTNET a sessione in corso
	got, err := s.HeartbeatLock("v", lk.Session, "alessandro", nil, false)
	if err != nil || got.Owner != "alessandro" {
		t.Fatalf("heartbeat dopo il rinomino: %v %+v", err, got)
	}
	files := map[string][]byte{"a": []byte("x")}
	pid, missing, err := s.BeginPush("v", PushOptions{Author: "alex-nuovo", Files: manifestOf(files), LockSession: lk.Session})
	if err != nil {
		t.Fatalf("push dopo il rinomino: %v", err)
	}
	for range missing {
		s.PutBlob("v", hashBytes(files["a"]), bytes.NewReader(files["a"]), false)
	}
	if _, _, err := s.CommitPush("v", pid); err != nil {
		t.Fatalf("commit dopo il rinomino: %v", err)
	}
	if cur, _ := s.CurrentLock("v"); cur.Owner != "alex-nuovo" {
		t.Fatalf("nome mostrato non aggiornato: %q", cur.Owner)
	}
	// un altro con la sessione sbagliata resta fuori
	if _, err := s.HeartbeatLock("v", "altra", "alex", nil, false); !errors.Is(err, ErrConflict) {
		t.Fatalf("heartbeat con sessione sbagliata: %v", err)
	}
	if _, err := s.ReleaseLock("v", lk.Session, false); err != nil {
		t.Fatalf("rilascio con la sessione: %v", err)
	}
}

// --- punto 3: spazio eliminato ---

func TestDeleteSpaceRefusedWhileLocked(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	lk, _, _ := s.AcquireLock("v", "alex", nil, 1)
	var le *LockedError
	if err := s.DeleteSpace("v"); !errors.As(err, &le) {
		t.Fatalf("eliminato con un lock vivo: %v", err)
	}
	time.Sleep(1100 * time.Millisecond) // stale: ora sì
	if err := s.DeleteSpace("v"); err != nil {
		t.Fatal(err)
	}
	var sg *SpaceGoneError
	_, err := s.HeartbeatLock("v", lk.Session, "alex", nil, false)
	if !errors.As(err, &sg) || !errors.Is(err, ErrNotFound) {
		t.Fatalf("heartbeat su spazio eliminato: %v", err)
	}
	if _, ok := s.LockSnapshot("v"); ok {
		t.Fatal("istantanea di uno spazio eliminato")
	}
}

// --- punto 4: tempi monotoni in memoria, UTC fuori ---

func TestLockTimesMonotonicAndUTC(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	lk, _, _ := s.AcquireLock("v", "alex", nil, 90)
	if !strings.Contains(lk.LastBeat.String(), "m=") {
		t.Fatal("LastBeat senza lettura monotona: i confronti seguono l'orologio di sistema")
	}
	b, _ := json.Marshal(lk)
	var out struct{ Since, LastBeat string }
	json.Unmarshal(b, &out)
	if !strings.HasSuffix(out.Since, "Z") || !strings.HasSuffix(out.LastBeat, "Z") {
		t.Fatalf("istanti non in UTC: %s", b)
	}
	// lock riletto da disco con LastBeat "nel futuro" (orologio tornato
	// indietro): il delta negativo non sottrae tempo alle statistiche
	st, _ := s.space("v")
	st.mu.Lock()
	st.lock.LastBeat = time.Now().Add(time.Hour).Round(0)
	st.mu.Unlock()
	if _, err := s.HeartbeatLock("v", lk.Session, "", []string{"p"}, false); err != nil {
		t.Fatal(err)
	}
	ss, _ := s.Stats("v")
	if ss.Hosts["alex"].Seconds < 0 {
		t.Fatalf("statistiche negative: %+v", ss.Hosts)
	}
}

// --- C4: disco pieno ---

func TestDiskFullRefusesWrites(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	pushFiles(t, s, "v", "alex", 0, map[string][]byte{"a": []byte("1")})
	var free uint64 = 100 << 30
	s.statfs = func(string) (uint64, uint64, error) { return free, 1000 << 30, nil }
	s.DiskGuard = true
	if got := s.MinFreeBytes(1000 << 30); got != 20<<30 {
		t.Fatalf("soglia 2%%: %d", got)
	}
	if got := s.MinFreeBytes(10 << 30); got != 1<<30 {
		t.Fatalf("soglia minima 1 GiB: %d", got)
	}
	if _, _, err := s.AcquireLock("v", "alex", nil, 90); err != nil {
		t.Fatalf("spazio sufficiente ma rifiutato: %v", err)
	}
	s.ReleaseLock("v", "", true)
	free = 5 << 30
	var df *DiskFullError
	if _, _, err := s.AcquireLock("v", "alex", nil, 90); !errors.As(err, &df) {
		t.Fatalf("lock con disco pieno: %v", err)
	}
	if _, _, err := begin(s, "v", "alex", "m", 1, manifestOf(map[string][]byte{"b": []byte("2")}), nil); !errors.As(err, &df) {
		t.Fatalf("push con disco pieno: %v", err)
	}
	if _, err := s.PutBlob("v", hashBytes([]byte("2")), bytes.NewReader([]byte("2")), false); !errors.As(err, &df) {
		t.Fatalf("blob con disco pieno: %v", err)
	}
	if _, err := s.Restore("v", 1, "admin"); !errors.As(err, &df) {
		t.Fatalf("restore con disco pieno: %v", err)
	}
	s.MinFree = 1 << 30 // MINESYNC_MIN_FREE
	if _, err := s.Restore("v", 1, "admin"); err != nil {
		t.Fatalf("soglia esplicita ignorata: %v", err)
	}
	for in, want := range map[string]uint64{"5GiB": 5 << 30, "500MB": 500e6, "1024": 1024, "1.5 GiB": 3 << 29} {
		if got, err := ParseBytes(in); err != nil || got != want {
			t.Errorf("ParseBytes(%q) = %d %v, atteso %d", in, got, err, want)
		}
	}
	if _, err := ParseBytes("tanti"); err == nil {
		t.Error("ParseBytes ha accettato una dimensione senza numero")
	}
}

// --- punto 2: GC fuori dal mutex ---

// Un commit concorrente che riusa un blob orfano mentre il GC lo sta per
// eliminare: il blob deve restare. E durante le fasi lunghe heartbeat e
// commit non aspettano il mutex.
func TestGCConcurrentCommitDuringSweep(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	for i := 0; i < 3; i++ {
		pushFiles(t, s, "v", "alex", i, map[string][]byte{"a": []byte(strings.Repeat("q", i+1))})
	}
	lk, _, _ := s.AcquireLock("v", "alex", nil, 90)
	var hooked int
	setHook(t, func(phase string) {
		if phase != "candidates" {
			return
		}
		hooked++
		// se il GC tenesse il mutex qui, queste chiamate (stessa goroutine)
		// resterebbero bloccate per sempre
		if _, err := s.HeartbeatLock("v", lk.Session, "", nil, false); err != nil {
			t.Errorf("heartbeat durante il GC: %v", err)
		}
		if _, ok := s.LockSnapshot("v"); !ok {
			t.Error("istantanea assente")
		}
		// gen 4 = gen 1: riusa il blob "q", orfano per il GC
		pushFiles(t, s, "v", "alex", 3, map[string][]byte{"a": []byte("q")})
	})
	res, err := s.GC("v", 1)
	if err != nil {
		t.Fatal(err)
	}
	if hooked != 1 {
		t.Fatalf("hook chiamato %d volte", hooked)
	}
	if !s.HasBlob("v", hashBytes([]byte("q"))) {
		t.Fatal("il GC ha cancellato un blob referenziato da una generazione scritta durante la pulizia")
	}
	if s.HasBlob("v", hashBytes([]byte("qq"))) {
		t.Fatal("blob orfano non eliminato")
	}
	if res.GenerationsPruned != 2 || res.BlobsDeleted != 1 {
		t.Fatalf("GC inatteso: %+v", res)
	}
	m, _ := s.ManifestAt("v", 4)
	if err := s.CheckBlobs("v", m); err != nil {
		t.Fatalf("HEAD con blob mancanti: %v", err)
	}
}

// Un push aperto mentre il GC ha già calcolato i referenziati: il blob
// deduplicato (non ricaricato dal client) deve sopravvivere fino al commit.
func TestGCOpenPushDuringSweep(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	for i := 0; i < 3; i++ {
		pushFiles(t, s, "v", "alex", i, map[string][]byte{"a": []byte(strings.Repeat("w", i+1))})
	}
	var pid string
	setHook(t, func(phase string) {
		if phase != "referenced" {
			return
		}
		var missing []string
		var err error
		pid, missing, err = begin(s, "v", "alex", "m", 3, manifestOf(map[string][]byte{"a": []byte("ww")}), nil)
		if err != nil || len(missing) != 0 {
			t.Errorf("begin durante il GC: %v %v", missing, err)
		}
	})
	if _, err := s.GC("v", 1); err != nil {
		t.Fatal(err)
	}
	if _, err := commit(s, "v", pid); err != nil {
		t.Fatalf("commit di un push aperto durante il GC: %v", err)
	}
}

// La retention gira in background: mentre rilegge i manifest, heartbeat,
// commit e istantanea del lock non aspettano.
func TestRetentionDoesNotBlockCommits(t *testing.T) {
	s := newStore(t)
	s.KeepLast = 1
	s.CreateSpace("v", "generic", nil)
	lk, _, _ := s.AcquireLock("v", "alex", nil, 90)
	entered, release := make(chan struct{}), make(chan struct{})
	setHook(t, func(phase string) {
		if phase == "referenced" {
			close(entered)
			<-release
		}
	})
	// gens vecchie da potare: la prima retention parte al primo commit
	for i := 0; i < 3; i++ {
		pushFiles(t, s, "v", "alex", i, map[string][]byte{"a": []byte(strings.Repeat("r", i+1))})
		if i == 0 {
			setGenTime(t, s, "v", 1, time.Now().Add(-20*24*time.Hour))
		}
	}
	// la retention del primo commit vede solo la gen 1 (unica): niente hook.
	// Forziamo una retention ora, in background come dopo un commit.
	s.waitGC()
	st, _ := s.space("v")
	st.mu.Lock()
	run := st.startGCLocked()
	st.mu.Unlock()
	s.gcWG.Add(1)
	go func() {
		defer s.gcWG.Done()
		s.retention("v", st, run, time.Now())
	}()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("la retention non è partita")
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		if _, err := s.HeartbeatLock("v", lk.Session, "", nil, false); err != nil {
			t.Errorf("heartbeat: %v", err)
		}
		pid, _, err := begin(s, "v", "alex", "m", 3, manifestOf(map[string][]byte{"a": []byte("rrr")}), nil)
		if err == nil {
			_, err = commit(s, "v", pid)
		}
		if err != nil {
			t.Errorf("commit durante la retention: %v", err)
		}
	}()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("heartbeat/commit bloccati dalla retention")
	}
	close(release)
	s.waitGC()
	if _, err := os.Stat(s.genPath("v", 1)); !os.IsNotExist(err) {
		t.Fatalf("la gen 1 (20 giorni, oltre KeepLast) doveva essere potata: %v", err)
	}
	if s.HasBlob("v", hashBytes([]byte("r"))) {
		t.Fatal("blob orfano della gen 1 non eliminato")
	}
	for _, n := range []int{2, 3, 4} {
		if _, err := s.Generation("v", n); err != nil {
			t.Fatalf("gen %d persa: %v", n, err)
		}
	}
}

// --- istantanea dei lock per il DNS ---

func TestLockSnapshotWithoutSpaceMutex(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	if lk, ok := s.LockSnapshot("v"); !ok || lk != nil {
		t.Fatal("istantanea iniziale")
	}
	lk, _, _ := s.AcquireLock("v", "alex", map[string]string{"host": "10.0.0.1"}, 90)
	st, _ := s.space("v")
	st.mu.Lock() // un commit o un GC lungo
	got, ok := s.LockSnapshot("v")
	st.mu.Unlock()
	if !ok || got == nil || got.Owner != "alex" || got.Session != "" || got.Info["host"] != "10.0.0.1" {
		t.Fatalf("istantanea: %+v", got)
	}
	s.ReleaseLock("v", lk.Session, false)
	if got, _ := s.LockSnapshot("v"); got != nil {
		t.Fatal("istantanea non aggiornata al rilascio")
	}
	// riavvio dell'hub: l'istantanea riparte dal lock su disco
	s.AcquireLock("v", "bob", nil, 90)
	s2, err := Open(s.root)
	if err != nil {
		t.Fatal(err)
	}
	if got, _ := s2.LockSnapshot("v"); got == nil || got.Owner != "bob" {
		t.Fatalf("istantanea dopo il riavvio: %+v", got)
	}
}
