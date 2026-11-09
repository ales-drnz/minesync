package syncx

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"minesync/client/internal/api"
	"minesync/client/internal/syncx/fakehub"
)

func init() { retryBackoff = 5 * time.Millisecond }

// newTestEngine prepara un engine verso il finto hub, con la cartella dello
// spazio in <tmp>/mondo (così il backup finisce in <tmp>/.minesync-backup).
func newTestEngine(t *testing.T, hub *fakehub.Hub) *Engine {
	t.Helper()
	root := t.TempDir()
	local := filepath.Join(root, "mondo")
	if err := os.MkdirAll(local, 0o755); err != nil {
		t.Fatal(err)
	}
	return &Engine{
		Client: api.New(hub.URL()), SpaceID: "sp", LocalPath: local,
		CachePath: filepath.Join(t.TempDir(), "sp.json"), Matcher: NewMatcher(nil),
	}
}

func writeLocal(t *testing.T, e *Engine, rel, content string) {
	t.Helper()
	p := filepath.Join(e.LocalPath, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func readLocal(t *testing.T, e *Engine, rel string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(e.LocalPath, filepath.FromSlash(rel)))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func checkHeaders(t *testing.T, hub *fakehub.Hub) {
	t.Helper()
	hub.Lock()
	defer hub.Unlock()
	if hub.MissingHeader > 0 {
		t.Errorf("%d richieste senza header X-MineSync", hub.MissingHeader)
	}
}

// D1: modifiche locali + push fallito + pull successivo. Il pull NON deve
// rimettere la versione vecchia dell'hub: rifiuta con DirtyLocalError non
// divergente, e il percorso della sessione (push, poi pull) porta le
// modifiche sull'hub.
func TestModificheLocaliPushFallitoPoiPull(t *testing.T) {
	hub := fakehub.New()
	defer hub.Close()
	hub.Commit(map[string][]byte{"world/level.dat": []byte("v1"), "server.properties": []byte("porta")})
	eng := newTestEngine(t, hub)
	ctx := context.Background()
	if _, err := eng.Pull(ctx); err != nil {
		t.Fatal(err)
	}

	writeLocal(t, eng, "world/level.dat", "serata di gioco")
	writeLocal(t, eng, "world/nuovo.dat", "chunk nuovi")
	hub.Lock()
	hub.FailPushBegin = true
	hub.Unlock()
	if _, err := eng.Push(ctx, "stop", false); err == nil {
		t.Fatal("il push doveva fallire")
	}
	hub.Lock()
	hub.FailPushBegin = false
	hub.Unlock()

	_, err := eng.Pull(ctx)
	var dirty *DirtyLocalError
	if !errors.As(err, &dirty) {
		t.Fatalf("pull dopo push fallito: errore = %v, atteso DirtyLocalError", err)
	}
	if dirty.Diverged() || dirty.BaseGen != 1 || dirty.HubHead != 1 {
		t.Fatalf("DirtyLocalError inatteso: %+v (diverged=%v)", dirty, dirty.Diverged())
	}
	if len(dirty.Changed) != 2 || len(dirty.Removed) != 0 {
		t.Errorf("modifiche rilevate: %+v", dirty)
	}
	if got := readLocal(t, eng, "world/level.dat"); got != "serata di gioco" {
		t.Fatalf("il pull ha sovrascritto la modifica locale: %q", got)
	}

	// percorso della sessione: fast-forward (push), poi pull
	res, err := eng.Push(ctx, "modifiche locali", false)
	if err != nil {
		t.Fatalf("push fast-forward: %v", err)
	}
	if res.Gen.N != 2 {
		t.Errorf("generazione %d, attesa 2", res.Gen.N)
	}
	if _, err := eng.Pull(ctx); err != nil {
		t.Fatalf("pull dopo il fast-forward: %v", err)
	}
	if got := string(hub.Files(2)["world/level.dat"]); got != "serata di gioco" {
		t.Errorf("sull'hub c'è %q", got)
	}
	checkHeaders(t, hub)
}

// D1 divergente: nel frattempo qualcun altro ha pushato. Il pull rifiuta
// (Diverged); con DiscardLocal scarta le modifiche locali ma prima le copia
// nel backup accanto alla cartella dello spazio.
func TestDivergenteDiscardLocalFaIlBackup(t *testing.T) {
	hub := fakehub.New()
	defer hub.Close()
	hub.Commit(map[string][]byte{"a.txt": []byte("base"), "b.txt": []byte("b"), "c.txt": []byte("c")})
	eng := newTestEngine(t, hub)
	ctx := context.Background()
	if _, err := eng.Pull(ctx); err != nil {
		t.Fatal(err)
	}
	writeLocal(t, eng, "a.txt", "mia modifica")
	os.Remove(filepath.Join(eng.LocalPath, "c.txt"))
	hub.Commit(map[string][]byte{"a.txt": []byte("modifica di un altro"), "b.txt": []byte("b"), "c.txt": []byte("c")})

	_, err := eng.Pull(ctx)
	var dirty *DirtyLocalError
	if !errors.As(err, &dirty) || !dirty.Diverged() {
		t.Fatalf("errore = %v, atteso DirtyLocalError divergente", err)
	}
	if dirty.BaseGen != 1 || dirty.HubHead != 2 || len(dirty.Changed) != 1 || len(dirty.Removed) != 1 {
		t.Errorf("DirtyLocalError inatteso: %+v", dirty)
	}
	if !errors.Is(err, ErrDirtyLocal) {
		t.Error("errors.Is(err, ErrDirtyLocal) = false")
	}

	eng.DiscardLocal = true
	plan, err := eng.Pull(ctx)
	if err != nil {
		t.Fatalf("pull con DiscardLocal: %v", err)
	}
	if got := readLocal(t, eng, "a.txt"); got != "modifica di un altro" {
		t.Errorf("a.txt = %q dopo lo scarto", got)
	}
	if plan.Backup == "" {
		t.Fatal("nessun backup creato")
	}
	if filepath.Dir(plan.Backup) != BackupRoot(eng.LocalPath) ||
		filepath.Dir(BackupRoot(eng.LocalPath)) != filepath.Dir(eng.LocalPath) {
		t.Errorf("backup in posizione inattesa: %s", plan.Backup)
	}
	b, err := os.ReadFile(filepath.Join(plan.Backup, "a.txt"))
	if err != nil || string(b) != "mia modifica" {
		t.Errorf("backup di a.txt = %q, %v", b, err)
	}
	checkHeaders(t, hub)
}

// D8: un primo pull interrotto lascia la cartella a metà. Un push da lì
// cancellerebbe sull'hub tutto ciò che non è ancora stato scaricato: va
// rifiutato. Ripetere il pull invece è lecito e completa il lavoro.
func TestPullInterrottoPoiPushRifiutato(t *testing.T) {
	hub := fakehub.New()
	defer hub.Close()
	files := map[string][]byte{}
	for _, n := range []string{"a", "b", "c", "d", "e"} {
		files["world/"+n+".dat"] = []byte("contenuto " + n)
	}
	hub.Commit(files)
	hub.Lock()
	hub.FailBlobs[fakehub.Hash(files["world/e.dat"])] = true
	hub.Unlock()

	eng := newTestEngine(t, hub)
	ctx := context.Background()
	if _, err := eng.Pull(ctx); err == nil {
		t.Fatal("il pull doveva fallire")
	}
	if _, err := eng.Push(ctx, "push manuale", true); !errors.Is(err, ErrStaleBase) {
		t.Fatalf("push dopo pull interrotto: errore = %v, atteso ErrStaleBase", err)
	}
	if hub.Head() != 1 {
		t.Fatalf("l'hub è stato modificato: HEAD %d", hub.Head())
	}

	// cache persa: base ignota con hub non vuoto → stesso rifiuto
	os.Remove(eng.CachePath)
	if _, err := eng.Push(ctx, "push manuale", true); !errors.Is(err, ErrStaleBase) {
		t.Fatalf("push con cache persa: errore = %v, atteso ErrStaleBase", err)
	}
	hub.Lock()
	begins := hub.PushBegins
	hub.FailBlobs = map[string]bool{}
	hub.Unlock()
	if begins != 0 {
		t.Errorf("push/begin chiamato %d volte", begins)
	}

	// il pull si può ripetere e completa il checkout
	if _, err := eng.Pull(ctx); err != nil {
		t.Fatalf("ripetizione del pull: %v", err)
	}
	if got := readLocal(t, eng, "world/e.dat"); got != "contenuto e" {
		t.Errorf("e.dat = %q", got)
	}
	if res, err := eng.Push(ctx, "push", true); err != nil || !res.NoChange {
		t.Errorf("push dopo pull completo: %+v, %v", res, err)
	}
}

// S6: percorsi e hash del manifest vanno validati prima di toccare il disco.
func TestManifestMalevoloRifiutato(t *testing.T) {
	good := fakehub.Hash([]byte("x"))
	cases := []struct {
		name string
		m    api.Manifest
	}{
		{"risalita", api.Manifest{"../x": {Hash: good, Size: 1}}},
		{"risalita profonda", api.Manifest{"a/../../x": {Hash: good, Size: 1}}},
		{"assoluto", api.Manifest{"/etc/x": {Hash: good, Size: 1}}},
		{"unità windows", api.Manifest{"C:/x": {Hash: good, Size: 1}}},
		{"backslash", api.Manifest{"a\\b": {Hash: good, Size: 1}}},
		{"vuoto", api.Manifest{"": {Hash: good, Size: 1}}},
		{"hash corto", api.Manifest{"ok.txt": {Hash: "abc", Size: 1}}},
		{"hash maiuscolo", api.Manifest{"ok.txt": {Hash: "A" + good[1:], Size: 1}}},
		{"chunk corto", api.Manifest{"ok.txt": {Hash: good, Size: 1, Chunks: []api.Chunk{{Hash: "12", Size: 1}}}}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			hub := fakehub.New()
			defer hub.Close()
			hub.Commit(map[string][]byte{"x": []byte("x")}) // il blob esiste davvero
			hub.SetRawManifest(c.m)
			eng := newTestEngine(t, hub)
			parent := filepath.Dir(eng.LocalPath)
			if _, err := eng.Pull(context.Background()); !errors.Is(err, ErrBadManifest) {
				t.Fatalf("pull: errore = %v, atteso ErrBadManifest", err)
			}
			if _, err := eng.Prefetch(context.Background(), nil); !errors.Is(err, ErrBadManifest) {
				t.Fatalf("prefetch: errore = %v, atteso ErrBadManifest", err)
			}
			entries, _ := os.ReadDir(parent)
			if len(entries) != 1 || entries[0].Name() != "mondo" {
				t.Errorf("scritto fuori dalla cartella dello spazio: %v", entries)
			}
			if inside, _ := os.ReadDir(eng.LocalPath); len(inside) != 0 {
				t.Errorf("scritto dentro la cartella nonostante il manifest invalido: %v", inside)
			}
		})
	}
}

// D9/C3: il commit riesce ma la risposta si perde. Il client ritenta lo
// stesso pushId e ottiene la stessa generazione, senza crearne una seconda;
// la base locale avanza e il push successivo non trova niente da fare.
func TestCommitRitentatoDopoRispostaPersa(t *testing.T) {
	for _, oldHub := range []bool{false, true} {
		name := "idempotente"
		if oldHub {
			name = "hub vecchio"
		}
		t.Run(name, func(t *testing.T) {
			hub := fakehub.New()
			defer hub.Close()
			hub.Commit(map[string][]byte{"a.txt": []byte("1")})
			eng := newTestEngine(t, hub)
			eng.LockSession = "sessione-di-prova"
			ctx := context.Background()
			if _, err := eng.Pull(ctx); err != nil {
				t.Fatal(err)
			}
			writeLocal(t, eng, "a.txt", "2")
			hub.Lock()
			hub.DropCommitResponses = 1
			hub.NonIdempotentCommit = oldHub
			hub.Unlock()
			res, err := eng.Push(ctx, "autosave", false)
			if err != nil {
				t.Fatalf("push con risposta persa: %v", err)
			}
			if res.Gen.N != 2 || hub.Head() != 2 {
				t.Fatalf("generazione %d, HEAD hub %d: attese entrambe 2", res.Gen.N, hub.Head())
			}
			hub.Lock()
			commits, sess := hub.Commits, hub.LastSession
			hub.Unlock()
			if commits != 1 {
				t.Errorf("%d commit effettivi, atteso 1", commits)
			}
			if sess != "sessione-di-prova" {
				t.Errorf("sessione del lock non passata al push: %q", sess)
			}
			res, err = eng.Push(ctx, "autosave", false)
			if err != nil || !res.NoChange {
				t.Errorf("push successivo: %+v, %v (la base non è avanzata?)", res, err)
			}
		})
	}
}

// R1: un download che si ferma a metà viene interrotto dal watchdog di
// progresso invece di bloccare il pull per sempre.
func TestWatchdogInterrompeDownloadFermo(t *testing.T) {
	hub := fakehub.New()
	defer hub.Close()
	hub.Commit(map[string][]byte{"a.txt": []byte("contenuto abbastanza lungo")})
	hub.Lock()
	hub.StallBlobs = true
	hub.Unlock()
	eng := newTestEngine(t, hub)
	eng.Client.IdleTimeout = 50 * time.Millisecond
	start := time.Now()
	_, err := eng.Pull(context.Background())
	if !errors.Is(err, api.ErrStalled) {
		t.Fatalf("errore = %v, atteso ErrStalled", err)
	}
	if el := time.Since(start); el > 5*time.Second {
		t.Errorf("il watchdog ci ha messo %s", el)
	}
}
