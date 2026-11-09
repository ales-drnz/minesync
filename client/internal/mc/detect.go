// Package mc: integrazione Minecraft lato client (detect, java, processo).
package mc

import (
	"archive/zip"
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"

	"minesync/client/internal/i18n"
)

// ServerInfo è la fotografia di una cartella server.
type ServerInfo struct {
	Dir         string
	StartScript string   // percorso assoluto dello script, "" se non c'è
	Launch      []string // comando effettivo di avvio, vuoto se non si sa come partire
	LaunchNote  string   // come si è arrivati a Launch, per l'utente
	Scripts     []string // tutti gli script candidati trovati
	Loader      string   // forge | neoforge | fabric | quilt | vanilla | ?
	Version     string   // versione del loader, best-effort
	MCVersion   string   // versione di Minecraft (es. 1.20.1), best-effort
	JavaMajor   int      // Java richiesto dichiarato dal server jar (0 = ignoto)
	Port        string
	MOTD        string
}

// stem degli script di avvio realmente usati nei server pack in circolazione.
// Il confronto è case-insensitive: su Linux esistono davvero ServerStart.sh,
// StartServer.sh e START.SH.
var scriptStems = []string{
	"serverstart", "server-start", "server_start", "startserver", "start-server", "start_server",
	"launchserver", "launch-server", "run", "run_server", "runserver", "start", "launch", "server",
}

// rootListing è il contenuto della radice del server, letto UNA volta e
// condiviso da tutti i passaggi del rilevamento (script, jar, loader, versioni).
type rootListing struct {
	dir   string
	files []string // nomi dei file (non cartelle), in ordine alfabetico
}

func listRoot(dir string) rootListing {
	l := rootListing{dir: dir}
	entries, _ := os.ReadDir(dir) // già in ordine di nome
	for _, e := range entries {
		if !e.IsDir() {
			l.files = append(l.files, e.Name())
		}
	}
	return l
}

// has riporta se in radice c'è un file con esattamente questo nome.
func (l rootListing) has(name string) bool {
	for _, n := range l.files {
		if n == name {
			return true
		}
	}
	return false
}

// jars elenca i jar in radice, esclusi gli installer.
func (l rootListing) jars() []string {
	var out []string
	for _, n := range l.files {
		low := strings.ToLower(n)
		if strings.HasSuffix(low, ".jar") && !strings.Contains(low, "installer") {
			out = append(out, n)
		}
	}
	return out
}

// Inspect fotografa una cartella server Minecraft. Legge soltanto: non esegue
// nulla della cartella (vedi il modello di fiducia in java.go).
func Inspect(dir string) ServerInfo {
	dir = descendToServerRoot(dir)
	ls := listRoot(dir)
	info := ServerInfo{Dir: dir}
	info.Scripts = findStartScripts(ls)
	info.StartScript = pickStartScript(info.Scripts)
	info.Loader = detectLoader(ls)
	info.Version = loaderVersionFromJars(ls)
	info.MCVersion = detectMCVersion(ls, info.Loader)
	if v, major := versionFromServerJar(dir); v != "" {
		// version.json dentro il server jar è la fonte autorevole: la scrive
		// Mojang e include il Java richiesto, niente tabelle da mantenere
		info.MCVersion, info.JavaMajor = v, major
	}
	if info.MCVersion == "" {
		info.MCVersion = versionFromPackManifest(dir)
	}
	info.Launch, info.LaunchNote = buildLaunch(ls, info.StartScript)
	if f, err := os.Open(filepath.Join(dir, "server.properties")); err == nil {
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := sc.Text()
			if v, ok := strings.CutPrefix(line, "server-port="); ok {
				info.Port = strings.TrimSpace(v)
			}
			if v, ok := strings.CutPrefix(line, "motd="); ok {
				info.MOTD = strings.TrimSpace(v)
			}
		}
		f.Close()
	}
	return info
}

// descendToServerRoot scende di un livello quando il server sta dentro una
// sottocartella. Gli zip dei server pack contengono quasi sempre una cartella
// che avvolge tutto ("Modpack-Server/…"): estratto così com'è, in radice non c'è
// niente e MineSync non trovava nulla da avviare.
func descendToServerRoot(dir string) string {
	if isServerRoot(dir) {
		return dir
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return dir
	}
	var subs []string
	for _, e := range entries {
		if e.IsDir() && !strings.HasPrefix(e.Name(), ".") {
			subs = append(subs, e.Name())
		} else if !e.IsDir() {
			return dir // ci sono file in radice: è questa la cartella buona
		}
	}
	if len(subs) != 1 {
		return dir // ambiguo: meglio non indovinare
	}
	if cand := filepath.Join(dir, subs[0]); isServerRoot(cand) {
		return cand
	}
	return dir
}

// isServerRoot: la cartella contiene qualcosa che identifica un server.
func isServerRoot(dir string) bool {
	for _, marker := range []string{"server.properties", "eula.txt", "mods", "world", "libraries"} {
		if _, err := os.Stat(filepath.Join(dir, marker)); err == nil {
			return true
		}
	}
	ls := listRoot(dir)
	return len(findStartScripts(ls)) > 0 || findLauncherJar(ls) != ""
}

// findStartScripts elenca gli script di avvio presenti, in ordine di
// preferenza. Confronto case-insensitive sulla lettura condivisa della cartella.
func findStartScripts(ls rootListing) []string {
	exts := []string{".sh"}
	if runtime.GOOS == "windows" {
		exts = []string{".bat", ".cmd", ".ps1"}
	} else if runtime.GOOS == "darwin" {
		exts = []string{".sh", ".command"}
	}
	rank := map[string]int{}
	for i, s := range scriptStems {
		rank[s] = i
	}
	type cand struct {
		path string
		r    int
	}
	var found []cand
	for _, fname := range ls.files {
		name := strings.ToLower(fname)
		for _, ext := range exts {
			if !strings.HasSuffix(name, ext) {
				continue
			}
			if r, ok := rank[strings.TrimSuffix(name, ext)]; ok {
				found = append(found, cand{filepath.Join(ls.dir, fname), r})
			}
			break
		}
	}
	sort.Slice(found, func(i, j int) bool {
		if found[i].r != found[j].r {
			return found[i].r < found[j].r
		}
		return found[i].path < found[j].path
	})
	out := make([]string, 0, len(found))
	for _, c := range found {
		out = append(out, c.path)
	}
	return out
}

// pickStartScript sceglie fra i candidati. A parità di ordine vince quello che
// imposta esplicitamente la memoria: i server pack spediscono spesso sia il
// run.sh generato dall'installer (che lascia l'heap di default, cioè 1/4 della
// RAM: un pack da 400 mod ci muore) sia lo script dell'autore con i flag
// giusti.
func pickStartScript(cands []string) string {
	if len(cands) == 0 {
		return ""
	}
	for _, p := range cands {
		if scriptSetsHeap(p) {
			return p
		}
	}
	return cands[0]
}

func scriptSetsHeap(path string) bool {
	b, err := os.ReadFile(path)
	if err != nil || len(b) > 512*1024 {
		return false
	}
	return strings.Contains(string(b), "-Xmx")
}

// hasCRLF dice se un file di testo ha fine-riga Windows: eseguito da sh su
// Linux darebbe errori incomprensibili tipo «$'\r': command not found».
func hasCRLF(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	buf := make([]byte, 4096)
	n, _ := f.Read(buf)
	return bytes.Contains(buf[:n], []byte("\r\n"))
}

// launcherJars: jar che sanno avviarsi da soli con `java -jar`, in ordine di
// preferenza. Serve ai pack che non hanno nessuno script: Fabric, Quilt,
// vanilla, Paper e i Forge fino alla 1.16 sono tutti così.
var launcherJarPatterns = []string{
	"fabric-server-launch.jar",
	"quilt-server-launch.jar",
	"forge-*-universal.jar",
	"forge-*.jar",
	"minecraft_server*.jar",
	"server.jar",
	"paper*.jar",
	"purpur*.jar",
	"spigot*.jar",
}

// findLauncherJar cerca un jar avviabile, scartando gli installer (un
// `forge-1.20.1-installer.jar` dimenticato nella cartella non è un server).
func findLauncherJar(ls rootListing) string {
	names := ls.jars()
	sort.Strings(names)
	for _, pat := range launcherJarPatterns {
		for _, n := range names {
			low := strings.ToLower(n)
			if strings.Contains(low, "-sources") {
				continue
			}
			if ok, _ := filepath.Match(pat, low); ok {
				return filepath.Join(ls.dir, n)
			}
		}
	}
	return ""
}

// buildLaunch costruisce il comando di avvio: lo script se c'è, altrimenti un
// `java -jar` sintetizzato dal jar del loader. Senza questo ripiego i pack
// Fabric/vanilla/Paper senza script — cioè moltissimi — erano inutilizzabili.
func buildLaunch(ls rootListing, script string) (argv []string, note string) {
	if script != "" {
		base := filepath.Base(script)
		switch strings.ToLower(filepath.Ext(script)) {
		case ".ps1":
			return []string{"powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", base},
				i18n.Sf("script PowerShell %s", base)
		case ".bat", ".cmd":
			// `call` protegge dai nomi con spazi e dai .bat che ne chiamano altri
			return []string{"cmd", "/C", "call", base}, i18n.Sf("script %s", base)
		default:
			return unixScriptArgv(script), i18n.Sf("script %s", base)
		}
	}
	if jar := findLauncherJar(ls); jar != "" {
		return []string{"java", "-jar", filepath.Base(jar), "nogui"},
			i18n.Sf("nessuno script: avvio diretto di %s", filepath.Base(jar))
	}
	return nil, ""
}

// unixScriptArgv decide con cosa eseguire uno script su unix. Eseguirlo
// direttamente fa rispettare lo shebang: lanciarlo con `sh` come si faceva
// prima significa dare in pasto a dash gli script scritti per bash (array,
// [[ ]], set -o pipefail) di mezzo mondo dei server pack, che falliscono
// all'istante e sembrano un crash del server.
func unixScriptArgv(script string) []string {
	base := filepath.Base(script)
	if st, err := os.Stat(script); err == nil && st.Mode()&0o111 != 0 && !hasCRLF(script) {
		return []string{"./" + base}
	}
	// non eseguibile (o con CRLF): serve un interprete esplicito
	if wantsBash(script) {
		if p, err := exec.LookPath("bash"); err == nil {
			return []string{p, base}
		}
	}
	return []string{"sh", base}
}

// wantsBash guarda shebang e sintassi per capire se lo script è bash-only.
func wantsBash(path string) bool {
	b, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	s := string(b)
	if i := strings.IndexByte(s, '\n'); i > 0 && strings.Contains(s[:i], "bash") {
		return true
	}
	for _, marker := range []string{"[[", "set -o pipefail", "=(", "pushd", "function "} {
		if strings.Contains(s, marker) {
			return true
		}
	}
	return false
}

// detectLoader riconosce il mod loader: librerie installate, jar di lancio
// Fabric/Quilt, jar forge/neoforge in radice, infine server.properties
// (vanilla). La versione del loader la ricava loaderVersionFromJars.
func detectLoader(ls rootListing) string {
	libs := filepath.Join(ls.dir, "libraries")
	loader := ""
	checks := []struct{ sub, name string }{
		{"net/neoforged", "neoforge"},
		{"net/minecraftforge", "forge"},
		{"org/quiltmc", "quilt"}, // Quilt pubblica su org.quiltmc, non net.quiltmc
		{"net/fabricmc", "fabric"},
	}
	for _, c := range checks {
		if _, err := os.Stat(filepath.Join(libs, filepath.FromSlash(c.sub))); err == nil {
			loader = c.name
			break
		}
	}
	// un server Quilt installa anche le librerie Fabric: il jar toglie il dubbio
	if ls.has("quilt-server-launch.jar") {
		return "quilt"
	}
	if loader == "" && ls.has("fabric-server-launch.jar") {
		return "fabric"
	}
	if loader == "" {
		if jar, isNeo := forgeJar(ls); jar != "" {
			loader = map[bool]string{true: "neoforge", false: "forge"}[isNeo]
		}
	}
	if loader == "" && ls.has("server.properties") {
		loader = "vanilla"
	}
	return loader
}

// forgeJar trova il primo jar forge/neoforge in radice (installer esclusi).
func forgeJar(ls rootListing) (name string, isNeo bool) {
	for _, n := range ls.jars() {
		low := strings.ToLower(n)
		if strings.HasPrefix(low, "neoforge-") {
			return n, true
		}
		if strings.HasPrefix(low, "forge-") {
			return n, false
		}
	}
	return "", false
}

// loaderVersionFromJars ricava (best-effort) la versione del loader dal nome
// del jar in radice: forge-<mc>-<loader>[-universal].jar ; neoforge-<loader>.jar
func loaderVersionFromJars(ls rootListing) string {
	jar, isNeo := forgeJar(ls)
	if jar == "" {
		return ""
	}
	parts := strings.Split(strings.TrimSuffix(jar, filepath.Ext(jar)), "-")
	switch {
	case isNeo && len(parts) >= 2:
		return parts[1]
	case !isNeo && len(parts) >= 3:
		return parts[2]
	}
	return ""
}

// detectMCVersion ricava la versione di Minecraft dalle librerie del loader.
// Ogni loader lascia una traccia affidabile:
//   - forge:    libraries/net/minecraftforge/forge/<mc>-<forge>
//   - neoforge: libraries/net/neoforged/neoforge/<mcMinor>.<mcPatch>.<build>
//   - fabric:   libraries/net/fabricmc/intermediary/<mc>
func detectMCVersion(ls rootListing, loader string) string {
	dir := ls.dir
	libs := filepath.Join(dir, "libraries")
	// 1. le librerie del server vanilla: valgono per ogni loader
	if d := lastSubdir(filepath.Join(libs, "net", "minecraft", "server")); d != "" {
		if v := strings.SplitN(d, "-", 2)[0]; looksLikeMC(v) {
			return v
		}
	}
	switch loader {
	case "forge":
		if d := lastSubdir(filepath.Join(libs, "net", "minecraftforge", "forge")); d != "" {
			return strings.SplitN(d, "-", 2)[0] // "1.20.1-47.4.0" → "1.20.1"
		}
	case "neoforge":
		// NeoForge 1.20.1 sta sotto net/neoforged/forge come "1.20.1-47.1.x",
		// dalla 1.20.2 sotto net/neoforged/neoforge come "21.1.79"
		if d := lastSubdir(filepath.Join(libs, "net", "neoforged", "forge")); d != "" {
			if v := strings.SplitN(d, "-", 2)[0]; looksLikeMC(v) {
				return v
			}
		}
		if d := lastSubdir(filepath.Join(libs, "net", "neoforged", "neoforge")); d != "" {
			p := strings.Split(d, ".")
			if len(p) >= 2 {
				return "1." + p[0] + "." + p[1] // "21.1.79" → "1.21.1"
			}
		}
	case "fabric", "quilt":
		if d := lastSubdir(filepath.Join(libs, "net", "fabricmc", "intermediary")); d != "" {
			return d
		}
		if d := lastSubdir(filepath.Join(libs, "org", "quiltmc", "hashed")); d != "" {
			return d
		}
	}
	// 2. cartella versions/<mc>/ dei pack Fabric e vanilla-bundler
	if d := lastSubdir(filepath.Join(dir, "versions")); looksLikeMC(d) {
		return d
	}
	// 3. nomi dei jar in radice: è l'unica traccia nei pack Forge 1.12-1.16,
	//    dove sbagliare versione vuol dire lanciare con Java 21 un server che
	//    esiste solo per Java 8
	if v := versionFromJarNames(ls); v != "" {
		return v
	}
	return ""
}

var jarVerRes = []*regexp.Regexp{
	regexp.MustCompile(`fabric-server-mc\.(1\.\d+(?:\.\d+)?)-loader`),    // launcher Fabric
	regexp.MustCompile(`^forge-(1\.\d+(?:\.\d+)?)-`),                     // forge-1.12.2-14.23.5.2860.jar
	regexp.MustCompile(`^minecraft_server\.(1\.\d+(?:\.\d+)?)\.jar$`),    // minecraft_server.1.12.2.jar
	regexp.MustCompile(`^server-(1\.\d+(?:\.\d+)?)\.jar$`),               // server-1.21.1.jar
	regexp.MustCompile(`^(?:paper|purpur|spigot)[-_](1\.\d+(?:\.\d+)?)`), // paper-1.20.4-497.jar
}

func versionFromJarNames(ls rootListing) string {
	for _, name := range ls.jars() {
		n := strings.ToLower(name)
		for _, re := range jarVerRes {
			if m := re.FindStringSubmatch(n); m != nil {
				return m[1]
			}
		}
	}
	return ""
}

// lastSubdir restituisce la sottocartella "più alta" in ordine di versione.
// Prendere la prima in ordine alfabetico, come si faceva, sbagliava di brutto
// sui pack aggiornati sul posto: con 1.20.1 e 1.21.1 entrambe presenti
// vinceva 1.20.1, quindi MineSync imponeva Java 17 a un server 1.21 e lo
// faceva morire su una macchina dove sarebbe partito da solo.
func lastSubdir(dir string) string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return ""
	}
	best := ""
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		if best == "" || compareVersions(e.Name(), best) > 0 {
			best = e.Name()
		}
	}
	return best
}

// compareVersions confronta stringhe di versione numero per numero.
func compareVersions(a, b string) int {
	as, bs := splitNums(a), splitNums(b)
	for i := 0; i < len(as) || i < len(bs); i++ {
		var x, y int
		if i < len(as) {
			x = as[i]
		}
		if i < len(bs) {
			y = bs[i]
		}
		if x != y {
			if x > y {
				return 1
			}
			return -1
		}
	}
	return strings.Compare(a, b)
}

func splitNums(s string) []int {
	var out []int
	cur, has := 0, false
	for i := 0; i < len(s); i++ {
		if s[i] >= '0' && s[i] <= '9' {
			cur, has = cur*10+int(s[i]-'0'), true
			continue
		}
		if has {
			out = append(out, cur)
			cur, has = 0, false
		}
	}
	if has {
		out = append(out, cur)
	}
	return out
}

var mcVerRe = regexp.MustCompile(`^1\.\d{1,2}(\.\d{1,2})?$`)

func looksLikeMC(s string) bool { return mcVerRe.MatchString(s) }

// versionFromServerJar legge version.json dentro il server jar vanilla: è la
// fonte autorevole, la scrive Mojang e dichiara anche il Java richiesto
// ("javaVersion":{"majorVersion":21}), che è meglio di qualunque tabella
// mantenuta a mano.
func versionFromServerJar(dir string) (mcVersion string, javaMajor int) {
	cands := []string{
		filepath.Join(dir, "server.jar"),
		filepath.Join(dir, "minecraft_server.jar"),
	}
	if v := lastSubdir(filepath.Join(dir, "versions")); v != "" {
		cands = append([]string{
			filepath.Join(dir, "versions", v, "server-"+v+".jar"),
			filepath.Join(dir, "versions", v, "server.jar"),
		}, cands...)
	}
	for _, jar := range cands {
		if v, m := readVersionJSON(jar); v != "" {
			return v, m
		}
	}
	return "", 0
}

func readVersionJSON(jar string) (string, int) {
	zr, err := zip.OpenReader(jar)
	if err != nil {
		return "", 0
	}
	defer zr.Close()
	for _, f := range zr.File {
		if f.Name != "version.json" {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			return "", 0
		}
		defer rc.Close()
		var v struct {
			ID          string `json:"id"`
			Name        string `json:"name"`
			JavaVersion struct {
				MajorVersion int `json:"majorVersion"`
			} `json:"javaVersion"`
		}
		if json.NewDecoder(io.LimitReader(rc, 1<<20)).Decode(&v) != nil {
			return "", 0
		}
		id := v.ID
		if id == "" {
			id = v.Name
		}
		return id, v.JavaVersion.MajorVersion
	}
	return "", 0
}

// versionFromPackManifest legge il manifest del pack distribuito: è l'unica
// fonte disponibile PRIMA del primo avvio, quando libraries/ non esiste ancora.
func versionFromPackManifest(dir string) string {
	// CurseForge
	if b, err := os.ReadFile(filepath.Join(dir, "manifest.json")); err == nil {
		var m struct {
			Minecraft struct {
				Version string `json:"version"`
			} `json:"minecraft"`
		}
		if json.Unmarshal(b, &m) == nil && looksLikeMC(m.Minecraft.Version) {
			return m.Minecraft.Version
		}
	}
	// Modrinth
	if b, err := os.ReadFile(filepath.Join(dir, "modrinth.index.json")); err == nil {
		var m struct {
			Dependencies map[string]string `json:"dependencies"`
		}
		if json.Unmarshal(b, &m) == nil && looksLikeMC(m.Dependencies["minecraft"]) {
			return m.Dependencies["minecraft"]
		}
	}
	return ""
}
