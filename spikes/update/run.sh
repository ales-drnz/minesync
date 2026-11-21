#!/usr/bin/env bash
# Esegue lo spike di auto-aggiornamento: exit 0 solo se tutti gli scenari passano.
set -euo pipefail
cd "$(dirname "$0")"
command -v dart >/dev/null || { echo "dart non trovato nel PATH" >&2; exit 2; }
dart pub get >/dev/null
dart analyze --fatal-infos
dart run bin/e2e.dart
