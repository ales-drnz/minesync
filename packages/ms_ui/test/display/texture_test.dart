import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';

import 'support.dart';

void main() {
  setUpAll(loadMsFonts);

  testWidgets('texture, sfondo a blocchi e orizzonte (pixel puri)', (t) async {
    await displayGoldens(
      t,
      'textures',
      () => Builder(
        builder: (context) => gallery([
          row([for (final k in MsTextureKind.values) MsSlot.square(child: MsTexture(k))]),
          row([for (final k in MsTextureKind.values) MsTexture(k, width: 160, height: 64)]),
          const SizedBox(width: 320, height: 128, child: MsBlocksBackground()),
          const SizedBox(width: 320, child: MsHorizon()),
        ]),
      ),
      pure: true,
      extra: textureColors,
      size: const Size(720, 600),
    );
  });

  testWidgets('orizzonte nelle due palette', (t) async {
    await displayGoldens(
      t,
      'horizon',
      () => gallery([
        for (final p in MsPalette.values)
          MsTheme(
            data: MsThemeData(palette: p),
            child: const SizedBox(width: 320, child: MsHorizon()),
          ),
      ]),
      pure: true,
      extra: (c) => {
        ...textureColors(c),
        for (final s in [pratoDark, abissoDark]) ...[
          for (final p in MsPalette.values) ...MsPattern.horizon(s, p).colorsFor(320, 16),
        ],
      },
      size: const Size(400, 120),
    );
  });

  test('il motivo è deterministico e usa solo colori pieni', () {
    for (final k in MsTextureKind.values) {
      final a = MsPattern.texture(k).rects(64, 64);
      final b = MsPattern.texture(k).rects(64, 64);
      expect(a, b);
      for (final r in a) {
        expect(r.$5.a, 1.0, reason: '$k');
        // tutto sulla griglia di 2 px di design
        expect(r.$1 % 2 + r.$2 % 2 + r.$3 % 2 + r.$4 % 2, 0);
      }
    }
  });

  testWidgets('la texture è decorativa (nessun nodo semantico)', (t) async {
    final h = t.ensureSemantics();
    await t.pumpWidget(host(const MsTexture(MsTextureKind.grass, width: 48, height: 48)));
    expect(find.bySemanticsLabel(RegExp('.')), findsNothing);
    h.dispose();
  });
}
