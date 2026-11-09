package store

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// manyFiles costruisce n file distinti.
func manyFiles(n int, tag string) map[string][]byte {
	out := map[string][]byte{}
	for i := 0; i < n; i++ {
		out[fmt.Sprintf("f%03d", i)] = []byte(fmt.Sprintf("%s-%d", tag, i))
	}
	return out
}

func manifestOf(files map[string][]byte) Manifest {
	m := Manifest{}
	for p, b := range files {
		m[p] = FileMeta{Hash: hashBytes(b), Size: int64(len(b))}
	}
	return m
}

// D2: Stats serializzate mentre l'heartbeat scrive le mappe.
func TestConcurrentStatsHeartbeat(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	lk, _, err := s.AcquireLock("v", "alex", map[string]string{"port": "25565"}, 90)
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	stop := make(chan struct{})
	wg.Add(2)
	go func() {
		defer wg.Done()
		for i := 0; ; i++ {
			select {
			case <-stop:
				return
			default:
			}
			got, err := s.HeartbeatLock("v", lk.Session, []string{fmt.Sprintf("p%d", i%50), "alex"}, true)
			if err != nil {
				t.Error(err)
				return
			}
			got.Players = append(got.Players, "x") // la copia è nostra
			got.Info["port"] = "1"
		}
	}()
	go func() {
		defer wg.Done()
		for i := 0; i < 300; i++ {
			ss, err := s.Stats("v")
			if err != nil {
				t.Error(err)
				return
			}
			if _, err := json.Marshal(ss); err != nil {
				t.Error(err)
			}
			if cur, _ := s.CurrentLock("v"); cur != nil {
				json.Marshal(cur)
			}
		}
		close(stop)
	}()
	wg.Wait()
	if cur, _ := s.CurrentLock("v"); cur.Info["port"] != "25565" {
		t.Fatal("la copia restituita dall'heartbeat condivide la mappa Info")
	}
}

// D7: GC e DeleteGeneration durante un push aperto non toccano i blob caricati.
func TestGCDuringOpenPushKeepsBlobs(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	for i := 0; i < 3; i++ {
		pushFiles(t, s, "v", "alex", i, map[string][]byte{"a": []byte(strings.Repeat("q", i+1))})
	}
	// push aperto che riusa un blob di gen1 (dedup: non verrà ricaricato)
	// e ne carica uno nuovo
	files := map[string][]byte{"a": []byte("q"), "b": []byte("nuovo")}
	pid, missing, err := begin(s, "v", "alex", "m", 3, manifestOf(files), nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(missing) != 1 {
		t.Fatalf("missing inatteso: %v", missing)
	}
	if _, err := s.PushBlob("v", pid, missing[0], bytes.NewReader([]byte("nuovo")), false); err != nil {
		t.Fatal(err)
	}
	if err := s.DeleteGeneration("v", 1); err != nil {
		t.Fatal(err)
	}
	if _, err := s.GC("v", 1); err != nil {
		t.Fatal(err)
	}
	if !s.HasBlob("v", hashBytes([]byte("q"))) || !s.HasBlob("v", hashBytes([]byte("nuovo"))) {
		t.Fatal("il GC ha cancellato blob di un push in corso")
	}
	if _, err := commit(s, "v", pid); err != nil {
		t.Fatalf("commit dopo il GC: %v", err)
	}
}

// D3: una generazione illeggibile blocca il GC senza cancellare niente.
func TestGCAbortsOnCorruptGeneration(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	for i := 0; i < 4; i++ {
		pushFiles(t, s, "v", "alex", i, map[string][]byte{"a": []byte(strings.Repeat("c", i+1))})
	}
	if err := os.WriteFile(s.genPath("v", 3), []byte("{rotto"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := s.GC("v", 1); err == nil {
		t.Fatal("GC con generazione corrotta non ha restituito errore")
	}
	if err := s.DeleteGeneration("v", 1); err == nil {
		t.Fatal("DeleteGeneration con generazione corrotta non ha restituito errore")
	}
	for i := 0; i < 4; i++ {
		if !s.HasBlob("v", hashBytes([]byte(strings.Repeat("c", i+1)))) {
			t.Fatalf("blob %d cancellato nonostante l'abort", i+1)
		}
	}
	if _, err := os.Stat(s.genPath("v", 1)); err != nil {
		t.Fatal("generazione eliminata nonostante l'abort")
	}
}

// D5: HEAD corrotto o puntato a una generazione mancante si ricostruisce.
func TestCorruptHeadRecovery(t *testing.T) {
	dir := t.TempDir()
	s, _ := Open(dir)
	s.CreateSpace("v", "generic", nil)
	for i := 0; i < 3; i++ {
		pushFiles(t, s, "v", "alex", i, map[string][]byte{"a": []byte(strings.Repeat("h", i+1))})
	}
	headPath := filepath.Join(s.spaceDir("v"), "HEAD")
	for _, garbage := range []string{"", "xx", "\x00\x00", "99"} {
		if err := os.WriteFile(headPath, []byte(garbage), 0o644); err != nil {
			t.Fatal(err)
		}
		s2, err := Open(dir)
		if err != nil {
			t.Fatalf("Open con HEAD %q: %v", garbage, err)
		}
		if h, _ := s2.Head("v"); h != 3 {
			t.Fatalf("HEAD %q ricostruito a %d, atteso 3", garbage, h)
		}
		if b, _ := os.ReadFile(headPath); string(b) != "3" {
			t.Fatalf("HEAD su disco non riscritto: %q", b)
		}
	}
	// ultima generazione illeggibile: si riparte dalla precedente valida
	os.WriteFile(s.genPath("v", 3), []byte("{"), 0o644)
	s3, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if h, _ := s3.Head("v"); h != 2 {
		t.Fatalf("HEAD = %d, atteso 2", h)
	}
}

// C3: il secondo commit dello stesso push restituisce lo stesso risultato.
func TestCommitIdempotent(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	files := map[string][]byte{"a": []byte("uno")}
	pid, missing, err := begin(s, "v", "alex", "m", 0, manifestOf(files), nil)
	if err != nil {
		t.Fatal(err)
	}
	s.PushBlob("v", pid, missing[0], bytes.NewReader(files["a"]), false)
	g1, replay, err := s.CommitPush("v", pid)
	if err != nil || replay {
		t.Fatalf("primo commit: %v replay=%v", err, replay)
	}
	g2, replay, err := s.CommitPush("v", pid)
	if err != nil || !replay {
		t.Fatalf("secondo commit: %v replay=%v", err, replay)
	}
	if g1.N != g2.N || g1.Stats != g2.Stats {
		t.Fatalf("risultati diversi: %+v vs %+v", g1, g2)
	}
	if h, _ := s.Head("v"); h != 1 {
		t.Fatalf("il replay ha creato un'altra generazione: HEAD=%d", h)
	}
	if _, _, err := s.CommitPush("v", "inesistente"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("push sconosciuto: %v", err)
	}
}

// C2/D13: il push è legato alla sessione di lock.
func TestPushLockBinding(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	files := map[string][]byte{"a": []byte("x")}
	man := manifestOf(files)
	push := func(author, session string) (string, error) {
		pid, _, err := s.BeginPush("v", PushOptions{Author: author, Parent: 0, Files: man, LockSession: session})
		return pid, err
	}
	var le *LockedError
	// senza lock
	if _, err := push("alex", ""); !errors.As(err, &le) {
		t.Fatalf("push senza lock: %v", err)
	}
	lk, _, err := s.AcquireLock("v", "alex", nil, 1)
	if err != nil {
		t.Fatal(err)
	}
	// sessione sbagliata o mancante, utente sbagliato
	for _, c := range []struct{ who, sess string }{{"alex", ""}, {"alex", "altra"}, {"steve", lk.Session}} {
		if _, err := push(c.who, c.sess); !errors.As(err, &le) {
			t.Fatalf("push %+v accettato: %v", c, err)
		}
	}
	pid, err := push("alex", lk.Session)
	if err != nil {
		t.Fatal(err)
	}
	s.PutBlob("v", hashBytes(files["a"]), bytes.NewReader(files["a"]), false)
	// il lock scade e steve lo prende: il commit del vecchio client va respinto
	time.Sleep(1100 * time.Millisecond)
	lk2, took, err := s.AcquireLock("v", "steve", nil, 90)
	if err != nil || took == nil {
		t.Fatalf("takeover: %v %v", took, err)
	}
	if _, _, err := s.CommitPush("v", pid); !errors.As(err, &le) {
		t.Fatalf("commit col lock perso accettato: %v", err)
	}
	if h, _ := s.Head("v"); h != 0 {
		t.Fatal("generazione scritta da chi aveva perso il lock")
	}
	// rilasciato il lock: il commit di un push legato fallisce anche così
	pid2, err := push("steve", lk2.Session)
	if err != nil {
		t.Fatal(err)
	}
	s.ReleaseLock("v", lk2.Session, false)
	if _, _, err := s.CommitPush("v", pid2); !errors.As(err, &le) {
		t.Fatalf("commit senza lock accettato: %v", err)
	}
	// NoLock (admin) passa anche senza lock
	if _, _, err := s.BeginPush("v", PushOptions{Author: "admin", Files: man, NoLock: true}); err != nil {
		t.Fatalf("nolock: %v", err)
	}
}

// C4: un push che elimina più della metà dei file di HEAD viene rifiutato.
func TestMassDeleteRejected(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	full := manyFiles(30, "m")
	pushFiles(t, s, "v", "alex", 0, full)
	// ne restano 10 su 30: −20 > 50%
	few := map[string][]byte{}
	for p, b := range full {
		if len(few) == 10 {
			break
		}
		few[p] = b
	}
	_, _, err := begin(s, "v", "alex", "m", 1, manifestOf(few), nil)
	var md *MassDeleteError
	if !errors.As(err, &md) || md.Removed != 20 || md.Total != 30 || !errors.Is(err, ErrConflict) {
		t.Fatalf("mass delete non rifiutato: %v", err)
	}
	// metà esatta: permesso
	half := map[string][]byte{}
	for p, b := range full {
		if len(half) == 15 {
			break
		}
		half[p] = b
	}
	if _, _, err := begin(s, "v", "alex", "m", 1, manifestOf(half), nil); err != nil {
		t.Fatalf("rimozione del 50%% rifiutata: %v", err)
	}
	// admin con allowMassDelete
	if _, _, err := s.BeginPush("v", PushOptions{Author: "a", Parent: 1, Files: Manifest{}, NoLock: true, AllowMassDelete: true}); err != nil {
		t.Fatalf("allowMassDelete: %v", err)
	}
	// HEAD piccolo (<20 file): nessun blocco
	s.CreateSpace("w", "generic", nil)
	pushFiles(t, s, "w", "alex", 0, manyFiles(10, "w"))
	if _, _, err := begin(s, "w", "alex", "m", 1, Manifest{}, nil); err != nil {
		t.Fatalf("HEAD piccolo bloccato: %v", err)
	}
}

// setGenTime riscrive il timestamp di una generazione su disco.
func setGenTime(t *testing.T, s *Store, id string, n int, ts time.Time) {
	t.Helper()
	g, err := s.loadGen(id, n)
	if err != nil {
		t.Fatal(err)
	}
	g.TS = ts
	if err := writeJSON(s.genPath(id, n), g); err != nil {
		t.Fatal(err)
	}
	st, _ := s.space(id)
	st.mu.Lock()
	delete(st.genTS, n)
	st.mu.Unlock()
}

// C4/S2: la retention automatica non tocca mai le generazioni < 24h, anche
// dopo una raffica di push vuoti.
func TestRetentionNeverDropsRecent(t *testing.T) {
	s := newStore(t)
	s.KeepLast = 3
	s.CreateSpace("v", "minecraft", nil)
	pushFiles(t, s, "v", "alex", 0, map[string][]byte{"mondo": []byte("prezioso")})
	for i := 1; i <= 30; i++ {
		st, _ := s.space("v")
		st.mu.Lock()
		st.lastRetention = time.Time{} // niente throttle nel test
		st.mu.Unlock()
		pushFiles(t, s, "v", "vandalo", i, map[string][]byte{})
	}
	gens, err := s.Generations("v", 0)
	if err != nil || len(gens) != 31 {
		t.Fatalf("retention ha cancellato generazioni recenti: %d (%v)", len(gens), err)
	}
	if !s.HasBlob("v", hashBytes([]byte("prezioso"))) {
		t.Fatal("blob del mondo cancellato")
	}
}

// C4: oltre le 24h si tengono le ultime KeepLast e una per giorno (7 giorni).
func TestRetentionDailyKeep(t *testing.T) {
	s := newStore(t)
	s.KeepLast = 2
	s.CreateSpace("v", "generic", nil)
	for i := 0; i < 8; i++ {
		pushFiles(t, s, "v", "alex", i, map[string][]byte{"a": []byte(strings.Repeat("d", i+1))})
	}
	now := time.Now()
	day := func(d, h int) time.Time {
		l := now.In(time.Local)
		return time.Date(l.Year(), l.Month(), l.Day()-d, h, 0, 0, 0, time.Local)
	}
	// 1,2: 20 giorni fa; 3,4: 3 giorni fa (stesso giorno); 5: 2 giorni fa;
	// 6: ieri; 7,8: adesso (KeepLast e < 24h)
	setGenTime(t, s, "v", 1, day(20, 10))
	setGenTime(t, s, "v", 2, day(20, 11))
	setGenTime(t, s, "v", 3, day(3, 9))
	setGenTime(t, s, "v", 4, day(3, 18))
	setGenTime(t, s, "v", 5, day(2, 12))
	setGenTime(t, s, "v", 6, day(1, 12))
	st, _ := s.space("v")
	st.mu.Lock()
	_, err := s.retentionLocked("v", st, now)
	st.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	ns, _ := s.genNumbers("v")
	got := fmt.Sprint(ns)
	if got != "[4 5 6 7 8]" {
		t.Fatalf("generazioni rimaste %s, attese [4 5 6 7 8]", got)
	}
}

// R17 + tetto: le sessioni scadono dall'ultima attività; al massimo
// maxPushesPerUser aperte per utente.
func TestPushSessionsExpiryAndCap(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	files := map[string][]byte{"a": []byte("blob")}
	var pids []string
	for i := 0; i < maxPushesPerUser+2; i++ {
		pid, _, err := begin(s, "v", "alex", "m", 0, manifestOf(files), nil)
		if err != nil {
			t.Fatal(err)
		}
		pids = append(pids, pid)
	}
	st, _ := s.space("v")
	st.mu.Lock()
	n := len(st.pushes)
	_, firstAlive := st.pushes[pids[0]]
	// sessione creata 3h fa ma attiva adesso: non deve scadere
	last := st.pushes[pids[len(pids)-1]]
	last.Created = time.Now().Add(-3 * time.Hour)
	st.mu.Unlock()
	if n != maxPushesPerUser || firstAlive {
		t.Fatalf("sessioni aperte %d (prima viva=%v), atteso tetto %d", n, firstAlive, maxPushesPerUser)
	}
	if _, err := s.PushBlob("v", last.ID, hashBytes(files["a"]), bytes.NewReader(files["a"]), false); err != nil {
		t.Fatal(err)
	}
	// un blob estraneo al manifest è rifiutato
	if _, err := s.PushBlob("v", last.ID, hashBytes([]byte("altro")), strings.NewReader("altro"), false); !errors.Is(err, ErrBadRequest) {
		t.Fatalf("blob estraneo accettato: %v", err)
	}
	st.mu.Lock()
	st.expirePushesLocked(time.Now())
	_, alive := st.pushes[last.ID]
	st.mu.Unlock()
	if !alive {
		t.Fatal("sessione attiva scaduta per età di creazione")
	}
	if _, err := commit(s, "v", last.ID); err != nil {
		t.Fatal(err)
	}
}

// Restore/RestoreFile: il controllo del lock è nello store.
func TestRestoreRefusedWhileLocked(t *testing.T) {
	s := newStore(t)
	s.CreateSpace("v", "generic", nil)
	pushFiles(t, s, "v", "alex", 0, map[string][]byte{"a": []byte("1")})
	pushFiles(t, s, "v", "alex", 1, map[string][]byte{"a": []byte("2")})
	s.AcquireLock("v", "steve", nil, 90)
	var le *LockedError
	if _, err := s.Restore("v", 1, "alex"); !errors.As(err, &le) {
		t.Fatalf("restore durante una sessione: %v", err)
	}
	if _, err := s.RestoreFile("v", "a", 1, "alex"); !errors.As(err, &le) {
		t.Fatalf("restore-file durante una sessione: %v", err)
	}
}

// D15: DeleteSpace mentre un upload è in corso non lascia directory zombie,
// e Open salta le directory senza space.json.
func TestDeleteSpaceAndRobustOpen(t *testing.T) {
	dir := t.TempDir()
	s, _ := Open(dir)
	s.CreateSpace("v", "generic", nil)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			b := []byte(fmt.Sprintf("blob-%d", i))
			s.PutBlob("v", hashBytes(b), bytes.NewReader(b), false)
		}(i)
	}
	if err := s.DeleteSpace("v"); err != nil {
		t.Fatal(err)
	}
	wg.Wait()
	if _, err := os.Stat(filepath.Join(dir, "spaces", "v")); !os.IsNotExist(err) {
		t.Fatalf("directory dello spazio ricreata: %v", err)
	}
	os.MkdirAll(filepath.Join(dir, "spaces", "orfana", "blobs"), 0o755)
	os.MkdirAll(filepath.Join(dir, "spaces", ".deleted-x-1"), 0o755)
	s2, err := Open(dir)
	if err != nil {
		t.Fatalf("Open con directory senza space.json: %v", err)
	}
	if len(s2.ListSpaces()) != 0 {
		t.Fatal("directory orfana caricata come spazio")
	}
	if _, err := os.Stat(filepath.Join(dir, "spaces", ".deleted-x-1")); !os.IsNotExist(err) {
		t.Fatal("eliminazione interrotta non completata")
	}
}

// writeAtomic: un errore di scrittura non tocca la destinazione.
func TestWriteAtomicKeepsOldOnError(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "f")
	writeFileAtomic(p, []byte("vecchio"))
	err := writeAtomic(p, func(w io.Writer) error {
		w.Write([]byte("mezzo"))
		return errors.New("boom")
	})
	if err == nil {
		t.Fatal("errore perso")
	}
	if b, _ := os.ReadFile(p); string(b) != "vecchio" {
		t.Fatalf("destinazione toccata: %q", b)
	}
	if ents, _ := os.ReadDir(dir); len(ents) != 1 {
		t.Fatalf("temporanei rimasti: %d voci", len(ents))
	}
}
