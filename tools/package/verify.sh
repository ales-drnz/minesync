#!/usr/bin/env bash
# Controlli del pacchetto di una piattaforma, senza aprire finestre: firme e
# checksum, struttura del pacchetto, cartella di versione uguale al manifest
# dell'aggiornamento, launcher (--selftest), CLI (--version).
#
#   tools/package/verify.sh <platform> <outdir>
#
# MINESYNC_VERIFY_PUBKEY: chiave pubblica (base64) con cui verificare le firme
# messe da sign.sh; senza, si controlla tutto tranne le firme.
#
# Linux: estrae l'AppImage (--appimage-extract), controlla la glibc e prova
#   l'installazione della versione di partenza col launcher, senza DISPLAY né
#   WAYLAND_DISPLAY (l'app non può aprire finestre ed esce subito).
# Windows: installa per utente in silenzio in una cartella temporanea, controlla
#   launcher, versione, state.json e collegamento, poi disinstalla.
# macOS: monta il dmg in sola lettura, controlla firma ad-hoc, Info.plist,
#   architetture e bootstrap.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[[ $# -eq 2 ]] || die "uso: $0 <platform> <outdir>"
PLATFORM=$1
OUT=$(cd "$2" && pwd)
VERSION=$(read_version)
NAME=$(download_name "$VERSION" "$PLATFORM")
[[ -f $OUT/$NAME ]] || die "manca $OUT/$NAME"
TMP=$(mktemp -d)
# su Windows il disinstallatore può tenere aperto un file ancora per poco:
# la pulizia non deve far fallire la verifica
cleanup_tmp() { rm -rf "$TMP" 2>/dev/null || { sleep 2; rm -rf "$TMP" 2>/dev/null || true; }; }
trap cleanup_tmp EXIT

pub_get
verify_args=("$OUT" --version "$VERSION")
[[ -n ${MINESYNC_VERIFY_PUBKEY:-} ]] && verify_args+=(--pub "$MINESYNC_VERIFY_PUBKEY")
verify_release() { (cd "$REPO" && dart run tools/package/verify_release.dart "$@"); }

expect_selftest() {
	local out
	out=$("$@" --selftest)
	[[ $out == minesync-launcher\ build=*\ protocol=* ]] || die "--selftest: '$out'"
	log "launcher: $out"
}

expect_cli() {
	local out
	out=$("$1" --version)
	[[ $out == "minesync $VERSION" ]] || die "CLI --version: '$out'"
	log "CLI: $out"
}

check_cli_archive() {
	local a=$OUT/MineSync-$VERSION-$PLATFORM-cli list
	if [[ -f $a.tar.gz ]]; then
		list=$(tar -tzf "$a.tar.gz")
	elif [[ -f $a.zip ]]; then
		list=$(unzip -Z1 "$a.zip" 2>/dev/null || powershell.exe -NoProfile -Command \
			"Add-Type -A System.IO.Compression.FileSystem; [IO.Compression.ZipFile]::OpenRead('$(native_path "$a.zip")').Entries.FullName")
	else
		die "manca l'archivio della CLI"
	fi
	# Compress-Archive di Windows PowerShell scrive i percorsi con la barra rovesciata
	grep -Eq '(^|[/\\])minesync(\.exe)?[[:space:]]*$' <<<"$list" || die "CLI assente nell'archivio"
	grep -Eq '(^|[/\\])minesync-guard(\.exe)?[[:space:]]*$' <<<"$list" || die "guard assente nell'archivio"
	log "archivio della CLI: ok"
}

verify_linux() {
	local img=$OUT/$NAME root
	[[ -x $img ]] || die "$NAME non è eseguibile"
	(cd "$TMP" && "$img" --appimage-extract >/dev/null)
	root=$TMP/squashfs-root
	[[ -x $root/AppRun && -f $root/$APP_ID_LINUX.desktop && -f $root/$APP_ID_LINUX.png ]] ||
		die "AppDir incompleta"
	grep -q "^StartupWMClass=$APP_ID_LINUX$" "$root/$APP_ID_LINUX.desktop" || die "StartupWMClass"
	expect_selftest "$root/AppRun"
	[[ -x $root/bootstrap/minesync-guard ]] || die "guard mancante accanto all'app"
	expect_cli "$root/bootstrap/minesync"
	verify_release "${verify_args[@]}" --tree "$PLATFORM" "$root/bootstrap"
	check_glibc "$root"

	# Installazione della versione di partenza, come al primo avvio. Nessun
	# display raggiungibile (niente DISPLAY né WAYLAND_DISPLAY, backend X11,
	# XDG_RUNTIME_DIR vuota: libwayland non trova nemmeno wayland-0), quindi
	# GTK non apre finestre e l'app esce subito con errore: conta solo che il
	# launcher abbia copiato bootstrap/ e scritto lo stato.
	local data=$TMP/data
	mkdir -p "$TMP/xdg-runtime"
	chmod 700 "$TMP/xdg-runtime"
	env -u DISPLAY -u WAYLAND_DISPLAY -u DBUS_SESSION_BUS_ADDRESS GDK_BACKEND=x11 XDG_RUNTIME_DIR="$TMP/xdg-runtime" \
		APPIMAGE="$img" APPDIR="$root" XDG_DATA_HOME="$data" MINESYNC_HEALTH_TIMEOUT_S=5 \
		timeout 60 "$root/AppRun" >"$TMP/launch.log" 2>&1 || true
	grep -q "installo la versione del pacchetto $VERSION" "$TMP/launch.log" ||
		die "il launcher non ha installato la versione di partenza: $(cat "$TMP/launch.log")"
	grep -q "\"current\": \"$VERSION\"" "$data/MineSync/state.json" || die "state.json"
	verify_release "${verify_args[@]}" --tree "$PLATFORM" "$data/MineSync/versions/$VERSION"
	log "bootstrap installato in XDG_DATA_HOME/MineSync/versions/$VERSION"
}

verify_windows() {
	local setup=$OUT/$NAME dir=$TMP/MineSync i
	local lnk
	lnk="$(cygpath -u "$APPDATA")/Microsoft/Windows/Start Menu/Programs/MineSync.lnk"
	# Installazione per utente, silenziosa: nessuna richiesta UAC possibile
	# (PrivilegesRequired=lowest), nessuna finestra.
	MSYS2_ARG_CONV_EXCL='*' "$setup" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- \
		"/DIR=$(native_path "$dir")" "/LOG=$(native_path "$TMP/setup.log")" ||
		die "installazione non riuscita: $(cat "$TMP/setup.log" 2>/dev/null)"
	[[ -f $dir/MineSync.exe && -f $dir/MineSync.ico && -f $dir/unins000.exe ]] || die "installazione incompleta"
	expect_selftest "$dir/MineSync.exe"
	verify_release "${verify_args[@]}" --pe-gui "$dir/MineSync.exe" --pe-gui "$dir/versions/$VERSION/minesync-launcher.exe" \
		--tree "$PLATFORM" "$dir/versions/$VERSION"
	[[ -f $dir/versions/$VERSION/minesync-guard.exe ]] || die "guard mancante accanto all'app"
	expect_cli "$dir/versions/$VERSION/minesync.exe"
	tr -d '\r' <"$dir/state.json" | grep -q "\"current\": \"$VERSION\"" || die "state.json: $(cat "$dir/state.json")"
	[[ -f $lnk ]] || die "collegamento del menu Start mancante: $lnk"
	if grep -qi 'elevat\|administrator' "$TMP/setup.log"; then
		log "ATTENZIONE: il log dell'installer parla di privilegi elevati"
	fi
	log "installato in $dir, collegamento $lnk"

	MSYS2_ARG_CONV_EXCL='*' "$dir/unins000.exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
	# Il disinstallatore si copia in %TEMP% ed esce subito: si aspetta.
	for i in $(seq 1 60); do
		[[ ! -e $dir/MineSync.exe && ! -e $lnk ]] && break
		sleep 2
	done
	[[ ! -e $dir/MineSync.exe ]] || die "disinstallazione: MineSync.exe ancora presente"
	[[ ! -e $dir/versions ]] || die "disinstallazione: versions ancora presente"
	[[ ! -e $lnk ]] || die "disinstallazione: collegamento ancora presente"
	log "disinstallato"
}

verify_macos() {
	# mnt resta globale: la pulizia all'uscita lo usa dopo la fine della funzione
	local dmg=$OUT/$NAME arch
	MNT=$TMP/mnt
	local mnt=$MNT
	case $PLATFORM in macos-arm64) arch=arm64 ;; macos-x64) arch=x86_64 ;; esac
	mkdir -p "$mnt"
	hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$dmg" >/dev/null
	cleanup_tmp() {
		hdiutil detach "$MNT" -force >/dev/null 2>&1 || true
		rm -rf "$TMP"
	}
	local app=$mnt/MineSync.app
	[[ -L $mnt/Applications && $(readlink "$mnt/Applications") == /Applications ]] || die "manca il link ad Applications"
	codesign --verify --deep --strict --verbose=2 "$app"
	local plist=$app/Contents/Info.plist pb=/usr/libexec/PlistBuddy
	[[ $("$pb" -c 'Print :CFBundleIdentifier' "$plist") == "$APP_ID_MAC_LAUNCHER" ]] || die "CFBundleIdentifier"
	[[ $("$pb" -c 'Print :CFBundleExecutable' "$plist") == MineSync ]] || die "CFBundleExecutable"
	[[ $("$pb" -c 'Print :LSMinimumSystemVersion' "$plist") == 13.0 ]] || die "LSMinimumSystemVersion"
	expect_selftest "$app/Contents/MacOS/MineSync"
	local boot=$app/Contents/Resources/bootstrap inner
	inner=$boot/MineSync.app
	verify_release "${verify_args[@]}" --tree "$PLATFORM" "$boot"
	[[ $("$pb" -c 'Print :CFBundleIdentifier' "$inner/Contents/Info.plist") == "$APP_ID_MAC_APP" ]] || die "id dell'app interna"
	[[ $("$pb" -c 'Print :LSMinimumSystemVersion' "$inner/Contents/Info.plist") == 13.0 ]] || die "LSMinimumSystemVersion interna"
	codesign --verify --deep --strict "$inner"
	local f
	for f in "$app/Contents/MacOS/MineSync" "$inner/Contents/MacOS/$APP_BINARY" \
		"$inner/Contents/MacOS/minesync-guard" "$inner/Contents/MacOS/minesync"; do
		[[ $(lipo -archs "$f") == "$arch" ]] || die "$f: architetture $(lipo -archs "$f")"
	done
	expect_cli "$inner/Contents/MacOS/minesync"
	log "dmg: ok"
}

case $PLATFORM in
linux-*) verify_linux ;;
windows-*) verify_windows ;;
macos-*) verify_macos ;;
*) die "piattaforma sconosciuta: $PLATFORM" ;;
esac
check_cli_archive
# Firme, checksum e archivio dell'aggiornamento (anche senza --tree).
verify_release "${verify_args[@]}"
log "$PLATFORM: pacchetto verificato"
