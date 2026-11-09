// Package version: la versione del client. Viene iniettata in fase di build
// (-ldflags "-X minesync/client/internal/version.Client=x.y.z") dal tag git;
// le build locali restano "dev" e non si auto-aggiornano mai.
package version

import (
	"strconv"
	"strings"
)

// Client è la versione di questo binario ("dev" se non iniettata).
var Client = "dev"

// Display è la versione da mostrare all'utente: "v1.2.3" oppure "dev".
func Display() string {
	if _, ok := parse(Client); ok {
		return "v" + strings.TrimPrefix(Client, "v")
	}
	return Client
}

// semver è una versione semantica già scomposta (build metadata ignorati).
type semver struct {
	core [3]int
	pre  []string // identificatori della pre-release (nil = release)
}

// parse accetta "1.2.3", "v1.2.3", "1.2.3-rc.1", "1.2.3+build". Tutto il
// resto (compreso "dev") non è una versione confrontabile.
func parse(v string) (semver, bool) {
	var out semver
	v = strings.TrimPrefix(strings.TrimSpace(v), "v")
	if i := strings.IndexByte(v, '+'); i >= 0 {
		v = v[:i]
	}
	core, pre, hasPre := strings.Cut(v, "-")
	parts := strings.Split(core, ".")
	if len(parts) != 3 {
		return out, false
	}
	for i, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil || n < 0 || p == "" || (len(p) > 1 && p[0] == '0') {
			return out, false
		}
		out.core[i] = n
	}
	if hasPre {
		if pre == "" {
			return out, false
		}
		out.pre = strings.Split(pre, ".")
		for _, id := range out.pre {
			if id == "" {
				return out, false
			}
		}
	}
	return out, true
}

// Compare confronta due versioni semantiche: -1 se a<b, 0 se uguali, 1 se a>b.
// ok è falso se una delle due non è una versione valida.
func Compare(a, b string) (cmp int, ok bool) {
	va, okA := parse(a)
	vb, okB := parse(b)
	if !okA || !okB {
		return 0, false
	}
	for i := range 3 {
		if c := compareInt(va.core[i], vb.core[i]); c != 0 {
			return c, true
		}
	}
	return comparePre(va.pre, vb.pre), true
}

// Newer riporta se candidate è strettamente più nuova di current. Se una
// delle due non è semver (es. "dev") la risposta è sempre no: niente
// aggiornamenti automatici "al buio" e mai downgrade.
func Newer(candidate, current string) bool {
	c, ok := Compare(candidate, current)
	return ok && c > 0
}

func compareInt(a, b int) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}

// comparePre segue le regole semver: una release batte qualunque
// pre-release; gli identificatori numerici si confrontano come numeri e
// valgono meno di quelli alfanumerici.
func comparePre(a, b []string) int {
	switch {
	case a == nil && b == nil:
		return 0
	case a == nil:
		return 1
	case b == nil:
		return -1
	}
	for i := 0; i < len(a) && i < len(b); i++ {
		na, errA := strconv.Atoi(a[i])
		nb, errB := strconv.Atoi(b[i])
		switch {
		case errA == nil && errB == nil:
			if c := compareInt(na, nb); c != 0 {
				return c
			}
		case errA == nil:
			return -1
		case errB == nil:
			return 1
		default:
			if c := strings.Compare(a[i], b[i]); c != 0 {
				return c
			}
		}
	}
	return compareInt(len(a), len(b))
}
