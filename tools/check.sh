#!/usr/bin/env bash
# Controlli del workspace 0.1.0: formato, analisi e test di ogni pacchetto.
# Lo stesso script gira in locale e in CI.
set -euo pipefail
cd "$(dirname "$0")/.."

flutter pub get --enforce-lockfile
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
