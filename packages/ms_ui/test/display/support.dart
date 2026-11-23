// Supporto ai golden dei componenti "display": stessa cattura di
// test/support/golden.dart, con colori pieni aggiuntivi ammessi dal
// controllo di purezza (ombre e attenuazioni composte, texture, occhi degli
// avatar) e con gli altri schemi.
//
//   prato scuro      a ogni dpr di goldenDprs  -> goldens/<nome>/dpr_X.png
//   prato chiaro     a dpr 1.0                 -> goldens/<nome>/prato_light.png
//   abisso scuro     a dpr 1.0                 -> goldens/<nome>/abisso_dark.png
//   abisso chiaro    a dpr 1.0                 -> goldens/<nome>/abisso_light.png
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';

import '../support/golden.dart';

export '../support/golden.dart';

/// Colori pieni ammessi oltre a quelli dello schema.
typedef ExtraColors = Iterable<Color> Function(MsColors c);

Iterable<Color> _none(MsColors c) => const [];

const _schemes = <(String, MsThemeData)>[
  ('prato_light', MsThemeData(brightness: Brightness.light)),
  ('abisso_dark', MsThemeData(palette: MsPalette.abisso)),
  ('abisso_light', MsThemeData(palette: MsPalette.abisso, brightness: Brightness.light)),
];

Future<void> _one(
  WidgetTester t,
  String file,
  Widget child,
  MsThemeData theme,
  double dpr, {
  required bool pure,
  required ExtraColors extra,
  required Size size,
}) async {
  // la geometria pura si controlla senza il testo, l'unica cosa con antialiasing
  debugHideText = pure;
  addTearDown(() => debugHideText = false);
  setGoldenView(t, dpr, size: size);
  await t.pumpWidget(goldenHost(dpr, child, theme: theme));
  await t.pump();
  final img = await captureGolden(t);
  if (pure) {
    final palette = schemePalette(theme.colors, extra: extra(theme.colors));
    final r = impurePixels(await pixelsOf(t, img), palette);
    expect(r.bad, 0, reason: '$file: ${r.samples}');
  }
  await expectLater(img, matchesGoldenFile(file));
  img.dispose();
}

/// Golden di [child] (costruito di nuovo per ogni schema) in prato scuro a
/// tutti i dpr e negli altri schemi a dpr 1. Con [pure] verifica che ci
/// siano solo colori dello schema più quelli di [extra].
Future<void> displayGoldens(
  WidgetTester t,
  String name,
  Widget Function() child, {
  bool pure = false,
  ExtraColors extra = _none,
  Size size = const Size(640, 600),
}) async {
  for (final dpr in goldenDprs) {
    await _one(
      t,
      'goldens/$name/dpr_${dpr.toStringAsFixed(2)}.png',
      child(),
      const MsThemeData(),
      dpr,
      pure: pure,
      extra: extra,
      size: size,
    );
  }
  for (final (scheme, theme) in _schemes) {
    await _one(
      t,
      'goldens/$name/$scheme.png',
      child(),
      theme,
      1.0,
      pure: pure,
      extra: extra,
      size: size,
    );
  }
}

/// Ospita [child] con tema [theme] a dpr 1 per i test di comportamento.
Widget host(Widget child, {MsThemeData theme = const MsThemeData()}) => Directionality(
  textDirection: TextDirection.ltr,
  child: MediaQuery(
    data: const MediaQueryData(),
    child: MsTheme(data: theme, child: child),
  ),
);

/// Colonna di galleria con spaziatura in px logici.
Widget gallery(List<Widget> children, {double gap = 16, double? width}) => SizedBox(
  width: width,
  child: Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: gap,
    children: children,
  ),
);

/// Riga di galleria.
Widget row(List<Widget> children, {double gap = 12}) => Wrap(
  spacing: gap,
  runSpacing: gap,
  crossAxisAlignment: WrapCrossAlignment.center,
  children: children,
);

/// Colori di tutte le texture alle misure usate nella galleria.
Iterable<Color> textureColors(MsColors c) => {
  for (final k in MsTextureKind.values) ...[
    ...MsPattern.texture(k).colorsFor(48, 48),
    ...MsPattern.texture(k).colorsFor(160, 64),
  ],
  ...MsPattern.blocks(c).colorsFor(320, 128),
  for (final p in MsPalette.values) ...MsPattern.horizon(c, p).colorsFor(320, 16),
};
