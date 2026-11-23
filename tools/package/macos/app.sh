# MineSync.app e dmg per macOS (incluso da desktop.sh: usa VERSION,
# BASE_VERSION, BUILD_NUMBER, PLATFORM, WORK, OUT, REPO, PKG_DIR e pack_payload).
#
#   MineSync.app/                         il launcher (id io.github.alesdrnz.minesync)
#     Contents/Info.plist                 LSUIElement: niente icona nel Dock per
#                                         il launcher, la mostra l'app vera
#     Contents/MacOS/MineSync             minesync-launcher compilato AOT
#     Contents/Resources/MineSync.icns
#     Contents/Resources/bootstrap/       cartella di versione completa:
#       MineSync.app/                     l'app Flutter (id del runner), con
#         Contents/MacOS/minesync_desktop minesync-guard e minesync accanto
#       .manifest.json
#
# Il launcher copia bootstrap/ in ~/Library/Application Support/MineSync/
# versions/<v>/ e avvia MineSync.app/Contents/MacOS/minesync_desktop da lì.
#
# Firma ad-hoc (codesign -s -): senza certificato Apple, ma su Apple Silicon
# il kernel non esegue codice arm64 senza firma, e ogni modifica al bundle
# (Info.plist, guard e CLI aggiunti, architetture tolte) invalida quella
# messa dal linker. Si firma dall'interno verso l'esterno.

FLUTTER_APP=$REPO/apps/desktop/build/macos/Build/Products/Release/$APP_BINARY.app
case $PLATFORM in
macos-arm64) MAC_ARCH=arm64 ;;
macos-x64) MAC_ARCH=x86_64 ;;
esac
MAC_MIN=13.0
PLISTBUDDY=/usr/libexec/PlistBuddy

plist_set() { # file chiave tipo valore
	"$PLISTBUDDY" -c "Set :$2 $4" "$1" 2>/dev/null || "$PLISTBUDDY" -c "Add :$2 $3 $4" "$1"
}

adhoc_sign() {
	codesign --force --sign - --timestamp=none "$@"
}

assemble_version() {
	[[ -d $FLUTTER_APP ]] || die "app Flutter mancante: $FLUTTER_APP"
	local app=$WORK/version/MineSync.app
	# La build release di Flutter è universale: si tiene solo l'architettura
	# della piattaforma (ditto --arch sfoltisce i Mach-O, metà dimensione).
	ditto --arch "$MAC_ARCH" "$FLUTTER_APP" "$app"
	local plist=$app/Contents/Info.plist
	plist_set "$plist" CFBundleName string MineSync
	plist_set "$plist" CFBundleDisplayName string MineSync
	plist_set "$plist" LSMinimumSystemVersion string "$MAC_MIN"
	cp "$WORK/bin/minesync-guard" "$WORK/bin/minesync" "$app/Contents/MacOS/"
	chmod 755 "$app/Contents/MacOS/minesync-guard" "$app/Contents/MacOS/minesync"
	adhoc_sign "$app/Contents/MacOS/minesync-guard" "$app/Contents/MacOS/minesync"
	adhoc_sign --deep --entitlements "$REPO/apps/desktop/macos/Runner/Release.entitlements" "$app"
	codesign --verify --deep --strict "$app"
	local a
	a=$(lipo -archs "$app/Contents/MacOS/$APP_BINARY")
	[[ $a == "$MAC_ARCH" ]] || die "architetture dell'app: '$a' (attesa $MAC_ARCH)"
	pack_payload "MineSync.app/Contents/MacOS/$APP_BINARY"
}

write_launcher_plist() {
	cat >"$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>MineSync</string>
	<key>CFBundleIconFile</key>
	<string>MineSync</string>
	<key>CFBundleIdentifier</key>
	<string>$APP_ID_MAC_LAUNCHER</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>MineSync</string>
	<key>CFBundleDisplayName</key>
	<string>MineSync</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$BASE_VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>LSMinimumSystemVersion</key>
	<string>$MAC_MIN</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.games</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>BSD-3-Clause</string>
</dict>
</plist>
EOF
}

build_package() {
	local app=$WORK/MineSync.app
	rm -rf "$app"
	mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
	cp "$WORK/bin/minesync-launcher" "$app/Contents/MacOS/MineSync"
	chmod 755 "$app/Contents/MacOS/MineSync"
	cp "$REPO/packages/ms_ui/assets/brand/MineSync.icns" "$app/Contents/Resources/MineSync.icns"
	ditto "$WORK/version" "$app/Contents/Resources/bootstrap"
	write_launcher_plist "$app/Contents/Info.plist"
	plutil -lint "$app/Contents/Info.plist" >/dev/null
	printf 'APPL????' >"$app/Contents/PkgInfo"
	# L'app interna è già firmata e sigillata come risorsa del launcher.
	adhoc_sign --deep "$app"
	codesign --verify --deep --strict --verbose=2 "$app"

	local stage=$WORK/dmg dest i
	dest=$OUT/$(download_name "$VERSION" "$PLATFORM")
	rm -rf "$stage" "$dest"
	mkdir -p "$stage"
	ditto "$app" "$stage/MineSync.app"
	ln -s /Applications "$stage/Applications"
	# hdiutil sui runner a volte risponde "Resource busy": si riprova.
	for i in 1 2 3; do
		if hdiutil create -volname MineSync -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dest"; then
			return 0
		fi
		log "hdiutil create non riuscito (tentativo $i)"
		sleep 5
	done
	die "dmg non creato"
}
