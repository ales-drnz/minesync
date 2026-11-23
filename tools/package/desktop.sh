#!/usr/bin/env bash
# Pacchetto desktop di MineSync per una piattaforma.
#
#   tools/package/desktop.sh <platform> <outdir>
#
# <platform>: linux-x64 linux-arm64 windows-x64 macos-arm64 macos-x64. Gira
# sul sistema e sull'architettura della piattaforma (niente cross-compilazione;
# Git Bash su Windows). Compila l'app Flutter (release, chiave pubblica degli
# aggiornamenti da MINESYNC_UPDATE_PUBKEY), guard, CLI e launcher, e scrive in
# <outdir>:
#   MineSync-<v>-<platform>.AppImage | -windows-x64-setup.exe | .dmg
#   MineSync-<v>-<platform>-cli.tar.gz | .zip     CLI + guard
#   update/<platform>/manifest.json + archivio    aggiornamento (NON firmato:
#                                                 lo firma tools/package/sign.sh)
#
# Variabili:
#   MINESYNC_UPDATE_PUBKEY    chiave pubblica ed25519 (base64); senza, l'app
#                             non si aggiorna da sola (solo avviso)
#   MINESYNC_PKG_CONTAINER    Linux: "auto" (default: ubuntu:20.04 con docker
#                             se la glibc di qui è più nuova di 2.31),
#                             "ubuntu:20.04" o "none" (compila qui)
#   MINESYNC_GLIBC_CHECK      Linux: "error" (default) o "warn" se un binario
#                             chiede una glibc più nuova di 2.31
#   MINESYNC_SKIP_FLUTTER_BUILD=1   riusa la build Flutter già presente
#   MINESYNC_NO_DOWNLOAD=1    Linux: niente appimagetool, si ferma all'AppDir
#   MINESYNC_APPIMAGETOOL     Linux: appimagetool già presente (invece di
#                             scaricare quello fissato)
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[[ $# -eq 2 ]] || die "uso: $0 <platform> <outdir>"
PLATFORM=$1
case $PLATFORM in
linux-x64 | linux-arm64 | windows-x64 | macos-arm64 | macos-x64) ;;
*) die "piattaforma sconosciuta: $PLATFORM" ;;
esac
mkdir -p "$2"
OUT=$(cd "$2" && pwd)

# Linux in container (glibc 2.31): si rientra in questo script dentro
# l'immagine, con lo stesso repository e la stessa cartella d'uscita. Di
# default ("auto") il container si usa se la glibc di qui è più nuova di 2.31
# e c'è docker; "none" compila qui.
if [[ $PLATFORM == linux-* && -z ${MINESYNC_IN_CONTAINER:-} ]]; then
	container=${MINESYNC_PKG_CONTAINER:-auto}
	if [[ $container == auto ]]; then
		host_glibc=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
		container=none
		if [[ $(printf '%s\n%s\n' "${host_glibc:-0}" "$GLIBC_MAX" | sort -V | tail -1) != "$GLIBC_MAX" ]] &&
			command -v docker >/dev/null 2>&1; then
			container=ubuntu:20.04
		fi
	fi
	if [[ $container != none ]]; then
		MINESYNC_PKG_CONTAINER=$container exec "$PKG_DIR/linux/container.sh" "$PLATFORM" "$OUT"
	fi
fi

VERSION=$(read_version)
BASE_VERSION=$(base_version "$VERSION")
BUILD_NUMBER=$(build_number "$VERSION")

# --- controlli preliminari -----------------------------------------------------

host_platform() {
	local os arch
	case $(uname -s) in
	Linux) os=linux ;;
	Darwin) os=macos ;;
	MINGW* | MSYS* | CYGWIN*) os=windows ;;
	*) die "sistema non supportato: $(uname -s)" ;;
	esac
	case $(uname -m) in
	x86_64 | amd64) arch=x64 ;;
	aarch64 | arm64) arch=arm64 ;;
	*) die "architettura non supportata: $(uname -m)" ;;
	esac
	printf '%s-%s' "$os" "$arch"
}
HOST=$(host_platform)
[[ $HOST == "$PLATFORM" ]] || die "$PLATFORM si compila su $PLATFORM (qui: $HOST)"

# Le costanti di versione nel codice devono coincidere con VERSION: l'app la
# mostra e la manda all'hub, il launcher usa quella della cartella.
for f in apps/desktop/lib/src/state/session_state.dart:appVersion apps/cli/lib/minesync_cli.dart:cliVersion; do
	file=${f%%:*} name=${f##*:}
	got=$(sed -n "s/^const String $name = '\(.*\)';/\1/p" "$REPO/$file")
	[[ $got == "$VERSION" ]] || die "$file: $name = '$got', VERSION = '$VERSION'"
done

if [[ -z ${MINESYNC_UPDATE_PUBKEY:-} ]]; then
	log "ATTENZIONE: MINESYNC_UPDATE_PUBKEY vuota, l'app non si aggiornerà da sola"
fi

WORK=$REPO/build/package/$PLATFORM
rm -rf "$WORK"
mkdir -p "$WORK/bin" "$WORK/version"
EXE=""
[[ $PLATFORM == windows-* ]] && EXE=.exe

log "MineSync $VERSION per $PLATFORM -> $OUT"

# --- compilazione --------------------------------------------------------------

(cd "$REPO" && flutter pub get --enforce-lockfile)

case $PLATFORM in
linux-*) FLUTTER_TARGET=linux ;;
windows-*) FLUTTER_TARGET=windows ;;
macos-*) FLUTTER_TARGET=macos ;;
esac
if [[ -z ${MINESYNC_SKIP_FLUTTER_BUILD:-} ]]; then
	# La cache CMake di una build fatta fuori dal container (altro compilatore,
	# altro SDK Flutter) non si riusa.
	[[ -n ${MINESYNC_IN_CONTAINER:-} ]] && rm -rf "$REPO/apps/desktop/build/linux"
	log "flutter build $FLUTTER_TARGET"
	(cd "$REPO/apps/desktop" && flutter build "$FLUTTER_TARGET" --release \
		--dart-define=MINESYNC_UPDATE_PUBKEY="${MINESYNC_UPDATE_PUBKEY:-}" \
		--build-name="$BASE_VERSION" --build-number="$BUILD_NUMBER")
fi

log "guard, CLI e launcher"
(
	cd "$REPO"
	dart compile exe apps/guard/bin/minesync_guard.dart -o "$WORK/bin/minesync-guard$EXE"
	dart compile exe apps/cli/bin/minesync_cli.dart -o "$WORK/bin/minesync$EXE"
	dart compile exe apps/launcher/bin/minesync_launcher.dart -o "$WORK/bin/minesync-launcher$EXE"
	# Il tool di rilascio compilato una volta sola (pack qui, sign dopo).
	dart compile exe apps/launcher/bin/minesync_release.dart -o "$WORK/bin/minesync_release$EXE"
)
export MINESYNC_RELEASE=$WORK/bin/minesync_release$EXE
"$WORK/bin/minesync-launcher$EXE" --selftest
"$WORK/bin/minesync$EXE" --version

# --- passi per sistema -----------------------------------------------------------

# Impacchetta $WORK/version come aggiornamento in $OUT/update/<platform>/ e
# copia il manifest nella cartella (la rende una cartella di versione
# completa, quella che il pacchetto installa). Il pack firma sempre: si usa
# una chiave usa-e-getta e si butta la firma, la vera la mette sign.sh sugli
# stessi byte del manifest.
pack_payload() {
	local entry=$1 launcher=${2:-}
	local keydir=$WORK/throwaway-key dest=$OUT/update/$PLATFORM
	rm -rf "$dest" "$keydir"
	release_tool keygen --out "$keydir" >/dev/null
	local args=(pack --key "$keydir/signing.key" --version "$VERSION" --platform "$PLATFORM"
		--entry "$entry" --src "$WORK/version" --out "$OUT")
	[[ -n $launcher ]] && args+=(--launcher "$launcher")
	release_tool "${args[@]}"
	rm -rf "$keydir" "$dest/manifest.json.sig"
	cp "$dest/manifest.json" "$WORK/version/.manifest.json"
}

# Archivio della sola CLI (minesync + guard) per chi la usa senza l'app.
cli_archive() {
	local name=MineSync-$VERSION-$PLATFORM-cli dir=$WORK/cli
	rm -rf "$dir"
	mkdir -p "$dir/$name"
	cp "$WORK/bin/minesync$EXE" "$WORK/bin/minesync-guard$EXE" "$REPO/LICENSE" "$dir/$name/"
	if [[ $PLATFORM == windows-* ]]; then
		rm -f "$OUT/$name.zip"
		powershell.exe -NoProfile -NonInteractive -Command \
			"Compress-Archive -Path '$(native_path "$dir/$name")' -DestinationPath '$(native_path "$OUT/$name.zip")'"
	else
		tar -C "$dir" -czf "$OUT/$name.tar.gz" "$name"
	fi
}

case $PLATFORM in
linux-*) source "$PKG_DIR/linux/appimage.sh" ;;
windows-*) source "$PKG_DIR/windows/installer.sh" ;;
macos-*) source "$PKG_DIR/macos/app.sh" ;;
esac

assemble_version # cartella di versione in $WORK/version, poi pack_payload
build_package    # download per l'utente in $OUT
cli_archive

log "fatto:"
(cd "$OUT" && find . -maxdepth 3 -type f ! -path './.*' | sort) >&2
