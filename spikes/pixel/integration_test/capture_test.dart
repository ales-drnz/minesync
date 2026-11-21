// Golden "veri": stessi componenti rasterizzati dal motore del desktop
// (Impeller/Skia della piattaforma, non il rasterizzatore software di
// flutter_tester). Scrive i PNG in .tmp/engine/dpr_X/ e verifica in linea la
// purezza della palette.
//   flutter test integration_test/capture_test.dart -d linux|macos|windows
// Sul web (nessun file system) verifica solo la purezza in linea:
//   flutter drive -d web-server --browser-name=chrome [--wasm] \
//     --driver=test_driver/integration_test.dart --target=integration_test/capture_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pixel_spike/analysis.dart';
import 'package:pixel_spike/gallery.dart';
import 'package:pixel_spike/main.dart' show loadRasterIcons;
import 'package:pixel_spike/pixel/grid.dart';

const out = String.fromEnvironment('OUT', defaultValue: '.tmp/engine');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final palette = geometryPalette();

  for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
    testWidgets('motore reale dpr $dpr', (tester) async {
      final raster = await loadRasterIcons();
      final sections = <String, Widget>{
        'geom_buttons': const ButtonsSection(showText: false),
        'buttons': const ButtonsSection(),
        'geom_panel': PanelSection(showText: false, raster: raster),
        'text_silkscreen': const TextSection('text_silkscreen'),
        'text_pixelify': const TextSection('text_pixelify'),
        'text_mono': const TextSection('text_mono'),
      };
      for (final e in sections.entries) {
        await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: PixelScope(
            grid: PixelGrid.forDpr(dpr),
            child: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(key: const Key('cap'), child: MsBackground(child: e.value)),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        final ro = tester.renderObject<RenderRepaintBoundary>(find.byKey(const Key('cap')));
        final img = await ro.toImage(pixelRatio: dpr);
        final raw = (await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
        final png = (await img.toByteData(format: ui.ImageByteFormat.png))!;
        if (!kIsWeb) {
          File('$out/dpr_${dpr.toStringAsFixed(2)}/${e.key}.png')
            ..createSync(recursive: true)
            ..writeAsBytesSync(png.buffer.asUint8List());
        }
        if (e.key.startsWith('geom') || e.key == 'buttons') {
          final p = checkPurity(Px(img.width, img.height, raw.buffer.asUint8List()), palette);
          expect(p.bad, 0, reason: '${e.key} dpr $dpr: ${p.samples}');
        }
        img.dispose();
      }
    });
  }
}
