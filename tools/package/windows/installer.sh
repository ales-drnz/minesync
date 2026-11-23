# Installer Windows per utente (incluso da desktop.sh: usa VERSION,
# BASE_VERSION, PLATFORM, WORK, OUT, REPO, PKG_DIR e pack_payload).
#
# Installa in %LOCALAPPDATA%\MineSync senza diritti di amministratore:
#   MineSync.exe                    launcher (sottosistema GUI, niente console)
#   MineSync.ico                    icona del collegamento (il launcher non ne ha)
#   state.json                      current = versione installata
#   versions\<v>\                   cartella di versione completa:
#     minesync_desktop.exe, *.dll, data\   bundle Flutter
#     minesync-guard.exe, minesync.exe     accanto all'eseguibile dell'app
#     minesync-launcher.exe                launcher della versione (il launcher
#                                          si aggiorna da qui, dopo --selftest)
#     .manifest.json
# e il collegamento "MineSync" nel menu Start con AUMID "MineSync" (quello dei
# toast di local_notifier, vedi apps/desktop/lib/src/platform/desktop_notifications.dart).

FLUTTER_BUNDLE=$REPO/apps/desktop/build/windows/x64/runner/Release
# Versione di Inno Setup se sul runner manca (windows-latest ha la 6.7.1).
INNO_VERSION=6.7.1

assemble_version() {
	[[ -f $FLUTTER_BUNDLE/$APP_BINARY.exe ]] || die "bundle Flutter mancante: $FLUTTER_BUNDLE"
	cp -r "$FLUTTER_BUNDLE/." "$WORK/version/"
	cp "$WORK/bin/minesync-guard.exe" "$WORK/bin/minesync.exe" "$WORK/version/"
	# Launcher senza finestra di console, prima di copiarlo ovunque.
	release_tool gui-subsystem "$WORK/bin/minesync-launcher.exe"
	cp "$WORK/bin/minesync-launcher.exe" "$WORK/version/minesync-launcher.exe"
	pack_payload "$APP_BINARY.exe" minesync-launcher.exe
}

find_iscc() {
	local c
	for c in "${ISCC:-}" "/c/Program Files (x86)/Inno Setup 6/ISCC.exe" "/c/Program Files/Inno Setup 6/ISCC.exe"; do
		[[ -n $c && -f $c ]] && {
			printf '%s' "$c"
			return 0
		}
	done
	command -v iscc 2>/dev/null || command -v ISCC 2>/dev/null || return 1
}

build_package() {
	local iscc
	if ! iscc=$(find_iscc); then
		log "Inno Setup assente: installo la $INNO_VERSION con choco"
		choco install innosetup --version "$INNO_VERSION" -y --no-progress >&2
		iscc=$(find_iscc) || die "ISCC.exe non trovato"
	fi
	local stage=$WORK/installer
	rm -rf "$stage"
	mkdir -p "$stage"
	cp "$WORK/bin/minesync-launcher.exe" "$stage/MineSync.exe"
	cp "$REPO/apps/desktop/windows/runner/resources/app_icon.ico" "$stage/MineSync.ico"
	local name
	name=$(download_name "$VERSION" "$PLATFORM")
	rm -f "$OUT/$name"
	# MSYS2_ARG_CONV_EXCL: Git Bash non deve trasformare /DNome=... in percorsi.
	MSYS2_ARG_CONV_EXCL='*' "$iscc" /Q \
		"/DAppVersion=$VERSION" \
		"/DAppBaseVersion=$BASE_VERSION" \
		"/DStageDir=$(native_path "$stage")" \
		"/DVersionDir=$(native_path "$WORK/version")" \
		"/DLicenseFile=$(native_path "$REPO/LICENSE")" \
		"/DOutputDir=$(native_path "$OUT")" \
		"/DOutputBaseName=${name%.exe}" \
		"/DAppAumid=$APP_AUMID" \
		"$(native_path "$PKG_DIR/windows/minesync.iss")"
	[[ -f $OUT/$name ]] || die "installer non creato: $OUT/$name"
}
