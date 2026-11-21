#!/usr/bin/env bash
# Compila guard, fake_server, fake_app, scenarios (AOT) ed esegue le prove.
# Exit code 0 solo se passano tutti gli scenari gating di questo OS.
# uso: ./run.sh [--only nome1,nome2]
set -euo pipefail
cd "$(dirname "$0")"
BIN="$PWD/.tmp/bin"
WORK="$PWD/.tmp/work"
mkdir -p "$BIN"
dart pub get >/dev/null
for n in guard fake_server fake_app scenarios; do
  dart compile exe "bin/$n.dart" -o "$BIN/$n" >/dev/null
done
"$BIN/scenarios" --bin "$BIN" --work "$WORK" --fixtures "$PWD/fixtures" "$@"
