package store

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"strings"
	"testing"
	"time"
)

func newStore(t *testing.T) *Store {
	t.Helper()
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func hashBytes(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

// pushFiles esegue un ciclo begin→upload→commit completo.
func pushFiles(t *testing.T, s *Store, space, author string, parent int, files map[string][]byte) GenSummary {
	t.Helper()
	man := Manifest{}
	for p, b := range files {
		man[p] = FileMeta{Hash: hashBytes(b), Size: int64(len(b))}
	}
	pid, missing, err := begin(s, space, author, "test", parent, man, nil)
	if err != nil {
		t.Fatalf("BeginPush: %v", err)
	}
	byHash := map[string][]byte{}
	for _, b := range files {
		byHash[hashBytes(b)] = b
	}
	for _, h := range missing {
		if _, err := s.PutBlob(space, h, bytes.NewReader(byHash[h]), false); err != nil {
			t.Fatalf("PutBlob: %v", err)
		}
	}
	gen, err := commit(s, space, pid)
	if err != nil {
		t.Fatalf("CommitPush: %v", err)
	}
	return gen
}

func TestPushLifecycle(t *testing.T) {
	s := newStore(t)
	if _, err := s.CreateSpace("MioMondo", "minecraft", nil); err != nil {
		t.Fatal(err)
	}
	g1 := pushFiles(t, s, "miomondo", "alex", 0, map[string][]byte{
		"world/level.dat":   []byte("livello"),
		"server.properties": []byte("porta=25565"),
	})
	if g1.N != 1 || g1.Stats.Added != 2 {
		t.Fatalf("gen1 inattesa: %+v", g1)
	}
	// seconda generazione: un file cambia, uno rimosso, uno nuovo
	g2 := pushFiles(t, s, "miomondo", "steve", 1, map[string][]byte{
		"world/level.dat": []byte("livello v2"),
		"mods/nuovo.jar":  []byte("jar"),
	})
	if g2.N != 2 || g2.Stats.Added != 1 || g2.Stats.Changed != 1 || g2.Stats.Removed != 1 {
		t.Fatalf("stats gen2: %+v", g2.Stats)
	}
	// dedup: il blob invariato non deve essere richiesto di nuovo
	man := Manifest{"world/level.dat": {Hash: hashBytes([]byte("livello v2")), Size: 10}}
	_, missing, err := begin(s, "miomondo", "alex", "x", 2, man, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(missing) != 0 {
		t.Fatalf("blob già noto richiesto di nuovo: %v", missing)
	}
	// manifest storico leggibile
	m1, err := s.ManifestAt("miomondo", 1)
	if err != nil || len(m1) != 2 {
		t.Fatalf("manifest gen1: %v %v", m1, err)
	}
}

func TestPushCASConflict(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	pushFiles(t, s, "v", "alex", 0, map[string][]byte{"a": []byte("1")})
	if _, _, err := begin(s, "v", "steve", "m", 0, Manifest{}, nil); !errors.Is(err, ErrConflict) {
		t.Fatalf("atteso conflitto CAS, avuto %v", err)
	}
}

func TestPutBlobRejectsWrongHash(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	wrong := hashBytes([]byte("altro"))
	if _, err := s.PutBlob("v", wrong, strings.NewReader("contenuto"), false); !errors.Is(err, ErrBadRequest) {
		t.Fatalf("atteso rifiuto hash, avuto %v", err)
	}
	if s.HasBlob("v", wrong) {
		t.Fatal("blob corrotto accettato")
	}
}

// TestPutBlobGzip: upload compresso → hash verificato sul contenuto originale,
// lettura trasparente decompressa, GC che riconosce i .gz.
func TestPutBlobGzip(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	content := []byte(strings.Repeat("mondo di minecraft ", 100))
	h := hashBytes(content)
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	zw.Write(content)
	zw.Close()
	if _, err := s.PutBlob("v", h, &buf, true); err != nil {
		t.Fatalf("PutBlob gzip: %v", err)
	}
	if !s.HasBlob("v", h) {
		t.Fatal("blob gzip non trovato")
	}
	// lettura decompressa trasparente
	rc, _, err := s.OpenBlob("v", h)
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(rc)
	rc.Close()
	if !bytes.Equal(got, content) {
		t.Fatal("contenuto decompresso diverso dall'originale")
	}
	// formato raw riportato correttamente
	f, _, gzipped, err := s.OpenBlobRaw("v", h)
	if err != nil || !gzipped {
		t.Fatalf("OpenBlobRaw: gzipped=%v err=%v", gzipped, err)
	}
	f.Close()
	// hash dichiarato che non corrisponde al contenuto del gzip → rifiutato
	var buf2 bytes.Buffer
	zw2 := gzip.NewWriter(&buf2)
	zw2.Write([]byte("altro contenuto"))
	zw2.Close()
	wrong := hashBytes([]byte("contenuto mai caricato"))
	if _, err := s.PutBlob("v", wrong, &buf2, true); !errors.Is(err, ErrBadRequest) {
		t.Fatalf("gzip con hash sbagliato accettato: %v", err)
	}
	if s.HasBlob("v", wrong) {
		t.Fatal("blob gzip corrotto rimasto su disco")
	}
	// il GC spazza anche i .gz orfani
	deleted, _ := sweepAll(s, "v")
	if deleted != 1 {
		t.Fatalf("blob gzip orfano non spazzato: %d", deleted)
	}
}

// TestChunkedFileLifecycle: un file spezzato in chunk attraversa push,
// lettura assemblata, GC e restore senza che il blob "intero" esista mai.
func TestChunkedFileLifecycle(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "minecraft", nil)
	c1, c2 := []byte(strings.Repeat("A", 1000)), []byte(strings.Repeat("B", 500))
	whole := hashBytes(append(append([]byte{}, c1...), c2...))
	man := Manifest{"world/region/r.0.0.mca": {
		Hash: whole, Size: 1500,
		Chunks: []Chunk{{Hash: hashBytes(c1), Size: 1000}, {Hash: hashBytes(c2), Size: 500}},
	}}
	pid, missing, err := begin(s, "v", "alex", "chunked", 0, man, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(missing) != 2 {
		t.Fatalf("attesi 2 chunk mancanti, avuti %v", missing)
	}
	// commit rifiutato finché manca un chunk
	if _, err := s.PutBlob("v", hashBytes(c1), bytes.NewReader(c1), false); err != nil {
		t.Fatal(err)
	}
	if _, err := commit(s, "v", pid); !errors.Is(err, ErrBadRequest) {
		t.Fatalf("commit con chunk mancante accettato: %v", err)
	}
	if _, err := s.PutBlob("v", hashBytes(c2), bytes.NewReader(c2), false); err != nil {
		t.Fatal(err)
	}
	if _, err := commit(s, "v", pid); err != nil {
		t.Fatal(err)
	}
	// lettura assemblata = contenuto originale
	g, _ := s.Generation("v", 1)
	rc, err := s.OpenFile("v", g.Files["world/region/r.0.0.mca"])
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(rc)
	rc.Close()
	if hashBytes(got) != whole {
		t.Fatal("assemblaggio chunk diverso dall'originale")
	}
	// il GC deve considerare i chunk referenziati (e non spazzarli)
	if del, _ := sweepAll(s, "v"); del != 0 {
		t.Fatalf("GC ha spazzato %d chunk referenziati", del)
	}
	// restore di una generazione chunked
	pushFiles(t, s, "v", "alex", 1, map[string][]byte{"a": []byte("x")})
	if _, err := s.Restore("v", 1, "alex"); err != nil {
		t.Fatalf("restore chunked: %v", err)
	}
	// chunk con somma sbagliata → respinto
	bad := Manifest{"f": {Hash: whole, Size: 999,
		Chunks: []Chunk{{Hash: hashBytes(c1), Size: 1000}}}}
	if _, _, err := begin(s, "v", "alex", "m", 3, bad, nil); !errors.Is(err, ErrBadRequest) {
		t.Fatalf("chunk incoerenti accettati: %v", err)
	}
}

// TestRestoreFile: un region danneggiato in una generazione viene riportato
// alla versione integra precedente, senza toccare il resto del mondo.
func TestRestoreFile(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "minecraft", nil)
	rf := "world/region/r.0.0.mca"
	// gen1: region sano + un altro file
	pushFiles(t, s, "v", "alex", 0, map[string][]byte{
		rf:                  []byte("region sano"),
		"server.properties": []byte("porta=25565"),
	})
	// gen2: region "danneggiato" (marcato corrupt) + altro file cambiato
	man := Manifest{
		rf:                  {Hash: hashBytes([]byte("region rotto")), Size: 12},
		"server.properties": {Hash: hashBytes([]byte("porta=25566")), Size: 11},
	}
	pid, missing, err := begin(s, "v", "steve", "danno", 1, man, []string{rf})
	if err != nil {
		t.Fatal(err)
	}
	for _, h := range missing {
		content := map[string][]byte{
			hashBytes([]byte("region rotto")): []byte("region rotto"),
			hashBytes([]byte("porta=25566")):  []byte("porta=25566"),
		}[h]
		s.PutBlob("v", h, bytes.NewReader(content), false)
	}
	g2, err := commit(s, "v", pid)
	if err != nil {
		t.Fatal(err)
	}
	if len(g2.Corrupt) != 1 || g2.Corrupt[0] != rf {
		t.Fatalf("gen2 non segnala il file corrotto: %+v", g2.Corrupt)
	}
	// ripristino automatico: torna alla versione di gen1 SOLO per il region
	g3, err := s.RestoreFile("v", rf, 0, "alex")
	if err != nil {
		t.Fatal(err)
	}
	m3, _ := s.ManifestAt("v", g3.N)
	if m3[rf].Hash != hashBytes([]byte("region sano")) {
		t.Fatal("il region non è tornato alla versione integra")
	}
	// il resto del mondo resta com'era in gen2 (non toccato)
	if m3["server.properties"].Hash != hashBytes([]byte("porta=25566")) {
		t.Fatal("restore-file ha alterato un file non richiesto")
	}
}

func TestCommitRefusesMissingBlob(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	man := Manifest{"a": {Hash: hashBytes([]byte("mai caricato")), Size: 12}}
	pid, _, err := begin(s, "v", "alex", "m", 0, man, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := commit(s, "v", pid); !errors.Is(err, ErrBadRequest) {
		t.Fatalf("atteso blob mancante, avuto %v", err)
	}
}

func TestPathValidation(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	for _, bad := range []string{"../fuga", "/assoluto", "a\\b", "a/../b", ""} {
		man := Manifest{bad: {Hash: hashBytes([]byte("x")), Size: 1}}
		if _, _, err := begin(s, "v", "alex", "m", 0, man, nil); !errors.Is(err, ErrBadRequest) {
			t.Fatalf("percorso %q accettato", bad)
		}
	}
}

func TestLockLifecycle(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	lk, took, err := s.AcquireLock("v", "alex", map[string]string{"host": "1.2.3.4"}, 90)
	if err != nil || took != nil {
		t.Fatalf("acquire: %v %v", err, took)
	}
	// secondo acquirente respinto con dettagli
	_, _, err = s.AcquireLock("v", "steve", nil, 90)
	var le *LockedError
	if !errors.As(err, &le) || le.Holder.Owner != "alex" || le.Holder.Session != "" {
		t.Fatalf("atteso LockedError redatto, avuto %v", err)
	}
	// heartbeat con session sbagliata
	if _, err := s.HeartbeatLock("v", "sbagliata", nil, false); !errors.Is(err, ErrConflict) {
		t.Fatalf("heartbeat estraneo accettato: %v", err)
	}
	if _, err := s.HeartbeatLock("v", lk.Session, []string{"steve", "alex"}, false); err != nil {
		t.Fatal(err)
	}
	// release con session sbagliata su lock vivo → rifiutato
	if _, err := s.ReleaseLock("v", "sbagliata", false); !errors.Is(err, ErrConflict) {
		t.Fatalf("release estraneo accettato: %v", err)
	}
	// release corretto
	if _, err := s.ReleaseLock("v", lk.Session, false); err != nil {
		t.Fatal(err)
	}
	if cur, _ := s.CurrentLock("v"); cur != nil {
		t.Fatal("lock ancora presente dopo release")
	}
}

func TestStaleLockTakeover(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	lk, _, err := s.AcquireLock("v", "alex", nil, 1) // TTL 1s
	if err != nil {
		t.Fatal(err)
	}
	_ = lk
	time.Sleep(1100 * time.Millisecond)
	nlk, took, err := s.AcquireLock("v", "steve", nil, 90)
	if err != nil {
		t.Fatalf("takeover stale fallito: %v", err)
	}
	if took == nil || took.Owner != "alex" || nlk.Owner != "steve" {
		t.Fatalf("takeover non riportato: %+v", took)
	}
}

func TestLockPersistence(t *testing.T) {
	dir := t.TempDir()
	s, _ := Open(dir)
	s.CreateSpace("v", "generic", nil)
	s.AcquireLock("v", "alex", nil, 90)
	// riavvio dell'hub
	s2, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	lk, _ := s2.CurrentLock("v")
	if lk == nil || lk.Owner != "alex" {
		t.Fatalf("lock perso dopo riavvio: %+v", lk)
	}
}

func TestRestore(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	pushFiles(t, s, "v", "alex", 0, map[string][]byte{"a": []byte("v1")})
	pushFiles(t, s, "v", "alex", 1, map[string][]byte{"a": []byte("v2")})
	gen, err := s.Restore("v", 1, "alex")
	if err != nil {
		t.Fatal(err)
	}
	if gen.N != 3 || gen.Restore != 1 {
		t.Fatalf("restore inatteso: %+v", gen)
	}
	m, _ := s.ManifestAt("v", 3)
	if m["a"].Hash != hashBytes([]byte("v1")) {
		t.Fatal("restore non ha ripristinato il contenuto di gen1")
	}
}

func TestGC(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	for i := 0; i < 5; i++ {
		pushFiles(t, s, "v", "alex", i, map[string][]byte{"a": []byte(strings.Repeat("x", i+1))})
	}
	res, err := s.GC("v", 2)
	if err != nil {
		t.Fatal(err)
	}
	if res.GenerationsPruned != 3 || res.GenerationsKept != 2 {
		t.Fatalf("GC inatteso: %+v", res)
	}
	if res.BlobsDeleted != 3 {
		t.Fatalf("blob orfani non eliminati: %+v", res)
	}
	// HEAD e la penultima devono restare leggibili
	if _, err := s.ManifestAt("v", 5); err != nil {
		t.Fatal("HEAD potata dal GC")
	}
	if _, err := s.ManifestAt("v", 4); err != nil {
		t.Fatal("gen 4 potata dal GC")
	}
	// storia: le generazioni potate spariscono senza errori
	gens, err := s.Generations("v", 0)
	if err != nil || len(gens) != 2 {
		t.Fatalf("storia dopo GC: %v %v", gens, err)
	}
}

// begin apre un push senza lock (i test del lock usano BeginPush diretto).
func begin(s *Store, space, author, msg string, parent int, man Manifest, corrupt []string) (string, []string, error) {
	return s.BeginPush(space, PushOptions{Author: author, Message: msg, Parent: parent,
		Files: man, Corrupt: corrupt, NoLock: true})
}

func commit(s *Store, space, pid string) (GenSummary, error) {
	g, _, err := s.CommitPush(space, pid)
	return g, err
}

// sweepAll spazza i blob non referenziati senza potare generazioni.
func sweepAll(s *Store, space string) (int, int64) {
	st, _ := s.space(space)
	st.mu.Lock()
	defer st.mu.Unlock()
	ns, _ := s.genNumbers(space)
	res, _ := s.pruneLocked(space, st, ns, nil)
	return res.BlobsDeleted, res.BytesFreed
}

func TestDeleteGeneration(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	for i := 0; i < 3; i++ {
		pushFiles(t, s, "v", "alex", i, map[string][]byte{"a": []byte(strings.Repeat("z", i+1))})
	}
	// HEAD intoccabile
	if err := s.DeleteGeneration("v", 3); !errors.Is(err, ErrBadRequest) {
		t.Fatalf("HEAD eliminabile?! %v", err)
	}
	if err := s.DeleteGeneration("v", 2); err != nil {
		t.Fatal(err)
	}
	gens, _ := s.Generations("v", 0)
	if len(gens) != 2 || gens[0].N != 3 || gens[1].N != 1 {
		t.Fatalf("storia dopo delete: %+v", gens)
	}
	if s.HasBlob("v", hashBytes([]byte("zz"))) {
		t.Fatal("blob della gen eliminata ancora presente")
	}
	if !s.HasBlob("v", hashBytes([]byte("zzz"))) || !s.HasBlob("v", hashBytes([]byte("z"))) {
		t.Fatal("blob delle gen sopravvissute spariti")
	}
}
