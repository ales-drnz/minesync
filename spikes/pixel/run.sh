#!/usr/bin/env bash
# Esegue tutte le prove dello spike pixel. Exit 0 solo se i criteri passano.
#   ./run.sh               tutto (golden, motore reale, perf, build web)
#   SKIP_PERF=1 ./run.sh   senza la misura di fluidità (es. CI senza display)
#   SKIP_WEB=1 ./run.sh    senza le build web
set -euo pipefail
cd "$(dirname "$0")"
export LC_ALL=C
case "$(uname -s)" in
  Linux) DEV=linux ;;
  Darwin) DEV=macos ;;
  *) echo "piattaforma non gestita (usa run.ps1 su Windows)"; exit 2 ;;
esac
mkdir -p .tmp
flutter pub get >/dev/null

if [ "$DEV" = linux ]; then
  # I golden di riferimento sono generati da flutter_tester su Linux: il testo
  # è rasterizzato in modo diverso su macOS/Windows, quindi lì si salta.
  echo "== 1. golden flutter_tester (tolleranza 0) + purezza in linea =="
  flutter test test/golden_test.dart
  echo "== 2. analisi dei golden =="
  dart run tool/analyze_goldens.dart goldens --json .tmp/goldens.json
fi

echo "== 3. stessi componenti rasterizzati dal motore reale ($DEV) =="
rm -rf .tmp/engine
flutter test integration_test/capture_test.dart -d "$DEV" --dart-define=OUT="$PWD/.tmp/engine"
dart run tool/analyze_goldens.dart .tmp/engine --json .tmp/engine.json

if [ -z "${SKIP_PERF:-}" ]; then
  echo "== 4. fluidità in profile (console 2000 righe, GIOCA) =="
  flutter drive --profile -d "$DEV" --driver=test_driver/perf_driver.dart \
    --target=integration_test/perf_test.dart > .tmp/perf.log 2>&1 || { tail -40 .tmp/perf.log; exit 1; }
  dart run tool/check_perf.dart .tmp/perf.json
fi

if [ -z "${SKIP_WEB:-}" ]; then
  echo "== 5. build web (informativa) =="
  flutter build web --release --no-web-resources-cdn -o .tmp/web_js >/dev/null
  flutter build web --release --wasm --no-web-resources-cdn -o .tmp/web_wasm >/dev/null
  tool/web_size.sh .tmp/web_js .tmp/web_wasm
fi
echo "TUTTO PASS"
