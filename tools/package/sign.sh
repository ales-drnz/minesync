#!/usr/bin/env bash
# Firma di un rilascio preparato da tools/package/desktop.sh.
#
#   MINESYNC_UPDATE_KEY=<seme base64> tools/package/sign.sh <outdir>
#
# - firma ogni <outdir>/update/*/manifest.json (-> manifest.json.sig);
# - scrive <outdir>/SHA256SUMS ("<hex>  <nome>", solo i download per gli
#   utenti: AppImage, setup.exe, dmg, archivi della CLI, binari dell'hub
#   minesync-hub-* se presenti) e SHA256SUMS.sig.
#
# MINESYNC_UPDATE_KEY è il formato di `minesync_release keygen` (seme ed25519
# di 32 byte in base64). La chiave va solo in un file temporaneo 0600, mai
# nei log, e viene cancellata all'uscita.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[[ $# -eq 1 ]] || die "uso: $0 <outdir>"
[[ -d $1 ]] || die "cartella inesistente: $1"
OUT=$(cd "$1" && pwd)
[[ -n ${MINESYNC_UPDATE_KEY:-} ]] || die "MINESYNC_UPDATE_KEY non impostata"

[[ -n ${MINESYNC_RELEASE:-} ]] || pub_get

keydir=$(mktemp -d)
trap 'rm -rf "$keydir"' EXIT
(
	umask 077
	printf '%s\n' "$MINESYNC_UPDATE_KEY" >"$keydir/signing.key"
)

shopt -s nullglob
manifests=("$OUT"/update/*/manifest.json)
for m in "${manifests[@]}"; do
	log "firmo ${m#"$OUT"/}"
	release_tool sign --key "$keydir/signing.key" "$m"
done

downloads=()
for f in "$OUT"/MineSync-*.AppImage "$OUT"/MineSync-*-setup.exe "$OUT"/MineSync-*.dmg \
	"$OUT"/MineSync-*-cli.tar.gz "$OUT"/MineSync-*-cli.zip "$OUT"/minesync-hub-*; do
	[[ -f $f ]] && downloads+=("$f")
done
[[ ${#manifests[@]} -gt 0 || ${#downloads[@]} -gt 0 ]] || die "niente da firmare in $OUT"

sums=$OUT/SHA256SUMS
: >"$sums.tmp"
for f in "${downloads[@]}"; do
	printf '%s  %s\n' "$(sha256_of "$f")" "$(basename "$f")" >>"$sums.tmp"
done
LC_ALL=C sort -k2 "$sums.tmp" >"$sums"
rm -f "$sums.tmp"
release_tool sign --key "$keydir/signing.key" "$sums"
log "SHA256SUMS: ${#downloads[@]} file"
cat "$sums" >&2
