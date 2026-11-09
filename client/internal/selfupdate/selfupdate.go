// Package selfupdate: aggiornamento automatico del client dall'hub.
//
// L'hub serve su /dl i binari della propria versione, più SHA256SUMS (formato
// di sha256sum) e, se la build è firmata, SHA256SUMS.sig (firma ed25519 in
// base64 sui byte esatti di SHA256SUMS). Prima di toccare l'eseguibile:
//
//   - aggiorniamo solo se entrambe le versioni sono semver e quella dell'hub è
//     strettamente più nuova (mai downgrade; le build "dev" non si aggiornano);
//   - se PublicKey è impostata la firma è OBBLIGATORIA e deve verificare: un
//     hub impersonato (ARP spoof su ZeroTier L2) non può farci eseguire codice;
//   - lo SHA-256 del binario scaricato deve combaciare con la sua riga in
//     SHA256SUMS, il file deve iniziare col magic giusto (PE/ELF/Mach-O) ed
//     essere più grande di 1 MB;
//   - il nuovo file è fsync-ato prima del rename.
//
// Il processo in corso continua a girare; la nuova versione parte al riavvio.
// L'eseguibile vecchio resta come "<exe>.old" finché la nuova versione non ha
// dimostrato di funzionare (primo ping riuscito → CleanupOld): se l'update è
// rotto, l'utente ha ancora un binario funzionante da rinominare.
// Su Windows non si può sovrascrivere né cancellare un exe in esecuzione, ma
// lo si può rinominare: exe → exe.old, nuovo → exe. Se un vecchio exe.old è
// ancora in esecuzione (non cancellabile) usiamo exe.old-<timestamp>.
package selfupdate

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"

	"minesync/client/internal/i18n"
	"minesync/client/internal/version"
)

// PublicKey è la chiave pubblica ed25519 (base64 std, 32 byte) con cui sono
// firmati i SHA256SUMS. Iniettata in fase di build; vuota = firma non
// richiesta (si verifica comunque lo SHA-256).
var PublicKey = ""

// ErrNotNewer: l'hub non ha una versione più nuova (o una delle due non è semver).
var ErrNotNewer = i18n.NewError("nessun aggiornamento: la versione dell'hub non è più nuova")

const (
	minBinarySize = 1 << 20   // un client vero pesa diversi MB
	maxBinarySize = 512 << 20 // tetto di sicurezza al download
	maxSumsSize   = 64 << 10
)

// AssetName è il nome del binario per questo OS/arch sulla pagina /dl.
func AssetName() string { return assetName(runtime.GOOS, runtime.GOARCH) }

func assetName(goos, goarch string) string {
	ext := ""
	if goos == "windows" {
		ext = ".exe"
	}
	return fmt.Sprintf("minesync-%s-%s%s", goos, goarch, ext)
}

// Apply scarica il client dall'hub e lo mette al posto dell'eseguibile
// corrente, solo se hubVersion è più nuova di version.Client.
func Apply(ctx context.Context, serverURL, hubVersion string) error {
	exe, err := TargetExe()
	if err != nil {
		return err
	}
	u := updater{
		base:    strings.TrimRight(serverURL, "/") + "/dl/",
		asset:   AssetName(),
		goos:    runtime.GOOS,
		pubKey:  PublicKey,
		current: version.Client,
		hub:     hubVersion,
		client:  http.DefaultClient,
	}
	return u.applyTo(ctx, exe)
}

// oldSuffixRe riconosce i residui di un update: "…​.old" o "…​.old-<ts>".
var oldSuffixRe = regexp.MustCompile(`\.old(-\d+)?$`)

// TargetExe è il percorso del binario "vero". Dopo uno swap l'eseguibile in
// esecuzione è stato rinominato in "…​.old" (su Windows e Linux os.Executable()
// può restituire proprio quel path): il binario NUOVO sta al path senza
// suffisso, ed è quello da rilanciare o da aggiornare.
func TargetExe() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	return oldSuffixRe.ReplaceAllString(exe, ""), nil
}

// CleanupOld elimina i residui dell'aggiornamento precedente. Va chiamata
// solo quando la versione corrente ha dimostrato di funzionare (primo ping
// riuscito all'hub). Gli .old ancora in esecuzione (Windows) restano: li
// toglierà un avvio successivo.
func CleanupOld() {
	exe, err := TargetExe()
	if err != nil {
		return
	}
	cleanupOld(exe)
}

func cleanupOld(exe string) {
	matches, _ := filepath.Glob(globEscape(exe) + ".old*")
	for _, m := range matches {
		if oldSuffixRe.MatchString(m) {
			os.Remove(m)
		}
	}
}

// globEscape protegge i metacaratteri di Glob presenti nel path.
func globEscape(p string) string {
	if runtime.GOOS == "windows" {
		// su Windows '\' è il separatore, non un escape: basta togliere [ ] * ?
		return strings.NewReplacer("[", "[[]", "*", "[*]", "?", "[?]").Replace(p)
	}
	return strings.NewReplacer(`\`, `\\`, "[", `\[`, "*", `\*`, "?", `\?`).Replace(p)
}

// updater raccoglie i parametri di un aggiornamento (separati per i test).
type updater struct {
	base    string // URL della cartella /dl/ (con lo slash finale)
	asset   string
	goos    string
	pubKey  string
	current string
	hub     string
	client  *http.Client
}

func (u updater) applyTo(ctx context.Context, exe string) error {
	if !version.Newer(u.hub, u.current) {
		return fmt.Errorf("%w (hub %q, client %q)", ErrNotNewer, u.hub, u.current)
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Minute)
	defer cancel()

	sums, err := u.fetch(ctx, "SHA256SUMS", maxSumsSize)
	if err != nil {
		return fmt.Errorf("SHA256SUMS: %w", err)
	}
	if err := u.verifySignature(ctx, sums); err != nil {
		return err
	}
	want, err := findSum(sums, u.asset)
	if err != nil {
		return err
	}

	tmp := exe + ".new"
	if err := u.download(ctx, tmp, want); err != nil {
		os.Remove(tmp)
		return err
	}
	return swap(exe, tmp)
}

// verifySignature controlla SHA256SUMS.sig contro PublicKey. Senza chiave la
// firma non è richiesta (né verificabile).
func (u updater) verifySignature(ctx context.Context, sums []byte) error {
	if u.pubKey == "" {
		return nil
	}
	key, err := base64.StdEncoding.DecodeString(strings.TrimSpace(u.pubKey))
	if err != nil || len(key) != ed25519.PublicKeySize {
		return i18n.Errorf("chiave pubblica di aggiornamento non valida in questa build")
	}
	sigB64, err := u.fetch(ctx, "SHA256SUMS.sig", 1024)
	if err != nil {
		return i18n.Errorf("firma degli aggiornamenti mancante: %w", err)
	}
	// il file è base64 seguito da un a-capo: via gli spazi prima di decodificare
	sig, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(sigB64)))
	if err != nil || len(sig) != ed25519.SignatureSize {
		return i18n.Errorf("firma degli aggiornamenti malformata")
	}
	if !ed25519.Verify(ed25519.PublicKey(key), sums, sig) {
		return i18n.Errorf("firma degli aggiornamenti NON valida: aggiornamento rifiutato")
	}
	return nil
}

// findSum estrae l'hash atteso per name da un file in formato sha256sum.
func findSum(sums []byte, name string) ([]byte, error) {
	sc := bufio.NewScanner(bytes.NewReader(sums))
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) != 2 {
			continue
		}
		if strings.TrimPrefix(fields[1], "*") != name {
			continue
		}
		h, err := hex.DecodeString(fields[0])
		if err != nil || len(h) != sha256.Size {
			return nil, i18n.Errorf("riga SHA256SUMS malformata per %s", name)
		}
		return h, nil
	}
	return nil, i18n.Errorf("%s non presente in SHA256SUMS", name)
}

func (u updater) get(ctx context.Context, name string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", u.base+name, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept-Language", string(i18n.Current()))
	res, err := u.client.Do(req)
	if err != nil {
		return nil, err
	}
	if res.StatusCode != http.StatusOK {
		res.Body.Close()
		return nil, i18n.Errorf("%s non disponibile sull'hub (HTTP %d)", name, res.StatusCode)
	}
	return res, nil
}

func (u updater) fetch(ctx context.Context, name string, limit int64) ([]byte, error) {
	res, err := u.get(ctx, name)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	b, err := io.ReadAll(io.LimitReader(res.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > limit {
		return nil, i18n.Errorf("%s troppo grande", name)
	}
	return b, nil
}

// download scrive il binario in tmp verificando hash, dimensione e magic,
// e lo porta su disco (fsync) prima di restituire.
func (u updater) download(ctx context.Context, tmp string, want []byte) error {
	res, err := u.get(ctx, u.asset)
	if err != nil {
		return err
	}
	defer res.Body.Close()

	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
	if err != nil {
		return err
	}
	h := sha256.New()
	n, cerr := io.Copy(io.MultiWriter(f, h), io.LimitReader(res.Body, maxBinarySize+1))
	if cerr == nil {
		cerr = f.Sync()
	}
	if err := f.Close(); cerr == nil {
		cerr = err
	}
	if cerr != nil {
		return cerr
	}
	switch {
	case n > maxBinarySize:
		return i18n.Errorf("binario scaricato troppo grande")
	case n <= minBinarySize:
		return i18n.Errorf("binario scaricato troppo piccolo (%d byte): download troncato?", n)
	case !bytes.Equal(h.Sum(nil), want):
		return i18n.Errorf("SHA-256 del binario non combacia con SHA256SUMS: aggiornamento rifiutato")
	}
	return checkMagic(tmp, u.goos)
}

// checkMagic verifica che il file sia un eseguibile del formato giusto.
func checkMagic(path, goos string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	head := make([]byte, 4)
	if _, err := io.ReadFull(f, head); err != nil {
		return i18n.Errorf("binario scaricato illeggibile")
	}
	var ok bool
	switch goos {
	case "windows":
		ok = head[0] == 'M' && head[1] == 'Z'
	case "darwin":
		for _, m := range [][]byte{
			{0xcf, 0xfa, 0xed, 0xfe}, {0xce, 0xfa, 0xed, 0xfe}, // Mach-O 64/32 LE
			{0xfe, 0xed, 0xfa, 0xcf}, {0xfe, 0xed, 0xfa, 0xce}, // Mach-O 64/32 BE
			{0xca, 0xfe, 0xba, 0xbe}, // universal (fat)
		} {
			ok = ok || bytes.Equal(head, m)
		}
	default:
		ok = bytes.Equal(head, []byte("\x7fELF"))
	}
	if !ok {
		return i18n.Errorf("il file scaricato non è un eseguibile %s valido", goos)
	}
	return nil
}

// swap mette tmp al posto di exe, lasciando il vecchio come exe.old.
func swap(exe, tmp string) error {
	old := exe + ".old"
	os.Remove(old)
	if _, err := os.Lstat(old); err == nil {
		// un exe.old precedente è ancora in esecuzione (Windows) e non si
		// può cancellare: il backup prende un nome univoco
		old = exe + ".old-" + strconv.FormatInt(time.Now().UnixNano(), 10)
	}
	if err := os.Rename(exe, old); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, exe); err != nil {
		os.Rename(old, exe) // ripristina
		os.Remove(tmp)
		return err
	}
	syncDir(filepath.Dir(exe))
	return nil
}

// syncDir porta su disco i rename (no-op dove non supportato, es. Windows).
func syncDir(dir string) {
	if runtime.GOOS == "windows" {
		return
	}
	if d, err := os.Open(dir); err == nil {
		d.Sync()
		d.Close()
	}
}
