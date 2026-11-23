#!/usr/bin/env bash
# Controlla che la versione sia una sola: VERSION alla radice del repository
# e le copie che il codice Dart deve avere come costanti (versione dell'hub,
# della CLI, dell'app desktop e della web UI, user agent dei client) più le
# version dei pubspec del workspace. Gira in tools/check.sh e nella CI di
# release; non serve nessun SDK.
#
#   tools/check_version.sh [--tag <vX.Y.Z>]
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(tr -d '[:space:]' < VERSION)
if ! [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
	echo "VERSION non è una semver: '$version'" >&2
	exit 1
fi
errors=0
bad() {
	echo "versione diversa da VERSION ($version): $*" >&2
	errors=$((errors + 1))
}

if [ "${1:-}" = --tag ]; then
	tag=${2:?--tag vuole un valore}
	[ "$tag" = "v$version" ] || bad "tag $tag (atteso v$version)"
fi

# Costanti: file, espressione con un gruppo che cattura la versione
consts=(
	"apps/hub/lib/src/config.dart|const String hubVersion = '([^']*)'"
	"apps/cli/lib/minesync_cli.dart|const String cliVersion = '([^']*)'"
	"apps/desktop/lib/src/state/session_state.dart|const String appVersion = '([^']*)'"
	"apps/hub_web/lib/src/shell/header.dart|const webVersion = '([^']*)'"
	"packages/ms_session/lib/src/session.dart|this.clientVersion = '([^']*)'"
)
for c in "${consts[@]}"; do
	f=${c%%|*}
	re=${c#*|}
	[ -f "$f" ] || { bad "$f non esiste"; continue; }
	found=$(sed -nE "s/.*$re.*/\1/p" "$f" | head -1)
	if [ -z "$found" ]; then
		bad "$f: costante non trovata ($re)"
	elif [ "$found" != "$version" ]; then
		bad "$f: $found"
	fi
done

# User agent e versioni scritti come letterali nel codice dei client
# (minesync/<v>, minesync-cli/<v>, version: '<v>'), test esclusi
while IFS= read -r line; do
	v=$(sed -nE "s/.*(minesync(-cli)?\/|version: ')([0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.-]*).*/\3/p" <<<"$line")
	[ -n "$v" ] && [ "$v" != "$version" ] && bad "$line"
done < <(grep -rnE "(minesync(-cli)?/|version: ')[0-9]+\.[0-9]+\.[0-9]+" \
	--include='*.dart' packages/*/lib apps/*/lib apps/*/bin 2>/dev/null || true)

# pubspec dei membri del workspace
for p in packages/*/pubspec.yaml apps/*/pubspec.yaml; do
	v=$(sed -nE 's/^version: *([^ ]+).*/\1/p' "$p" | head -1)
	# Flutter accetta 0.1.0+3: conta la parte prima del +
	[ "${v%%+*}" = "$version" ] || bad "$p: version ${v:-assente}"
done

if [ $errors -gt 0 ]; then
	echo "$errors differenze: allineare a VERSION" >&2
	exit 1
fi
echo "versione $version coerente"
