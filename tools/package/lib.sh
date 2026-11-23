# Funzioni comuni degli script di pacchettizzazione (da includere con
# `source`, non da eseguire). Bash 3.2+ (macOS) e Git Bash su Windows.

# Radice del repository (tools/package/..).
PKG_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$PKG_DIR/../.." && pwd)

log() { printf '== %s\n' "$*" >&2; }
die() {
	printf 'errore: %s\n' "$*" >&2
	exit 1
}

# Versione unica del prodotto (file VERSION alla radice).
read_version() {
	local v
	v=$(tr -d ' \r\n' <"$REPO/VERSION")
	[[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die "VERSION non è semver: '$v'"
	printf '%s' "$v"
}

# Parte numerica (senza pre-release): quella che accettano le risorse di
# versione di Windows e CFBundleShortVersionString di macOS.
base_version() { printf '%s' "${1%%-*}"; }

# Numero di build intero e crescente: major*10000 + minor*100 + patch
# (0.1.0 -> 100). Sta sotto 65535 finché major < 6, il limite di Windows.
build_number() {
	local b major minor patch
	b=$(base_version "$1")
	IFS=. read -r major minor patch <<<"$b"
	printf '%d' $((major * 10000 + minor * 100 + patch))
}

# SHA-256 esadecimale di un file (sha256sum su Linux e Git Bash, shasum su macOS).
sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

# Scarica $1 in $2 e controlla che lo SHA-256 sia $3 (download in un file
# temporaneo: un file a metà o alterato non resta mai al posto giusto).
fetch_verified() {
	local url=$1 dest=$2 want=$3 got
	if [[ -f $dest ]] && [[ $(sha256_of "$dest") == "$want" ]]; then return 0; fi
	mkdir -p "$(dirname "$dest")"
	log "scarico $url"
	curl -fsSL --retry 3 -o "$dest.part" "$url" || die "download non riuscito: $url"
	got=$(sha256_of "$dest.part")
	if [[ $got != "$want" ]]; then
		rm -f "$dest.part"
		die "checksum sbagliato per $url: $got (atteso $want)"
	fi
	mv "$dest.part" "$dest"
}

# Percorso nativo (C:\...) per i programmi Windows lanciati da Git Bash.
native_path() {
	if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

# Esegue il tool di rilascio del launcher (keygen, pack, sign, gui-subsystem).
# MINESYNC_RELEASE può indicare un binario già compilato.
release_tool() {
	if [[ -n ${MINESYNC_RELEASE:-} ]]; then
		"$MINESYNC_RELEASE" "$@"
	else
		(cd "$REPO" && dart run apps/launcher/bin/minesync_release.dart "$@")
	fi
}

# pub get del workspace (serve anche dopo una build in container, che lascia
# in .dart_tool percorsi validi solo dentro il container).
pub_get() {
	if command -v flutter >/dev/null 2>&1; then
		(cd "$REPO" && flutter pub get --enforce-lockfile >/dev/null)
	else
		(cd "$REPO" && dart pub get --enforce-lockfile >/dev/null)
	fi
}

# Nomi dei file scaricabili dagli utenti per una versione e piattaforma.
download_name() {
	local v=$1 platform=$2
	case $platform in
	linux-*) printf 'MineSync-%s-%s.AppImage' "$v" "$platform" ;;
	windows-*) printf 'MineSync-%s-%s-setup.exe' "$v" "$platform" ;;
	macos-*) printf 'MineSync-%s-%s.dmg' "$v" "$platform" ;;
	*) die "piattaforma sconosciuta: $platform" ;;
	esac
}

# glibc più nuova accettata (minimo dichiarato: 2.31, Ubuntu 20.04 / Debian 11).
GLIBC_MAX=2.31

# Controlla con objdump che nessun ELF in $1 chieda simboli GLIBC_x.y più
# nuovi di GLIBC_MAX. Stampa il massimo trovato.
check_glibc() {
	local dir=$1 worst=0.0 f v bad=0
	command -v objdump >/dev/null || die "serve objdump (binutils) per controllare la glibc"
	while IFS= read -r -d '' f; do
		head -c 4 "$f" 2>/dev/null | grep -q $'\x7fELF' || continue
		v=$(objdump -T "$f" 2>/dev/null | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/GLIBC_//' | sort -V | tail -1 || true)
		[[ -z $v ]] && continue
		if [[ $(printf '%s\n%s\n' "$v" "$GLIBC_MAX" | sort -V | tail -1) != "$GLIBC_MAX" ]]; then
			log "glibc $v richiesta da ${f#"$dir"/}"
			bad=1
		fi
		[[ $(printf '%s\n%s\n' "$v" "$worst" | sort -V | tail -1) == "$v" ]] && worst=$v
	done < <(find "$dir" -type f -print0)
	log "glibc massima richiesta: $worst (limite $GLIBC_MAX)"
	if [[ $bad == 1 ]]; then
		if [[ ${MINESYNC_GLIBC_CHECK:-error} == warn ]]; then
			log "ATTENZIONE: build non adatta alla glibc $GLIBC_MAX (compilare con MINESYNC_PKG_CONTAINER=ubuntu:20.04)"
		else
			die "build non adatta alla glibc $GLIBC_MAX: compilare con MINESYNC_PKG_CONTAINER=ubuntu:20.04"
		fi
	fi
}

# Identità dell'app (dai progetti runner di apps/desktop).
APP_ID_LINUX=io.github.alesdrnz.minesync_desktop
APP_BINARY=minesync_desktop
# Il launcher macOS (MineSync.app) ha un id suo: l'app Flutter al suo interno
# tiene quello del runner, e due bundle con lo stesso id confondono
# LaunchServices e le notifiche.
APP_ID_MAC_APP=io.github.alesdrnz.minesyncDesktop
APP_ID_MAC_LAUNCHER=io.github.alesdrnz.minesync
# AUMID dei toast di Windows: local_notifier usa il nome dell'app.
APP_AUMID=MineSync
