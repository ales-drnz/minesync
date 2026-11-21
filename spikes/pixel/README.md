# Spike: crisp pixel-art rendering in Flutter (desktop + web)

Throwaway prototype for MineSync 0.1.0, phase 0. It checks whether the approved
pixel design system (`ms.css`: radius 0, 2 px borders, extruded GIOCA block,
raised panels, sunken slots, 10+2 px "ingot" bars, 8x8 icons, Pixelify Sans /
Silkscreen / JetBrains Mono) can be rendered by Flutter **without any blurred
pixels** at fractional device pixel ratios, and fast enough.

## Strategy

* **Integer pixel unit** (`lib/pixel/grid.dart`): one system pixel (`--ms-px`,
  2 design px) = `unitPx = max(1, floor(dpr*2))` physical pixels. All
  geometry is in design px and every size is a whole number of units.
  dpr 1.0 / 1.25 / 1.5 / 2.0 -> 2 / 2 / 3 / 4 physical px per unit
  (scale 1.00 / **0.80** / 1.00 / 1.00; `PixelPolicy.nearest` would give 1.20 at 1.25).
* **Origin snapping** (`pixelSnapDelta`): each pixel render object moves its
  paint origin to the nearest physical pixel using `localToGlobal`, so scroll
  offsets and layout never leave fractional positions.
* **Filled rectangles only** (`PixelCanvas`): rings, bevels, the extruded side,
  ingots and icons are `drawRect` on the physical grid (antialiasing left ON,
  so any misalignment would show up in the analysis).
* **Icons**: 8x8 vector rects or 8x8 bitmaps with `FilterQuality.none`; the
  icon pixel is rounded to a whole number of physical pixels (24 px at
  unitPx 3 would otherwise be 4.5 px).
* **Text**: font size converted with the same unit. Silkscreen (1/8 em grid)
  gets the same integer quantisation as icons. The stock Silkscreen has 48
  glyphs with counters offset by 5/1000 em, which leave grey pixels even at
  exact sizes, so `tool/snap_silkscreen.py` produces `SilkscreenGrid-*.ttf`
  (OFL modification, family renamed). Baseline snapping is implemented but
  made no measurable difference (SkParagraph already rounds it).
* **Press animation**: 80 ms ease-out, but the face offset advances in whole
  physical pixels, so every frame is still crisp.
* Note: `Paint.isAntiAlias = false` on a text foreground has no effect.

## Run

```
./run.sh                 # Linux/macOS: everything, exit 0 only if all criteria pass
SKIP_PERF=1 SKIP_WEB=1 ./run.sh
pwsh ./run.ps1           # Windows (engine capture + perf)
```

Steps: (1) `flutter test test/golden_test.dart`: goldens at dpr 1.0/1.25/1.5/2.0
captured at **physical** resolution, zero tolerance, plus inline palette-purity
checks of the geometry, of the GIOCA label and of 11 frames of the press
animation; (2) `tool/analyze_goldens.dart`; (3) `integration_test/capture_test.dart`
renders the same components with the real desktop engine (Impeller OpenGLES on
Linux) and analyses them; (4) `flutter drive --profile` with
`integration_test/perf_test.dart` + `tool/check_perf.dart`; (5) web builds +
`tool/web_size.sh`. Regenerate goldens with `flutter test --update-goldens test/golden_test.dart`.

The analyzer requires, for `geom_*` images, that **every pixel** is exactly one
of the palette colours (no intermediate colour anywhere) and that every
horizontal/vertical run of the outline colour is a multiple of `unitPx`.
For text it reports the share of ink pixels that are antialiased.

## Results (CachyOS, Linux x64, 16 cores, 4K 144 Hz Wayland, GDK scale 2, Flutter 3.47.5)

Measured:

| check | dpr 1.0 | 1.25 | 1.5 | 2.0 |
|---|---|---|---|---|
| geometry off-palette pixels (flutter_tester and Impeller) | 0 | 0 | 0 | 0 |
| outline runs not multiple of unitPx | 0 | 0 | 0 | 0 |
| press animation frames with off-palette pixels | 0 | 0 | 0 | 0 |
| Silkscreen (grid) 16/24/32, AA pixels | 0 % | 0 % | 0 % | 0 % |
| Silkscreen stock 16, AA pixels | 5.1 % | 5.1 % | 3.4 % | 2.6 % |
| Pixelify Sans 16, AA pixels | 74 % | 74 % | 54 % | 45 % |
| Pixelify Sans 48, AA pixels | 26 % | 26 % | 18 % | 14 % |
| JetBrains Mono 14, AA pixels | 91 % | 91 % | 75 % | 60 % |

Pixelify Sans is not drawn on a clean grid (about 1/11 em with 10-unit
offsets), so it always has some antialiasing. It still reads as pixel type and
stays legible from 14 px up (see `goldens/zoom/`).

Smoothness (real window, dpr 2.0, 2560x1440 physical, profile mode, Impeller GLES):

| scenario | frames | build avg / p99 / worst | raster avg / p99 / worst | over 16.7 ms |
|---|---|---|---|---|
| console 2000 lines, continuous scroll 12 s | 709 / 721 (58.9 / 59.9 fps, 2 runs) | 1.2 / 2.3 / 3.3 ms | 1.2 / 2.1 / 3.8 ms | 0 |
| console flings x6 | 706 | 0.6 / 1.8 / 3.0 ms | 1.5 / 2.7 / 4.1 ms | 0 |
| GIOCA pressed 20 times | 368 | 0.1 / 0.4 / 1.0 ms | 1.1 / 1.7 / 2.3 ms | 0 |

The display runs at 144 Hz, but the Linux embedder paced frames at about 60 Hz.
We think it falls back to a fixed 60 Hz vsync, but have not checked this. Frame
cost is 7 ms or less, so there is plenty of headroom.

Web bundle (`--release --no-web-resources-cdn`, self-hosted; fonts = 4 TTF used):

| | raw | gzip -9 | brotli 11 |
|---|---|---|---|
| main.dart.js | 1243 KiB | 400 KiB | 318 KiB |
| main.dart.wasm (+ .mjs 28 KiB) | 1142 KiB | 428 KiB | 344 KiB |
| canvaskit.wasm (generic / chromium) | 7114 / 5302 KiB | 2848 / 2015 KiB | 2204 / 1504 KiB |
| skwasm.wasm | 3510 KiB | 1501 KiB | 1181 KiB |
| first load, JS + CanvasKit (Chromium) | 6965 KiB | 2587 KiB | 1971 KiB |
| first load, wasm + skwasm | 5078 KiB | 2098 KiB | 1672 KiB |

Not verified: pixel crispness in a browser (no Chrome locally), Windows and
macOS engines. `ci/pixel-spike.yml` proposes jobs for these.

## Conclusion

PASS on Linux. Geometry and icons have zero intermediate pixels at all four
dprs, both in flutter_tester and with Impeller. Silkscreen (grid-snapped) is
pixel-exact. Pixelify Sans is legible, with mild antialiasing. Console
scrolling runs at the 60 Hz the embedder delivers, with frames of 7 ms or less.
The price of integer units is a non-nominal scale at some dprs (0.80 at 1.25
with `floor`). Phase 1 has to choose a policy (floor, nearest, or a user
setting).

Licences: fonts OFL 1.1 (`assets/fonts/OFL-*.txt`; `SilkscreenGrid` is a
modified Silkscreen), `package:image` MIT (dev only), fontTools MIT (one-off
script).
