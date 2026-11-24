// Supporto ai test dei controlli: golden con controllo di purezza che
// accetta anche i colori composti in modo deterministico dai componenti
// (frangia del GIOCA, spinner, luci della manopola), ospite con Overlay per
// menu e tooltip, icona pixel di prova.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';
import 'package:ms_ui/src/components/controls/core.dart' show msBlend;

import '../support/golden.dart';

/// Schemi su cui si generano i golden "di tema" oltre a prato scuro.
const pratoLightTheme = MsThemeData(brightness: Brightness.light);
const abissoDarkTheme = MsThemeData(palette: MsPalette.abisso);

/// Colori composti con [msBlend] che i controlli disegnano pieni.
List<Color> blendedColors(MsColors c) {
  Color b(Color fg, double a, Color bg) => msBlend(fg, a, bg);
  // pulsante giallo (MsButtonVariant.warn): sfumature di --ms-warn
  final warnHover = b(const Color(0xFFFFFFFF), .12, c.warn);
  return [
    warnHover,
    b(const Color(0xFFFFFFFF), .3, c.warn),
    b(const Color(0xFF000000), .3, c.warn),
    for (final fg in [c.onWarn, c.text3])
      for (final bg in [c.warn, warnHover]) b(fg, .35, bg),
    // frangia del GIOCA, normale/hover/premuto
    for (final face in [c.accent, c.accentHover])
      for (final a in [.9, .5]) b(c.accentHi, a, face),
    // spinner (.35 su ogni faccia)
    for (final fg in [c.text, c.onAccent, c.onErr, c.text3])
      for (final bg in [c.panelHi, c.overlay, c.accent, c.accentHover, c.err, c.errHover, c.bg])
        b(fg, .35, bg),
    // manopola dello switch e incasso acceso
    for (final knob in [c.text2, c.panel]) ...[
      b(const Color(0xffffffff), .35, knob),
      b(const Color(0xff000000), .30, knob),
    ],
    b(const Color(0xff000000), .25, c.ok),
  ];
}

/// Golden di [child] ai quattro dpr; con [pure] verifica che ogni pixel sia
/// un colore dello schema (o un colore composto di [blendedColors]).
Future<void> expectControlGoldens(
  WidgetTester t,
  String name,
  Widget child, {
  MsThemeData theme = const MsThemeData(),
  bool pure = false,
  Size size = const Size(1200, 900),
  List<double> dprs = goldenDprs,
}) async {
  // la geometria pura si controlla senza il testo, l'unica cosa con antialiasing
  debugHideText = pure;
  addTearDown(() => debugHideText = false);
  final palette = schemePalette(theme.colors, extra: blendedColors(theme.colors));
  for (final dpr in dprs) {
    setGoldenView(t, dpr, size: size);
    await t.pumpWidget(
      goldenHost(
        dpr,
        Overlay.wrap(
          child: Padding(padding: const EdgeInsets.all(8), child: child),
        ),
        theme: theme,
      ),
    );
    await t.pump();
    final img = await captureGolden(t);
    if (pure) {
      final r = impurePixels(await pixelsOf(t, img), palette);
      expect(r.bad, 0, reason: '$name dpr $dpr: ${r.samples}');
    }
    await expectLater(img, matchesGoldenFile('goldens/$name/dpr_${dpr.toStringAsFixed(2)}.png'));
    img.dispose();
  }
}

/// Ospite per i test di comportamento: tema, griglia, Overlay e Navigator.
/// [WidgetsApp] fornisce le scorciatoie standard (Tab, Esc, frecce).
Widget host(Widget child, {MsThemeData theme = const MsThemeData()}) => WidgetsApp(
  color: theme.colors.bg,
  debugShowCheckedModeBanner: false,
  builder: (context, _) => MsTheme(
    data: theme,
    child: Navigator(
      onGenerateRoute: (_) => PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => ColoredBox(
          color: theme.colors.bg,
          child: Align(alignment: Alignment.topLeft, child: child),
        ),
      ),
    ),
  ),
);

/// Icona pixel di prova (un "dischetto" 8x8) che usa il colore di [IconTheme].
class TestIcon extends StatelessWidget {
  const TestIcon({super.key});

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color!;
    final size = (IconTheme.of(context).size! / PixelScope.of(context).unit * 2).roundToDouble();
    return PixelBox(
      width: size,
      height: size,
      repaintKey: color,
      painter: (c, w, h) {
        final k = w / 8;
        c.rect(k, k, 6 * k, 2 * k, color);
        c.rect(k, 3 * k, 2 * k, 4 * k, color);
        c.rect(5 * k, 3 * k, 2 * k, 4 * k, color);
        c.rect(3 * k, 5 * k, 2 * k, 2 * k, color);
      },
    );
  }
}

/// Riga con spazio di [gap] px di design.
Widget row(BuildContext context, List<Widget> children, {double gap = 16}) => Row(
  mainAxisSize: MainAxisSize.min,
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    for (var i = 0; i < children.length; i++) ...[if (i > 0) PixelGap(gap, 0), children[i]],
  ],
);

/// Golden di una galleria: prato scuro ai quattro dpr, prato chiaro e
/// abisso scuro a 1.0 e 1.5.
void goldenSuite(
  String name,
  Widget Function() build, {
  bool pure = false,
  Size size = const Size(1200, 900),
}) {
  group('golden $name', () {
    testWidgets(
      'prato scuro',
      (t) => expectControlGoldens(t, name, build(), pure: pure, size: size),
    );
    for (final (suffix, theme) in [
      ('prato_light', pratoLightTheme),
      ('abisso_dark', abissoDarkTheme),
    ]) {
      testWidgets(
        suffix,
        (t) => expectControlGoldens(
          t,
          '${name}_$suffix',
          build(),
          theme: theme,
          pure: pure,
          size: size,
          dprs: const [1.0, 1.5],
        ),
      );
    }
  });
}

/// Colonna con spazio di [gap] px di design.
Widget column(List<Widget> children, {double gap = 16}) => Column(
  mainAxisSize: MainAxisSize.min,
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    for (var i = 0; i < children.length; i++) ...[if (i > 0) PixelGap(0, gap), children[i]],
  ],
);

/// Larghezza fissa in px di design.
Widget width(double designPx, Widget child) => Builder(
  builder: (context) => SizedBox(width: PixelScope.of(context).d(designPx), child: child),
);

/// Riga senza contesto (per le gallerie).
Widget hrow(List<Widget> children, {double gap = 16}) =>
    Builder(builder: (context) => row(context, children, gap: gap));
