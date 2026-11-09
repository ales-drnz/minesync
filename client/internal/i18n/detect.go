package i18n

import (
	"os"
	"strings"
)

// EnvVar forza la lingua del client (it|en), sopra a tutto il resto.
const EnvVar = "MINESYNC_LANG"

// Resolve sceglie la lingua: env MINESYNC_LANG → lingua in config (cfg,
// "" = automatica) → lingua del sistema operativo → inglese.
func Resolve(cfg string) Lang {
	if l, ok := Parse(os.Getenv(EnvVar)); ok {
		return l
	}
	if l, ok := Parse(cfg); ok {
		return l
	}
	if l, ok := FromOS(); ok {
		return l
	}
	return EN
}

// parseAppleLanguages legge l'output di `defaults read -g AppleLanguages`
// (macOS), ( "it-IT", "en-US" ) → la prima lingua supportata. Sta qui e non
// nel file darwin perché il test giri su ogni sistema.
func parseAppleLanguages(s string) (Lang, bool) {
	s = strings.NewReplacer("(", "", ")", "", "\n", ",").Replace(s)
	return Parse(s)
}

// fromEnv legge le variabili di locale POSIX, nell'ordine di priorità.
// "C"/"POSIX" non dicono nulla sulla lingua: si passa alla successiva.
func fromEnv() (Lang, bool) {
	for _, k := range []string{"LC_ALL", "LC_MESSAGES", "LANG"} {
		v := strings.TrimSpace(os.Getenv(k))
		if v == "" {
			continue
		}
		if l, ok := Parse(v); ok {
			return l, true
		}
	}
	return "", false
}
