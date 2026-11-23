#!/usr/bin/env bash
# Controlli del workspace: formato, analisi e test di ogni pacchetto.
# Lo stesso script gira in locale e in CI.
set -euo pipefail
cd "$(dirname "$0")/.."

# Fuso orario fisso: i golden mostrano orari locali e devono coincidere tra
# questo PC e la CI.
export TZ=UTC

tools/check_version.sh

flutter pub get --enforce-lockfile

# Il Dockerfile dell'hub copia i pubspec uno per uno: ogni membro del
# workspace deve esserci, o il pub get dell'immagine fallisce.
for m in $(sed -n 's/^  - //p' pubspec.yaml); do
	grep -q "^COPY $m/pubspec.yaml $m/$" deploy/Dockerfile || {
		echo "deploy/Dockerfile: manca COPY $m/pubspec.yaml" >&2
		exit 1
	}
done
dart format --output=none --set-exit-if-changed packages apps tools
dart analyze --fatal-infos packages apps

# I pacchetti Flutter si testano con flutter test, gli altri con dart test.
for pubspec in packages/*/pubspec.yaml apps/*/pubspec.yaml; do
	dir=$(dirname "$pubspec")
	[ -d "$dir/test" ] || continue
	echo "== $dir"
	if grep -q 'sdk: flutter' "$pubspec"; then
		(cd "$dir" && flutter test)
	else
		(cd "$dir" && dart test)
	fi
done
