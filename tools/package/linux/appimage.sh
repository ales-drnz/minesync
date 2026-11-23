# AppImage per Linux (incluso da desktop.sh: usa VERSION, PLATFORM, WORK,
# OUT, REPO, PKG_DIR e pack_payload).
#
#   AppDir/
#     AppRun                       il launcher (minesync-launcher compilato AOT)
#     <app-id>.desktop, <app-id>.png, .DirIcon
#     usr/share/applications, usr/share/icons/hicolor/<n>x<n>/apps
#     bootstrap/                   cartella di versione completa:
#       minesync_desktop, lib/, data/   bundle Flutter
#       minesync-guard, minesync        accanto all'eseguibile dell'app (lì li
#                                       cerca guardCommand())
#       .manifest.json
#
# Il runtime dell'AppImage imposta APPIMAGE e APPDIR: il launcher installa
# bootstrap/ in $XDG_DATA_HOME/MineSync/versions/<v> (vedi
# apps/launcher/lib/src/layout.dart) e da lì avvia l'app.

# appimagetool e runtime di tipo 2 (statico, non serve libfuse2 sul PC
# dell'utente), versioni fissate con lo SHA-256 pubblicato da GitHub.
APPIMAGETOOL_VERSION=1.9.1
APPIMAGE_RUNTIME_VERSION=20251108
declare_appimage_sha() {
	case $1 in
	x86_64)
		APPIMAGETOOL_SHA=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
		RUNTIME_SHA=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d
		;;
	aarch64)
		APPIMAGETOOL_SHA=f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158
		RUNTIME_SHA=00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444
		;;
	esac
}

case $PLATFORM in
linux-x64)
	APPIMAGE_ARCH=x86_64
	FLUTTER_BUNDLE=$REPO/apps/desktop/build/linux/x64/release/bundle
	;;
linux-arm64)
	APPIMAGE_ARCH=aarch64
	FLUTTER_BUNDLE=$REPO/apps/desktop/build/linux/arm64/release/bundle
	;;
esac

assemble_version() {
	[[ -x $FLUTTER_BUNDLE/$APP_BINARY ]] || die "bundle Flutter mancante: $FLUTTER_BUNDLE"
	cp -a "$FLUTTER_BUNDLE/." "$WORK/version/"
	cp "$WORK/bin/minesync-guard" "$WORK/bin/minesync" "$WORK/version/"
	chmod 755 "$WORK/version/$APP_BINARY" "$WORK/version/minesync-guard" "$WORK/version/minesync"
	check_glibc "$WORK/version"
	check_glibc "$WORK/bin"
	# Il launcher non va nell'aggiornamento: l'AppImage è il launcher e non
	# si sostituisce da sola (cambia solo scaricando un'AppImage nuova).
	pack_payload "$APP_BINARY"
}

write_desktop_file() {
	cat >"$1" <<EOF
[Desktop Entry]
Type=Application
Name=MineSync
GenericName=Minecraft world sync
GenericName[it]=Sincronizzazione dei mondi di Minecraft
Comment=Play on your Minecraft server with friends, one host at a time
Comment[it]=Giocate sul vostro server Minecraft tra amici, un host alla volta
Exec=minesync
Icon=$APP_ID_LINUX
Terminal=false
Categories=Game;
Keywords=minecraft;server;sync;world;
StartupWMClass=$APP_ID_LINUX
X-AppImage-Version=$VERSION
EOF
}

build_package() {
	local appdir=$WORK/AppDir s
	rm -rf "$appdir"
	mkdir -p "$appdir/usr/share/applications"
	cp "$WORK/bin/minesync-launcher" "$appdir/AppRun"
	chmod 755 "$appdir/AppRun"
	cp -a "$WORK/version" "$appdir/bootstrap"
	write_desktop_file "$appdir/$APP_ID_LINUX.desktop"
	cp "$appdir/$APP_ID_LINUX.desktop" "$appdir/usr/share/applications/"
	for s in 16 24 32 48 64 128 256 512; do
		mkdir -p "$appdir/usr/share/icons/hicolor/${s}x$s/apps"
		cp "$REPO/packages/ms_ui/assets/brand/minesync-$s.png" \
			"$appdir/usr/share/icons/hicolor/${s}x$s/apps/$APP_ID_LINUX.png"
	done
	cp "$REPO/packages/ms_ui/assets/brand/minesync-256.png" "$appdir/$APP_ID_LINUX.png"
	ln -sf "$APP_ID_LINUX.png" "$appdir/.DirIcon"

	if [[ -n ${MINESYNC_NO_DOWNLOAD:-} && -z ${MINESYNC_APPIMAGETOOL:-} ]]; then
		log "MINESYNC_NO_DOWNLOAD: AppDir pronta in $appdir, AppImage non creata"
		return 0
	fi
	local cache=${MINESYNC_PKG_CACHE:-$REPO/build/package/cache} tool runtime
	declare_appimage_sha "$APPIMAGE_ARCH"
	runtime=$cache/runtime-$APPIMAGE_RUNTIME_VERSION-$APPIMAGE_ARCH
	fetch_verified "https://github.com/AppImage/type2-runtime/releases/download/$APPIMAGE_RUNTIME_VERSION/runtime-$APPIMAGE_ARCH" \
		"$runtime" "$RUNTIME_SHA"
	if [[ -n ${MINESYNC_APPIMAGETOOL:-} ]]; then
		tool=$MINESYNC_APPIMAGETOOL
	else
		tool=$cache/appimagetool-$APPIMAGETOOL_VERSION-$APPIMAGE_ARCH.AppImage
		fetch_verified "https://github.com/AppImage/appimagetool/releases/download/$APPIMAGETOOL_VERSION/appimagetool-$APPIMAGE_ARCH.AppImage" \
			"$tool" "$APPIMAGETOOL_SHA"
		chmod 755 "$tool"
	fi
	local dest
	dest=$OUT/$(download_name "$VERSION" "$PLATFORM")
	rm -f "$dest"
	# APPIMAGE_EXTRACT_AND_RUN: appimagetool è a sua volta un'AppImage e nei
	# container (e sui runner) FUSE non c'è.
	ARCH=$APPIMAGE_ARCH VERSION=$VERSION APPIMAGE_EXTRACT_AND_RUN=1 \
		"$tool" --no-appstream --runtime-file "$runtime" "$appdir" "$dest"
	chmod 755 "$dest"
}
