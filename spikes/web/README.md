# Spike: hub web UI in Flutter web

Throwaway prototype. Question: can the hub web UI (opened by friends' browsers over a
slow private ZeroTier link, plain `http://`) be written in Flutter web and still load fast?

## What is here

- `lib/` — minimal but realistic app: header with real `<a href>` nav links
  (`url_launcher` `Link`), overview with 6 cards + live event feed over SSE
  (`EventSource` via `package:web`), admin page with 40 form fields in 6 sections,
  `go_router` with path URLs (`/`, `/admin`, `/server/:id`), `SelectionArea`,
  3 OFL pixel fonts from github.com/google/fonts (Pixelify Sans, Silkscreen,
  JetBrains Mono; licences in `fonts/OFL-*.txt`). `?a11y=1` forces the semantics tree.
- `web/index.html` — pure HTML/CSS pixel splash (first paint before Flutter), bootstrap inlined.
- `web/flutter_bootstrap.js` — loads everything from `/b/<build-id>/`, no CDN (gstatic) at all.
- `server/bin/server.dart` — `dart:io` server (only dep: `crypto`): whole build in memory,
  gzip computed at start, brotli from `*.br` precompressed by the `brotli` CLI,
  `/b/<sha256-of-build>/…` = `Cache-Control: immutable, 1 year`, `index.html` = `no-cache` + ETag
  (Flutter does not hash file names, so the server puts the hash in the path), correct MIME for
  `.wasm`/`.mjs`, SPA fallback (any extension-less path → index), `/api/events` SSE test endpoint,
  optional `--coi` (COOP/COEP).
- `measure/measure.mjs` — Node (no npm deps) driving Chrome headless over CDP: throttled cold/warm
  loads, memory, routing/back button, semantics/labels, Tab navigation, `window.find` (Ctrl+F proxy).
- `run.sh` — builds (wasm + JS), precompresses, prints sizes, starts the server, measures, checks
  criteria; exit 0 only if all pass. `CHROME=… MBIT=2 LATENCY=150 RUNS=3 ./run.sh`

Dependencies (all BSD-3): go_router 18.1.4, url_launcher 6.3.3, web 1.1.2, crypto 3.x; fonts OFL.

## Results (measured 2026-11-21, Linux x64 16 cores, Flutter 3.47.5, chrome-headless-shell 157, SwiftShader WebGL)

Throttling via CDP `Network.emulateNetworkConditions`: 2 Mbit/s down, 1 Mbit/s up, 150 ms, median of 3.
"First frame" = Flutter's first post-frame callback (`performance.mark`), from navigation start.

| scenario | build | bytes on the wire (cold) | cold first frame | warm first frame | HTML splash FCP |
|---|---|---|---|---|---|
| `http://hub.test` (insecure, like the ZeroTier hub) | wasm (skwasm_heavy) | 3404 KB gzip | **14.7 s** | 0.30 s | 0.17 s |
| same | JS (canvaskit full) | 3894 KB gzip | **16.4 s** | 0.56 s | 0.17 s |
| `http://127.0.0.1` (secure context ≈ HTTPS) | wasm (skwasm) | 2080 KB brotli | **9.25 s** | 0.30 s | 0.17 s |
| same | JS (canvaskit) | 2315 KB brotli | **10.0 s** | 0.61 s | 0.17 s |

Why insecure origins are so much worse (verified):
- Chrome does not send `Accept-Encoding: br` over plain http → gzip only.
- `ImageDecoder` (WebCodecs) only exists in secure contexts → Flutter's loader picks the
  "heavy" engine (`skwasm_heavy.wasm` 2.26 MB gz instead of `skwasm.wasm` 1.54 MB gz;
  full `canvaskit.wasm` instead of the `chromium/` variant).
- Not cross-origin isolated → skwasm runs single-threaded (COOP/COEP need a secure context anyway).

Critical-path sizes (raw / gzip / brotli): wasm path 6.63 MB / 2.70 MB / 2.13 MB; JS on Chromium
8.65 / 3.10 / 2.37 MB; JS on Firefox/Safari 10.5 / 3.96 / 3.08 MB. Engine alone ≥ 1.2 MB brotli.
Full `build/` folders ≈ 52–55 MB (all engine variants + symbols; only one variant is downloaded).
Details: `.tmp/sizes-*.txt`, per-file waterfall in `.tmp/results*.json`.

Memory after warm load (headless, one tab): renderer PSS ≈ 135–139 MB; JS heap 7.9 MB (wasm) / 14.6 MB (JS).

Browser support for the wasm build (docs.flutter.dev/platform-integration/web/wasm): needs WasmGC +
JS string builtins + exnref; Chromium 137+ uses it by default; Firefox 147+ and Safari 26.2+ support it
but Flutter keeps them on JS+CanvasKit unless `wasmAllowList` opts in. The fallback is automatic.

Routing: PASS — real link click → `/admin`, browser back → `/`, deep link `/server/isola` reload,
document titles per page; works with and without semantics.

Accessibility / keyboard:
- By default no semantics tree: 0 `flt-semantics`, only a hidden "Enable accessibility" button
  (screen readers can activate it). With semantics on: `flt-semantics` nodes, form fields are real
  `<input>/<textarea>` with `aria-label` = field label, switches have names, dropdowns are buttons
  named "Lingua Italiano". Only on-screen (+cache) widgets are in the tree (12/12 labelled at a time
  on the admin page), as usual for lazy lists.
- Tab: works in both modes; Flutter's focus order follows the form (35 Tabs to reach "Salva"),
  typing into a field and pressing Enter on Salva shows validation errors (seen in the AX tree).
- Ctrl+F (`window.find`): finds nothing by default (text is painted on canvas). With semantics on it
  finds static text on screen ("Sara, Luca, Teo", dropdown values) but not field labels
  (`aria-label`) nor off-screen text.
- Not verified: text selection with the mouse (SelectionArea), real screen reader (NVDA/VoiceOver),
  phones (no CPU throttling run), Firefox/Safari (headless Chrome only).

## Conclusion

**FAIL on the cold-load criterion (≤ 5 s at 2 Mbit/s / 150 ms); PASS on warm load, URLs/back,
keyboard, labels.** The cold load is bandwidth-bound: even the best case (HTTPS + brotli + wasm)
ships ~2.1 MB, ≈ 8.5 s of pure transfer at 2 Mbit/s; the realistic plain-http case ships 3.4 MB.
No server-side trick gets the Flutter engine under the ~1.1 MB budget that 5 s implies.
Mitigations measured/possible: HTML splash (visible at 0.17 s, done), immutable caching (warm 0.3 s,
done), HTTPS on the hub (−35 % time), font subsetting/dropping Roboto fallback (~−150 KB),
deferred loading (only splits Dart code, not the engine). Recommendation: do not use Flutter web
for the friends-facing pages; use a light Dart-served HTML UI (or Jaspr) and, if wanted, keep
Flutter web only for the admin area.

## Additional measurement (coordinator, same machine and script)

`MBIT=<n> LATENCY=80 RUNS=1 ./run.sh`, plain http origin (as the hub on ZeroTier) and secure context:

| Link | http cold (wasm / js) | secure cold (wasm / js) | warm |
|---|---|---|---|
| 2 Mbit/s, 150 ms | 14.7 s / 16.4 s | 9.3 s / 10.0 s | 0.3 s |
| 10 Mbit/s, 80 ms | 3.2 s / 3.5 s | 2.1 s / 2.2 s | 0.2–0.5 s |
| 20 Mbit/s, 80 ms | 1.8 s / 2.0 s | 1.3 s / 1.3 s | 0.2–0.5 s |

The cold load is paid once per release per browser. It depends on the hub's upload bandwidth (the NAS's home connection), not on the friend's.
