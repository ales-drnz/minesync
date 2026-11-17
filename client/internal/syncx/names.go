package syncx

import (
	"runtime"
	"strings"
)

// Nomi di file che non possono esistere su Windows (C5).
//
// Linux e macOS accettano quasi tutto, Windows no: un "mappa?.dat" o un
// "CON.txt" creati da un mod su Linux finivano sull'hub e da lì bloccavano il
// pull di chiunque giocasse da Windows. Si fermano alla fonte, su ogni
// sistema: la scansione li salta con un avviso (e l'hub li rifiuta comunque).

// reservedWin: nomi di dispositivo riservati, con qualunque estensione.
var reservedWin = map[string]bool{"CON": true, "PRN": true, "AUX": true, "NUL": true}

func init() {
	for _, p := range []string{"COM", "LPT"} {
		for i := '1'; i <= '9'; i++ {
			reservedWin[p+string(i)] = true
		}
	}
}

// WindowsInvalid restituisce il primo segmento del percorso (separato da
// "/") che non sarebbe un nome valido su Windows, "" se è tutto lecito.
func WindowsInvalid(rel string) string {
	for _, seg := range strings.Split(rel, "/") {
		if !winValidSegment(seg) {
			return seg
		}
	}
	return ""
}

func winValidSegment(seg string) bool {
	if seg == "" {
		return false
	}
	for _, r := range seg {
		if r < 0x20 || strings.ContainsRune(`<>:"/\|?*`, r) {
			return false
		}
	}
	if last := seg[len(seg)-1]; last == '.' || last == ' ' {
		return false
	}
	stem := seg
	if i := strings.IndexByte(stem, '.'); i >= 0 {
		stem = stem[:i]
	}
	return !reservedWin[strings.ToUpper(strings.TrimRight(stem, " "))]
}

// invalidHere: un percorso dell'hub che su QUESTO sistema non si può creare.
// Su Windows valgono le regole sopra; altrove quello che validRel non
// rifiuta già si può scrivere.
func invalidHere(rel string) bool {
	return runtime.GOOS == "windows" && WindowsInvalid(rel) != ""
}
