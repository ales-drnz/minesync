package mc

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// Modello di fiducia (S7): la cartella del server è sincronizzata dall'hub,
// quindi chiunque possa pushare sullo spazio ne controlla il contenuto.
// Premere Play significa fidarsi dei membri dello spazio: lo start script, le
// mod e l'eventuale runtime Java incluso nel modpack vengono eseguiti. Prima
// del Play, invece, MineSync non esegue NULLA che stia dentro la cartella
// sincronizzata: per un java che sta lì dentro la UI mostra solo che esiste
// (Unverified) e la versione la scopre la sessione, dopo il Play (PickJava).

// JavaInfo descrive un runtime Java.
type JavaInfo struct {
	Found      bool
	Path       string // percorso dell'eseguibile ("" = quello del PATH)
	Version    string
	Major      int
	Bits       int  // 64 o 32 (0 = ignoto)
	Unverified bool // dentro la cartella sincronizzata: non eseguito prima del Play
}

// javaCheckTimeout limita ogni `java -version`: un runtime rotto o lento non
// deve bloccare il rilevamento.
const javaCheckTimeout = 3 * time.Second

var javaVerRe = regexp.MustCompile(`version "([^"]+)"`)

// CheckJava esegue `java -version` dal PATH e ne estrae la versione.
func CheckJava() JavaInfo {
	j := CheckJavaAt("java")
	j.Path = "" // dal PATH: nessun override d'ambiente necessario
	return j
}

// CheckJavaAt esegue `<exe> -version` sull'eseguibile indicato (timeout 3s).
func CheckJavaAt(exe string) JavaInfo {
	ctx, cancel := context.WithTimeout(context.Background(), javaCheckTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, exe, "-version").CombinedOutput()
	if err != nil {
		return JavaInfo{}
	}
	txt := string(out)
	bits := 64
	if strings.Contains(txt, "32-Bit") || (strings.Contains(txt, "Client VM") && !strings.Contains(txt, "64-Bit")) {
		bits = 32 // una JVM a 32 bit non regge -Xmx oltre ~1.5G: va evitata
	}
	m := javaVerRe.FindStringSubmatch(txt)
	if m == nil {
		return JavaInfo{Found: true, Path: exe, Bits: bits}
	}
	v := m[1]
	return JavaInfo{Found: true, Path: exe, Version: v, Major: majorOf(v), Bits: bits}
}

// majorOf estrae il major da una versione Java: "1.8.0_501" → 8,
// "17.0.9" → 17, "21.0.1+12" → 21, "24-ea" → 24 (early access compresi).
func majorOf(v string) int {
	parts := strings.Split(v, ".")
	if parts[0] == "1" && len(parts) > 1 { // vecchio schema 1.8.x
		return leadingInt(parts[1])
	}
	return leadingInt(parts[0])
}

// IsInside riporta se path sta dentro dir (o coincide con essa).
func IsInside(path, dir string) bool {
	if path == "" || dir == "" {
		return false
	}
	ap, err1 := filepath.Abs(path)
	ad, err2 := filepath.Abs(dir)
	if err1 != nil || err2 != nil {
		return false
	}
	if runtime.GOOS == "windows" {
		ap, ad = strings.ToLower(ap), strings.ToLower(ad)
	}
	rel, err := filepath.Rel(ad, ap)
	if err != nil {
		return false
	}
	return rel == "." || filepath.IsLocal(rel)
}

// DetectJavas trova i runtime Java installati: il PATH, JAVA_HOME e le cartelle
// d'installazione standard dei vendor. Ordina dal major più alto al più basso e
// deduplica per versione.
func DetectJavas() []JavaInfo { return DetectJavasFor("") }

// DetectJavasFor include anche i runtime spediti dentro la cartella del
// server (serverDir può essere "").
func DetectJavasFor(serverDir string) []JavaInfo {
	cands := javasInServerDir(serverDir) // il runtime del pack ha la precedenza
	if p, err := exec.LookPath("java"); err == nil {
		cands = append(cands, p)
	}
	if jh := os.Getenv("JAVA_HOME"); jh != "" {
		cands = append(cands, filepath.Join(jh, "bin", javaExeName()))
	}
	cands = append(cands, scanJavaDirs()...)

	seenPath := map[string]bool{}
	seenVer := map[string]bool{}
	var out []JavaInfo
	for _, c := range cands {
		// i symlink di sistema (/usr/lib/jvm/default) puntano a un runtime
		// gia' in lista: si deduplica sul percorso reale
		real := c
		if r, err := filepath.EvalSymlinks(c); err == nil {
			real = r
		}
		key := strings.ToLower(real)
		if seenPath[key] {
			continue
		}
		seenPath[key] = true
		j := CheckJavaAt(c)
		if !j.Found || j.Major == 0 {
			continue
		}
		vkey := j.Version + "/" + strconv.Itoa(j.Bits)
		if seenVer[vkey] {
			continue
		}
		seenVer[vkey] = true
		out = append(out, j)
	}
	// major decrescente: i runtime moderni per primi
	for i := 1; i < len(out); i++ {
		for k := i; k > 0 && out[k].Major > out[k-1].Major; k-- {
			out[k], out[k-1] = out[k-1], out[k]
		}
	}
	return out
}

func javaExeName() string {
	if runtime.GOOS == "windows" {
		return "java.exe"
	}
	return "java"
}

// scanJavaDirs cerca i java nelle cartelle d'installazione tipiche E nei
// runtime dei launcher Minecraft. Questi ultimi non sono un dettaglio: sul PC
// di un giocatore il Java giusto quasi sempre c'è già, ma è quello scaricato
// dal launcher ufficiale o da Prism/CurseForge, non un JDK di sistema. Senza
// guardarci dentro, MineSync diceva "nessun runtime compatibile" su macchine
// che ne avevano tre.
func scanJavaDirs() []string {
	home, _ := os.UserHomeDir()
	var globs []string
	switch runtime.GOOS {
	case "windows":
		var roots []string
		for _, env := range []string{"ProgramFiles", "ProgramFiles(x86)", "ProgramW6432", "LOCALAPPDATA", "APPDATA", "USERPROFILE"} {
			if v := os.Getenv(env); v != "" {
				roots = append(roots, v)
			}
		}
		vendors := []string{
			`Eclipse Adoptium\*`, `Java\*`, `Microsoft\jdk-*`, `Zulu\*`,
			`Amazon Corretto\*`, `BellSoft\*`, `Eclipse Foundation\*`, `AdoptOpenJDK\*`,
			`Semeru\*`, `GraalVM\*`, `SapMachine\*`, `.jdks\*`,
		}
		for _, r := range roots {
			for _, v := range vendors {
				globs = append(globs, filepath.Join(r, v, "bin", "java.exe"))
			}
			// runtime dei launcher (ufficiale, Prism/MultiMC/PolyMC, CurseForge, ATLauncher)
			globs = append(globs,
				filepath.Join(r, `.minecraft\runtime\*\windows-x64\*\bin\java.exe`),
				filepath.Join(r, `.minecraft\runtime\*\windows\*\bin\java.exe`),
				filepath.Join(r, `Minecraft Launcher\runtime\*\windows-x64\*\bin\java.exe`),
				filepath.Join(r, `Packages\Microsoft.4297127D64EC6_8wekyb3d8bbwe\LocalCache\Local\runtime\*\windows-x64\*\bin\java.exe`),
				filepath.Join(r, `PrismLauncher\java\*\bin\java.exe`),
				filepath.Join(r, `MultiMC\java\*\bin\java.exe`),
				filepath.Join(r, `PolyMC\java\*\bin\java.exe`),
				filepath.Join(r, `curseforge\minecraft\Install\runtime\*\windows-x64\*\bin\java.exe`),
				filepath.Join(r, `ATLauncher\runtimes\*\bin\java.exe`),
				filepath.Join(r, `gdlauncher_next\java\*\bin\java.exe`),
			)
		}
	case "darwin":
		globs = []string{
			"/Library/Java/JavaVirtualMachines/*/Contents/Home/bin/java",
			"/opt/homebrew/opt/openjdk*/bin/java",
			"/usr/local/opt/openjdk*/bin/java",
		}
		if home != "" {
			globs = append(globs,
				home+"/Library/Java/JavaVirtualMachines/*/Contents/Home/bin/java",
				home+"/Library/Application Support/minecraft/runtime/*/mac-os*/*/jre.bundle/Contents/Home/bin/java",
				home+"/Library/Application Support/minecraft/runtime/*/mac-os*/*/bin/java",
				home+"/Library/Application Support/PrismLauncher/java/*/bin/java",
				home+"/.sdkman/candidates/java/*/bin/java",
				home+"/.jdks/*/bin/java",
			)
		}
	default: // linux e simili
		globs = []string{
			"/usr/lib/jvm/*/bin/java",
			"/usr/lib/jvm/*/jre/bin/java",
			"/usr/lib64/jvm/*/bin/java",
			"/usr/java/*/bin/java",
			"/opt/java/*/bin/java",
			"/opt/*/bin/java",
		}
		if home != "" {
			globs = append(globs,
				home+"/.minecraft/runtime/*/linux/*/bin/java",
				home+"/.minecraft/runtime/*/linux-i386/*/bin/java",
				home+"/.local/share/PrismLauncher/java/*/bin/java",
				home+"/.local/share/multimc/java/*/bin/java",
				home+"/.local/share/PolyMC/java/*/bin/java",
				home+"/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher/java/*/bin/java",
				home+"/.local/share/atlauncher/runtimes/*/bin/java",
				home+"/.sdkman/candidates/java/*/bin/java",
				home+"/.jdks/*/bin/java",
				home+"/.gradle/jdks/*/bin/java",
			)
		}
	}
	var out []string
	for _, g := range globs {
		matches, _ := filepath.Glob(g)
		out = append(out, matches...)
	}
	return out
}

// javasInServerDir cerca un runtime spedito insieme al modpack. Molti pack
// (e il nostro server Cobbleverse) ne includono uno: se la macchina non ha
// Java di sistema è l'unico modo di partire, e prima MineSync si rifiutava
// di avviare un server che sarebbe partito benissimo.
func javasInServerDir(dir string) []string {
	if dir == "" {
		return nil
	}
	var out []string
	for _, pat := range []string{"runtime*", "jre*", "jdk*", "java*", "*/jre*", "*/jdk*"} {
		for _, sub := range []string{"bin/java", "bin/java.exe", "Contents/Home/bin/java"} {
			m, _ := filepath.Glob(filepath.Join(dir, pat, filepath.FromSlash(sub)))
			out = append(out, m...)
		}
	}
	return out
}

// RequiredMajor mappa una versione di Minecraft al major di Java richiesto.
// Restituisce 0 se la versione non è riconoscibile.
func RequiredMajor(mcVersion string) int {
	f := strings.SplitN(strings.TrimSpace(mcVersion), ".", 3)
	if len(f) < 2 || f[0] != "1" {
		return 0
	}
	minor, err := strconv.Atoi(f[1])
	if err != nil {
		return 0
	}
	patch := 0
	if len(f) >= 3 {
		patch = leadingInt(f[2])
	}
	switch {
	case minor <= 16:
		return 8 // fino a 1.16.5
	case minor == 17:
		return 17 // 1.17.x: Mojang chiedeva il 16, ma e' EOL e il 17 va bene
	case minor < 20:
		return 17 // 1.18 – 1.19
	case minor == 20:
		if patch <= 4 {
			return 17 // 1.20 – 1.20.4
		}
		return 21 // 1.20.5 – 1.20.6
	default:
		return 21 // 1.21+
	}
}

func leadingInt(s string) int {
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i++
	}
	n, _ := strconv.Atoi(s[:i])
	return n
}

// RequiredJava è il major di Java che il modpack vuole: quello dichiarato dal
// server jar se c'è (lo scrive Mojang, non si discute), altrimenti la tabella
// per versione di Minecraft. 0 = ignoto.
func RequiredJava(info ServerInfo) int {
	if info.JavaMajor > 0 {
		return info.JavaMajor
	}
	return RequiredMajor(info.MCVersion)
}

// rank ordina i runtime rispetto a quello ideale: più basso è meglio.
// Un Java più NUOVO del richiesto di solito funziona (o al peggio si lamenta),
// uno più VECCHIO no: manda in UnsupportedClassVersionError all'istante. Un
// tempo si pretendeva il major esatto, così bastava non avere in casa proprio
// quel numero per ricadere sul java del PATH — spesso il più sbagliato di tutti.
func rank(j JavaInfo, ideal int) int {
	r := 0
	switch {
	case j.Major == ideal:
		r = 0
	case j.Major > ideal:
		r = 10 + (j.Major - ideal)
	default:
		r = 1000 + (ideal - j.Major)
	}
	if j.Bits == 32 {
		r += 500 // -Xmx grande su una JVM a 32 bit non parte proprio
	}
	return r
}

// PickJava sceglie il runtime da usare per un server:
//   - se explicit != "" usa quell'eseguibile (scelta manuale dell'utente),
//     con ripiego sull'automatico se quel percorso non esiste più;
//   - altrimenti il runtime incluso nel pack o installato che meglio si
//     avvicina a quello richiesto dal modpack;
//   - altrimenti il java del PATH (comportamento storico).
//
// Restituisce il java scelto e il major richiesto dal modpack (0 = ignoto),
// così il chiamante può avvisare in caso di incompatibilità. Esegue anche i
// runtime inclusi nel pack: va usata dopo il Play (per la UI c'è PreviewJava).
func PickJava(info ServerInfo, explicit string) (JavaInfo, int) {
	req := RequiredJava(info)
	if explicit != "" {
		if j := CheckJavaAt(explicit); j.Found {
			return j, req
		}
		// il runtime scelto a mano è sparito (aggiornamento della distro,
		// disinstallazione): meglio l'automatico che rifiutarsi di partire
	}
	return bestJava(DetectJavasFor(info.Dir), req), req
}

// bestJava sceglie fra i candidati quello più vicino al major richiesto; a
// pari merito (o con req ignoto) vince il primo. Nessun candidato → PATH.
func bestJava(cands []JavaInfo, req int) JavaInfo {
	if len(cands) == 0 {
		return CheckJava()
	}
	best := cands[0]
	if req > 0 {
		for _, j := range cands[1:] {
			if rank(j, req) < rank(best, req) {
				best = j
			}
		}
	}
	return best
}

// PreviewJava è PickJava per la UI PRIMA del Play. Non esegue mai un java che
// sta dentro la cartella sincronizzata info.Dir (vedi il modello di fiducia):
// se il pack ne include uno — che PickJava metterebbe in testa ai candidati —
// lo riporta come Unverified senza lanciarlo. detect fornisce i runtime di
// sistema (chiamata solo se serve, così il chiamante può passare una cache).
func PreviewJava(info ServerInfo, explicit string, detect func() []JavaInfo) (JavaInfo, int) {
	req := RequiredJava(info)
	if explicit != "" {
		if IsInside(explicit, info.Dir) {
			if st, err := os.Stat(explicit); err == nil && !st.IsDir() {
				return JavaInfo{Found: true, Path: explicit, Unverified: true}, req
			}
		} else if j := CheckJavaAt(explicit); j.Found {
			return j, req
		}
	}
	if bundled := javasInServerDir(info.Dir); len(bundled) > 0 {
		return JavaInfo{Found: true, Path: bundled[0], Unverified: true}, req
	}
	return bestJava(detect(), req), req
}
