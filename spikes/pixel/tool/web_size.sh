#!/usr/bin/env bash
# Dimensioni dei bundle web: file principali e "percorso critico" (quello che
# un browser scarica al primo avvio), raw / gzip -9 / brotli -q 11.
# Uso: tool/web_size.sh <dir_build_js> <dir_build_wasm>
set -euo pipefail
JS=$1; WASM=$2
sz() { # raw gz br per un elenco di file
  local raw=0 gz=0 br=0
  for f in "$@"; do
    raw=$((raw + $(stat -c %s "$f")))
    gz=$((gz + $(gzip -9 -c "$f" | wc -c)))
    br=$((br + $(brotli -q 11 -c "$f" | wc -c)))
  done
  awk -v r=$raw -v g=$gz -v b=$br 'BEGIN { printf "%9.1f KiB raw %9.1f KiB gz %9.1f KiB br", r/1024, g/1024, b/1024 }'
}
row() { printf "%-46s %s\n" "$1" "$(sz "${@:2}")"; }
FONTS=(assets/assets/fonts/PixelifySans-wght.ttf assets/assets/fonts/SilkscreenGrid-Regular.ttf assets/assets/fonts/SilkscreenGrid-Bold.ttf assets/assets/fonts/JetBrainsMono-wght.ttf)
BASE=(index.html flutter_bootstrap.js assets/AssetManifest.bin.json assets/FontManifest.json)
echo "== JS (dart2js + CanvasKit) =="
cd "$JS"
row "main.dart.js" main.dart.js
row "canvaskit/canvaskit.wasm (generico)" canvaskit/canvaskit.wasm
row "canvaskit/chromium/canvaskit.wasm" canvaskit/chromium/canvaskit.wasm
row "font usati (4 ttf)" "${FONTS[@]}"
row "PERCORSO CRITICO JS (generico)" "${BASE[@]}" main.dart.js canvaskit/canvaskit.js canvaskit/canvaskit.wasm "${FONTS[@]}"
row "PERCORSO CRITICO JS (Chromium)" "${BASE[@]}" main.dart.js canvaskit/chromium/canvaskit.js canvaskit/chromium/canvaskit.wasm "${FONTS[@]}"
echo "cartella completa: $(du -sh --apparent-size . | cut -f1)"
cd - >/dev/null
echo "== WASM (dart2wasm + skwasm) =="
cd "$WASM"
row "main.dart.wasm" main.dart.wasm
row "main.dart.mjs" main.dart.mjs
row "canvaskit/skwasm.wasm" canvaskit/skwasm.wasm
row "PERCORSO CRITICO WASM (skwasm)" "${BASE[@]}" main.dart.wasm main.dart.mjs canvaskit/skwasm.js canvaskit/skwasm.wasm "${FONTS[@]}"
echo "cartella completa: $(du -sh --apparent-size . | cut -f1)"
