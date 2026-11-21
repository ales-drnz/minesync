#!/usr/bin/env bash
# Spike web: build Flutter web (wasm + JS), precompressione brotli, server
# Dart, misure con Chrome headless (CDP). Exit 0 solo se i criteri passano.
#
# Variabili: CHROME=<percorso di chrome/chrome-headless-shell>
#            MBIT=2 LATENCY=150 RUNS=3 PORT=18080
set -euo pipefail
cd "$(dirname "$0")"
MBIT=${MBIT:-2}; LATENCY=${LATENCY:-150}; RUNS=${RUNS:-3}; PORT=${PORT:-18080}
mkdir -p .tmp

if [[ -z "${CHROME:-}" ]]; then
  for c in google-chrome chromium chromium-browser \
    "$(ls -d "$HOME"/.cache/puppeteer/chrome-headless-shell/*/chrome-headless-shell-linux64/chrome-headless-shell 2>/dev/null | tail -1)"; do
    if [[ -n "$c" ]] && command -v "$c" >/dev/null 2>&1; then CHROME=$(command -v "$c"); break; fi
  done
fi
[[ -n "${CHROME:-}" ]] || { echo "Chrome non trovato: imposta CHROME"; exit 2; }
for t in flutter dart node brotli gzip; do command -v $t >/dev/null || { echo "manca $t"; exit 2; }; done

echo "== build"
flutter pub get >/dev/null
flutter build web --wasm --no-web-resources-cdn --no-source-maps -o build/wasm | tail -1
flutter build web --no-web-resources-cdn --no-source-maps -o build/js | tail -1
for d in build/wasm build/js; do
  find "$d" -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.wasm' -o -name '*.json' \
    -o -name '*.ttf' -o -name '*.otf' -o -name 'NOTICES' -o -name '*.bin' \) -print0 \
    | xargs -0 -P"$(nproc)" -n1 brotli -f -k -q 11
done

echo "== dimensioni (byte: grezzo / gzip -9 / brotli -q 11)"
sizes() { # $1=dir, resto=file
  local d=$1; shift; local tr=0 tg=0 tb=0
  for f in "$@"; do
    local p="$d/$f"; [[ -f $p ]] || continue
    local r g b; r=$(stat -c%s "$p"); g=$(gzip -9 -c "$p" | wc -c)
    b=$([[ -f $p.br ]] && stat -c%s "$p.br" || brotli -q 11 -c "$p" | wc -c)
    printf "  %-42s %9d %9d %9d\n" "$f" "$r" "$g" "$b"; tr=$((tr+r)); tg=$((tg+g)); tb=$((tb+b))
  done
  printf "  %-42s %9d %9d %9d\n" "TOTALE" $tr $tg $tb
}
COMMON="index.html assets/AssetManifest.bin.json assets/FontManifest.json assets/fonts/PixelifySans-VF.ttf assets/fonts/Silkscreen-Regular.ttf assets/fonts/Silkscreen-Bold.ttf assets/fonts/JetBrainsMono-VF.ttf assets/fonts/MaterialIcons-Regular.otf assets/fonts/fallback/Roboto-Regular.ttf"
echo "-- percorso wasm (Chromium 137+): main.dart.wasm + skwasm"
sizes build/wasm $COMMON main.dart.mjs main.dart.wasm canvaskit/skwasm.js canvaskit/skwasm.wasm | tee .tmp/sizes-wasm.txt
echo "-- percorso JS su Chromium (canvaskit/chromium)"
sizes build/js $COMMON main.dart.js canvaskit/chromium/canvaskit.js canvaskit/chromium/canvaskit.wasm | tee .tmp/sizes-js-chromium.txt
echo "-- percorso JS su Firefox/Safari (canvaskit completo)"
sizes build/js $COMMON main.dart.js canvaskit/canvaskit.js canvaskit/canvaskit.wasm | tee .tmp/sizes-js-other.txt
echo "-- cartelle intere (du -sb, inclusi .br e .symbols)"; du -sb build/wasm build/js

echo "== server + misure (${MBIT} Mbit/s, ${LATENCY} ms, ${RUNS} giri)"
(cd server && dart pub get >/dev/null)
dart run server/bin/server.dart --root build/wasm --port "$PORT" > .tmp/server.log 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
for _ in $(seq 1 100); do curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null && break; sleep 0.2; done
# hub.test (mappato su 127.0.0.1) = origine http NON sicura, come l'hub su ZeroTier.
node measure/measure.mjs --chrome "$CHROME" --url "http://hub.test:$PORT" \
  --mbit "$MBIT" --latency "$LATENCY" --runs "$RUNS" --out .tmp/results.json --shots .tmp/shots
# 127.0.0.1 = contesto sicuro (come HTTPS): varianti leggere del motore. Solo informativo.
node measure/measure.mjs --chrome "$CHROME" --url "http://127.0.0.1:$PORT" --loads-only \
  --mbit "$MBIT" --latency "$LATENCY" --runs "$RUNS" --out .tmp/results-secure.json --shots .tmp/shots-secure

echo "== criteri"
node -e '
const r = require("./.tmp/results.json");
const sec = require("./.tmp/results-secure.json");
console.log(`(info) contesto sicuro: wasm cold ${sec.loads.wasm.coldMedianMs} ms / warm ${sec.loads.wasm.warmMedianMs} ms, js cold ${sec.loads.js.coldMedianMs} ms / warm ${sec.loads.js.warmMedianMs} ms`);
const w = r.loads.wasm, j = r.loads.js, a = r.a11yForced;
const checks = [
  ["cold wasm <= 5000 ms", w.coldMedianMs <= 5000, w.coldMedianMs],
  ["cold js <= 5000 ms", j.coldMedianMs <= 5000, j.coldMedianMs],
  ["warm wasm <= 1500 ms", w.warmMedianMs <= 1500, w.warmMedianMs],
  ["warm js <= 1500 ms", j.warmMedianMs <= 1500, j.warmMedianMs],
  ["URL + indietro + deep link", r.routing.pass, JSON.stringify(r.routing.afterBack)],
  ["form da tastiera (Tab fino a Salva, scrittura)", a.reachedSave && a.typedIntoPort && r.a11yDefault.reachedSave, a.tabsToSave],
  // Albero semantico: contiene solo i campi entro lo schermo (+cache);
  // si verifica che tutti quelli presenti abbiano un nome accessibile.
  ["etichette dei campi (screen reader)", a.formFields >= 8 && a.formFieldsLabelled === a.formFields, `${a.formFieldsLabelled}/${a.formFields} visibili`],
  ["URL + indietro con semantica attiva", r.routingA11y.pass, ""],
];
let ok = true;
for (const [n, p, v] of checks) { console.log(`${p ? "PASS" : "FAIL"}  ${n}  (${v})`); ok = ok && p; }
process.exit(ok ? 0 : 1);
'
