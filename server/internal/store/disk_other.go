//go:build !linux && !darwin

package store

import "errors"

// diskStat: l'hub gira su Linux (docker); altrove lo spazio non si misura e
// il controllo del disco non blocca niente.
func diskStat(string) (free, total uint64, err error) {
	return 0, 0, errors.ErrUnsupported
}
