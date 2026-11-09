package syncx

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"minesync/client/internal/api"
)

// h64 ripete s fino a formare un hash esadecimale valido (64 caratteri).
func h64(s string) string { return strings.Repeat(s, 64/len(s)) }

// Uno spazio appena creato è alla generazione #0 e non ha nessun file. Se la
// cartella locale è già piena (caso tipico: si collega la cartella del server
// esistente per caricarla), il pull allineerebbe il locale al remoto vuoto,
// cioè cancellerebbe tutto. Deve rifiutarsi e non toccare niente: senza base
// nota è un DirtyLocalError NON divergente (l'hub è vuoto, basta pushare);
// anche chiedendo di scartare il locale, il pull verso un hub vuoto resta
// vietato (ErrEmptyRemote).
func TestPullRifiutaHubVuoto(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"gen":0,"head":0,"files":{}}`))
	}))
	defer srv.Close()

	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "mods"), 0o755)
	files := []string{"start.sh", "server.properties", "mods/cobblemon.jar"}
	for _, f := range files {
		if err := os.WriteFile(filepath.Join(dir, f), []byte("contenuto di "+f), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	eng := &Engine{
		Client: api.New(srv.URL), SpaceID: "cobbleverse", LocalPath: dir,
		CachePath: filepath.Join(t.TempDir(), "cache.json"), Matcher: NewMatcher(nil),
	}
	_, err := eng.Pull(context.Background())
	var dirty *DirtyLocalError
	if !errors.As(err, &dirty) || dirty.Diverged() {
		t.Fatalf("Pull su hub vuoto: errore = %v, atteso DirtyLocalError non divergente", err)
	}
	eng.DiscardLocal = true
	if _, err := eng.Pull(context.Background()); !errors.Is(err, ErrEmptyRemote) {
		t.Fatalf("Pull su hub vuoto con DiscardLocal: errore = %v, atteso ErrEmptyRemote", err)
	}
	for _, f := range files {
		if _, err := os.Stat(filepath.Join(dir, f)); err != nil {
			t.Errorf("%s è stato cancellato: %v", f, err)
		}
	}
}

// Il caso legittimo opposto: cartella locale vuota e hub vuoto. Non c'è niente
// da cancellare, quindi il pull passa senza errori.
func TestPullHubVuotoCartellaVuota(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"gen":0,"head":0,"files":{}}`))
	}))
	defer srv.Close()

	eng := &Engine{
		Client: api.New(srv.URL), SpaceID: "nuovo", LocalPath: t.TempDir(),
		CachePath: filepath.Join(t.TempDir(), "cache.json"), Matcher: NewMatcher(nil),
	}
	if _, err := eng.Pull(context.Background()); err != nil {
		t.Fatalf("Pull su cartella vuota: errore inatteso %v", err)
	}
}

// Il caso speculare: la cartella locale è vuota (disco esterno non montato,
// spazio collegato alla cartella sbagliata) ma sull'hub c'è tutto. Pushare
// significherebbe cancellare il mondo per tutti.
func TestPushRifiutaCancellazioneDiMassa(t *testing.T) {
	remoto := `{"gen":42,"head":42,"files":{
		"start.sh":{"h":"` + h64("a") + `","s":10},
		"server.properties":{"h":"` + h64("b") + `","s":10},
		"mods/a.jar":{"h":"` + h64("c") + `","s":10},
		"world/level.dat":{"h":"` + h64("d") + `","s":10}}}`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "/manifest") {
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(remoto))
			return
		}
		t.Errorf("il push non doveva nemmeno iniziare: chiamato %s", r.URL.Path)
		http.Error(w, "no", http.StatusInternalServerError)
	}))
	defer srv.Close()

	eng := &Engine{
		Client: api.New(srv.URL), SpaceID: "cobbleverse", LocalPath: t.TempDir(),
		CachePath: filepath.Join(t.TempDir(), "c.json"), Matcher: NewMatcher(nil),
	}
	_, err := eng.Push(context.Background(), "push", true)
	if !errors.Is(err, ErrMassDelete) {
		t.Fatalf("Push da cartella vuota: errore = %v, atteso ErrMassDelete", err)
	}
}

// Un collegamento a CARTELLA nasconde tutto il sottoalbero alla scansione:
// ignorarlo in silenzio significa che il push successivo lo toglie dal
// manifest, cioè lo cancella per tutti.
func TestScanRifiutaSymlinkACartella(t *testing.T) {
	dir := t.TempDir()
	bersaglio := filepath.Join(t.TempDir(), "vero")
	os.MkdirAll(bersaglio, 0o755)
	os.WriteFile(filepath.Join(bersaglio, "level.dat"), []byte("dati"), 0o644)
	if err := os.Symlink(bersaglio, filepath.Join(dir, "world")); err != nil {
		t.Skip("symlink non supportati qui:", err)
	}
	if _, _, err := Scan(dir, NewMatcher(nil), Cache{}, nil); err == nil {
		t.Fatal("lo scan ha ignorato un collegamento a cartella invece di segnalarlo")
	}
}

// I collegamenti a FILE invece sono normalissimi: un JDK incluso nel modpack
// ne ha un centinaio per deduplicare le licenze. Vanno seguiti, non rifiutati.
func TestScanSegueSymlinkAFile(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "legal", "java.base"), 0o755)
	os.MkdirAll(filepath.Join(dir, "legal", "java.compiler"), 0o755)
	vero := filepath.Join(dir, "legal", "java.base", "LICENSE")
	os.WriteFile(vero, []byte("testo della licenza"), 0o644)
	if err := os.Symlink("../java.base/LICENSE", filepath.Join(dir, "legal", "java.compiler", "LICENSE")); err != nil {
		t.Skip("symlink non supportati qui:", err)
	}
	man, _, err := Scan(dir, NewMatcher(nil), Cache{}, nil)
	if err != nil {
		t.Fatalf("un JDK incluso nel pack blocca la sincronizzazione: %v", err)
	}
	link, ok := man["legal/java.compiler/LICENSE"]
	if !ok {
		t.Fatal("il file puntato dal collegamento non è finito nel manifest")
	}
	if link.Hash != man["legal/java.base/LICENSE"].Hash || link.Size != 19 {
		t.Errorf("contenuto del collegamento non risolto: %+v", link)
	}
}

// Un collegamento rotto non ha contenuto: si salta, senza far fallire tutto.
func TestScanSaltaSymlinkRotto(t *testing.T) {
	dir := t.TempDir()
	if err := os.Symlink("/non/esiste/da/nessuna/parte", filepath.Join(dir, "orfano")); err != nil {
		t.Skip("symlink non supportati qui:", err)
	}
	os.WriteFile(filepath.Join(dir, "vero.txt"), []byte("x"), 0o644)
	man, _, err := Scan(dir, NewMatcher(nil), Cache{}, nil)
	if err != nil {
		t.Fatalf("un collegamento rotto ha bloccato la scansione: %v", err)
	}
	if _, ok := man["vero.txt"]; !ok || len(man) != 1 {
		t.Errorf("manifest inatteso: %v", man)
	}
}

// Cambiare solo il bit di esecuzione deve produrre un push e, dall'altra
// parte, un chmod senza riscaricare niente.
func TestExecBitEntraNelConfronto(t *testing.T) {
	a := api.Manifest{"start.sh": {Hash: "h", Size: 3, Exec: true}}
	b := api.Manifest{"start.sh": {Hash: "h", Size: 3, Exec: false}}
	if manifestsEqual(a, b) {
		t.Error("manifest con bit exec diverso considerati uguali: il push non partirebbe mai")
	}
}

// Le cartelle escluse non vanno potate: certi mod di backup non ricreano la
// propria directory se sparisce.
func TestPotaturaRispettaLeEsclusioni(t *testing.T) {
	root := t.TempDir()
	os.MkdirAll(filepath.Join(root, "backups"), 0o755)
	os.MkdirAll(filepath.Join(root, "config", "vuota"), 0o755)
	pruneEmptyDirsOf(root, []string{"backups/x.zip", "config/vuota/y.toml"}, NewMatcher([]string{"backups/**"}))
	if _, err := os.Stat(filepath.Join(root, "backups")); err != nil {
		t.Error("la cartella esclusa backups/ è stata cancellata")
	}
	if _, err := os.Stat(filepath.Join(root, "config", "vuota")); err == nil {
		t.Error("la cartella vuota gestita non è stata potata")
	}
}

// Se qualcun altro ha giocato dopo il nostro ultimo pull, il nostro albero non
// discende da HEAD: pushare lo riporterebbe indietro cancellando la sua serata.
func TestPushRifiutaBaseVecchia(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "/manifest") {
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"gen":50,"head":50,"files":{"world/level.dat":{"h":"` + h64("e") + `","s":4}}}`))
			return
		}
		t.Errorf("il push non doveva iniziare: %s", r.URL.Path)
	}))
	defer srv.Close()

	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "world"), 0o755)
	os.WriteFile(filepath.Join(dir, "world", "level.dat"), []byte("miei"), 0o644)
	cachePath := filepath.Join(t.TempDir(), "c.json")
	// la nostra cache dice: fermi alla generazione 30
	SaveCacheMeta(cachePath, Cache{}, CacheMeta{Root: dir, Gen: 30})

	eng := &Engine{
		Client: api.New(srv.URL), SpaceID: "sp", LocalPath: dir,
		CachePath: cachePath, Matcher: NewMatcher(nil),
	}
	_, err := eng.Push(context.Background(), "push", true)
	if !errors.Is(err, ErrStaleBase) {
		t.Fatalf("errore = %v, atteso ErrStaleBase", err)
	}
}

// La cache di un'ALTRA cartella non va riusata: gli hash vecchi verrebbero
// creduti buoni e il manifest dichiarerebbe contenuti inesistenti.
func TestCacheDiAltraCartellaScartata(t *testing.T) {
	p := filepath.Join(t.TempDir(), "c.json")
	SaveCacheMeta(p, Cache{"a.txt": {Size: 1, Hash: "h"}}, CacheMeta{Root: "/casa/vecchia", Gen: 7})
	if c, _ := LoadCacheMeta(p, "/casa/nuova"); len(c) != 0 {
		t.Error("cache di un'altra cartella riusata")
	}
	c, meta := LoadCacheMeta(p, "/casa/vecchia")
	if len(c) != 1 || meta.Gen != 7 {
		t.Errorf("cache della cartella giusta non riletta: %d voci, gen %d", len(c), meta.Gen)
	}
}
