// Golden dei componenti a dpr 1.0 / 1.25 / 1.5 / 2.0.
//   flutter test --update-goldens test/golden_test.dart   (rigenera)
//   flutter test test/golden_test.dart                     (confronta, tolleranza 0)
// Oltre ai golden, il test verifica in linea la purezza della palette
// (nessun colore intermedio) su geometria e fotogrammi dell'animazione.
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_spike/analysis.dart';
import 'package:pixel_spike/gallery.dart';
import 'package:pixel_spike/main.dart' show loadRasterIcons;
import 'package:pixel_spike/ms/components.dart';
import 'package:pixel_spike/ms/tokens.dart';
import 'package:pixel_spike/pixel/grid.dart';

const dprs = [1.0, 1.25, 1.5, 2.0];

Future<void> loadFonts() async {
  Future<void> fam(String name, List<String> files) async {
    final l = FontLoader(name);
    for (final f in files) {
      l.addFont(rootBundle.load('assets/fonts/$f'));
    }
    await l.load();
  }

  await fam('PixelifySans', ['PixelifySans-wght.ttf']);
  await fam('Silkscreen', ['Silkscreen-Regular.ttf', 'Silkscreen-Bold.ttf']);
  await fam('SilkscreenGrid', ['SilkscreenGrid-Regular.ttf', 'SilkscreenGrid-Bold.ttf']);
  await fam('JetBrainsMono', ['JetBrainsMono-wght.ttf']);
}

Widget host(double dpr, Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: PixelScope(
        grid: PixelGrid.forDpr(dpr),
        child: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: const Key('cap'),
            child: MsBackground(child: child),
          ),
        ),
      ),
    );

/// Cattura la RepaintBoundary alla risoluzione FISICA (pixelRatio = dpr).
/// Nota: matchesGoldenFile su un Finder cattura a 1x, quindi gli si passa
/// direttamente l'immagine.
Future<ui.Image> captureImage(WidgetTester tester) async {
  final ro = tester.renderObject<RenderRepaintBoundary>(find.byKey(const Key('cap')));
  final dpr = tester.view.devicePixelRatio;
  return (await tester.runAsync(() => ro.toImage(pixelRatio: dpr)))!;
}

Future<Px> toPx(WidgetTester tester, ui.Image img) async {
  final bd = (await tester.runAsync(
      () => img.toByteData(format: ui.ImageByteFormat.rawStraightRgba)))!;
  return Px(img.width, img.height, bd.buffer.asUint8List());
}

Future<Px> capture(WidgetTester tester) async {
  final img = await captureImage(tester);
  final px = await toPx(tester, img);
  img.dispose();
  return px;
}

Future<void> golden(WidgetTester tester, String path) async {
  final img = await captureImage(tester);
  await expectLater(img, matchesGoldenFile(path));
  img.dispose();
}

String dir(double d) => '../goldens/dpr_${d.toStringAsFixed(2)}';

void main() {
  setUpAll(loadFonts);
  final palette = geometryPalette();

  for (final dpr in dprs) {
    group('dpr $dpr', () {
      late Map<String, ui.Image> raster;


      Future<void> prepare(WidgetTester tester, {Size logical = const Size(1400, 1600)}) async {
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = logical * dpr;
        addTearDown(tester.view.reset);
        raster = (await tester.runAsync(loadRasterIcons))!;
      }

      testWidgets('geometria pulsanti (senza testo)', (tester) async {
        await prepare(tester);
        await tester.pumpWidget(host(dpr, const ButtonsSection(showText: false)));
        final px = await capture(tester);
        final p = checkPurity(px, palette);
        expect(p.bad, 0, reason: 'pixel fuori palette: ${p.samples}');
        final runs = checkRuns(px, Ms.pxOutline.toARGB32(), PixelGrid.forDpr(dpr).unitPx);
        expect(runs.bad, 0, reason: 'bordi non multipli dell\'unità: ${runs.lengths}');
        await golden(tester, '${dir(dpr)}/geom_buttons.png');
      });

      testWidgets('pulsanti con etichetta Silkscreen: ancora nessun colore intermedio', (tester) async {
        await prepare(tester);
        await tester.pumpWidget(host(dpr, const ButtonsSection()));
        final px = await capture(tester);
        final p = checkPurity(px, palette);
        expect(p.bad, 0, reason: 'pixel fuori palette: ${p.samples}');
        await golden(tester, '${dir(dpr)}/buttons.png');
      });

      testWidgets('geometria pannello, slot, lingotti, icone (senza testo)', (tester) async {
        await prepare(tester);
        await tester.pumpWidget(host(dpr, PanelSection(showText: false, raster: raster)));
        final px = await capture(tester);
        final p = checkPurity(px, palette);
        expect(p.bad, 0, reason: 'pixel fuori palette: ${p.samples}');
        final runs = checkRuns(px, Ms.pxOutline.toARGB32(), PixelGrid.forDpr(dpr).unitPx);
        expect(runs.bad, 0, reason: 'bordi non multipli dell\'unità: ${runs.lengths}');
        await golden(tester, '${dir(dpr)}/geom_panel.png');
      });

      testWidgets('animazione di pressione: ogni fotogramma resta nitido', (tester) async {
        await prepare(tester);
        await tester.pumpWidget(host(dpr, const MsPlayButton(label: '')));
        final g = tester.getCenter(find.byType(MsPlayButton));
        final gesture = await tester.startGesture(g);
        for (var i = 0; i <= 10; i++) {
          final px = await capture(tester);
          final p = checkPurity(px, palette);
          expect(p.bad, 0, reason: 'fotogramma $i: ${p.samples}');
          await tester.pump(const Duration(milliseconds: 10));
        }
        await gesture.up();
        await tester.pumpAndSettle();
      });

      for (final id in ['text_silkscreen', 'text_pixelify', 'text_mono']) {
        testWidgets('testo $id', (tester) async {
          await prepare(tester);
          await tester.pumpWidget(host(dpr, TextSection(id)));
          await golden(tester, '${dir(dpr)}/$id.png');
        });
      }

      testWidgets('componenti con testo', (tester) async {
        await prepare(tester);
        await tester.pumpWidget(host(
            dpr,
            Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const ButtonsSection(),
              PanelSection(raster: raster),
            ])));
        await golden(tester, '${dir(dpr)}/components.png');
      });

      testWidgets('galleria completa', (tester) async {
        await prepare(tester, logical: const Size(1400, 1400));
        await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: PixelScope(
            grid: PixelGrid.forDpr(dpr),
            child: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(key: const Key('cap'), child: Gallery(raster: raster)),
            ),
          ),
        ));
        await golden(tester, '${dir(dpr)}/gallery.png');
      });
    });
  }
}
