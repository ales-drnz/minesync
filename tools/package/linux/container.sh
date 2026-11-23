#!/usr/bin/env bash
# Esegue tools/package/desktop.sh dentro un container Ubuntu 20.04 (glibc
# 2.31), con il repository e la cartella d'uscita montati agli stessi
# percorsi e l'utente di chi lancia (i file creati restano suoi).
#
#   tools/package/linux/container.sh <linux-x64|linux-arm64> <outdir>
#
# Lo chiama desktop.sh quando MINESYNC_PKG_CONTAINER è impostata (il valore è
# l'immagine di partenza; il Dockerfile qui accanto usa ubuntu:20.04).
# FLUTTER_VERSION: tag di Flutter; di default quello di .github/workflows/ci.yml.
set -euo pipefail
source "$(dirname "$0")/../lib.sh"

[[ $# -eq 2 ]] || die "uso: $0 <platform> <outdir>"
platform=$1
mkdir -p "$2"
out=$(cd "$2" && pwd)
command -v docker >/dev/null || die "serve docker"

base=${MINESYNC_PKG_CONTAINER:-ubuntu:20.04}
[[ $base == ubuntu:20.04 ]] || die "il Dockerfile è per ubuntu:20.04, non $base"
flutter_version=${FLUTTER_VERSION:-$(sed -n 's/^ *FLUTTER_VERSION: *"\(.*\)"/\1/p' "$REPO/.github/workflows/ci.yml" | head -1)}
[[ -n $flutter_version ]] || die "FLUTTER_VERSION sconosciuta"
image=minesync-pkg-linux:$flutter_version

log "immagine $image (da $base)"
docker build --build-arg FLUTTER_VERSION="$flutter_version" -t "$image" "$PKG_DIR/linux"

# La cache dei download (appimagetool, runtime) resta nel repository, sotto
# build/, così si riusa tra una build e l'altra.
docker run --rm \
	--user "$(id -u):$(id -g)" \
	-e HOME=/tmp/home \
	-e MINESYNC_IN_CONTAINER=1 \
	-e MINESYNC_UPDATE_PUBKEY \
	-e MINESYNC_GLIBC_CHECK \
	-e MINESYNC_SKIP_FLUTTER_BUILD \
	-e MINESYNC_NO_DOWNLOAD \
	-v "$REPO:$REPO" \
	-v "$out:$out" \
	-w "$REPO" \
	"$image" \
	bash -c 'mkdir -p "$HOME" && exec tools/package/desktop.sh "$1" "$2"' _ "$platform" "$out"
