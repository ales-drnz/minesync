#!/usr/bin/env bash
# Verifica una cartella di release firmata (l'uscita di tools/package/sign.sh)
# con la sola chiave pubblica: SHA256SUMS corrisponde ai file, e
# SHA256SUMS.sig e ogni update/<piattaforma>/manifest.json.sig sono firme
# ed25519 valide. Serve OpenSSL >= 3.0; nessun SDK.
#
#   tools/verify_release.sh <cartella> <chiave pubblica base64> [piattaforma...]
#
# Con le piattaforme (linux-x64, windows-x64, …) controlla anche che ognuna
# abbia il suo manifest firmato.
set -euo pipefail

dir=${1:?uso: tools/verify_release.sh <cartella> <chiave pubblica base64> [piattaforma...]}
pub=${2:?manca la chiave pubblica}
shift 2
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# chiave grezza di 32 byte -> SubjectPublicKeyInfo DER (prefisso fisso ed25519)
printf '%s' "$pub" | base64 -d > "$tmp/raw" 2>/dev/null || { echo "chiave pubblica non base64" >&2; exit 1; }
[ "$(wc -c < "$tmp/raw")" -eq 32 ] || { echo "chiave pubblica: attesi 32 byte" >&2; exit 1; }
{ printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; cat "$tmp/raw"; } > "$tmp/pub.der"
openssl pkey -pubin -inform DER -in "$tmp/pub.der" -out "$tmp/pub.pem"

verify() {
	local file=$1
	[ -f "$file.sig" ] || { echo "manca $file.sig" >&2; return 1; }
	tr -d '[:space:]' < "$file.sig" | base64 -d > "$tmp/sig"
	openssl pkeyutl -verify -pubin -inkey "$tmp/pub.pem" -rawin -in "$file" -sigfile "$tmp/sig" >/dev/null ||
		{ echo "firma non valida: $file" >&2; return 1; }
	echo "firma valida: $file"
}

[ -f "$dir/SHA256SUMS" ] || { echo "manca $dir/SHA256SUMS" >&2; exit 1; }
(cd "$dir" && sha256sum --strict -c SHA256SUMS)
verify "$dir/SHA256SUMS"

found=0
for m in "$dir"/update/*/manifest.json; do
	[ -f "$m" ] || continue
	verify "$m"
	found=$((found + 1))
done
for p in "$@"; do
	[ -f "$dir/update/$p/manifest.json" ] || { echo "manca update/$p/manifest.json" >&2; exit 1; }
done
echo "$found manifest firmati, SHA256SUMS valido"
