// Supporto ai golden di ms_ui: golden alla
// risoluzione fisica ai dpr frazionari e controllo che la geometria usi solo
// colori pieni dello schema (nessun pixel sfumato).
//
//   flutter test --update-goldens   rigenera i golden
//   flutter test                    confronta (tolleranza zero)
//
// I golden si generano e confrontano su Linux (flutter_tester): il testo dei
// caratteri vettoriali è rasterizzato in modo diverso altrove.
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ms_ui/ms_ui.dart';

/// I dpr su cui si verifica il design: 100, 125, 150, 200 %.
const goldenDprs = [1.0, 1.25, 1.5, 2.0];

/// Carica i caratteri del pacchetto nel motore di test.
Future<void> loadMsFonts() async {
  Future<void> fam(String name, List<String> files) async {
    final l = FontLoader('packages/ms_ui/$name');
    for (final f in files) {
      l.addFont(rootBundle.load('packages/ms_ui/assets/fonts/$f'));
    }
    await l.load();
  }

  await fam('AtkinsonHyperlegible', [
    'AtkinsonHyperlegible-Regular.ttf',
    'AtkinsonHyperlegible-Bold.ttf',
  ]);
  await fam('JetBrainsMono', ['JetBrainsMono-wght.ttf']);
}

const _capKey = Key('ms-golden-capture');

/// Ospita [child] con tema e griglia per il [dpr], su sfondo pieno.
Widget goldenHost(double dpr, Widget child, {MsThemeData theme = const MsThemeData()}) =>
    Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: MediaQueryData(devicePixelRatio: dpr),
        child: MsTheme(
          data: theme,
          child: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: _capKey,
              child: ColoredBox(
                color: theme.colors.bg,
                child: Padding(padding: const EdgeInsets.all(8), child: child),
              ),
            ),
          ),
        ),
      ),
    );

/// Prepara la vista del tester per [dpr] e una superficie logica [size].
void setGoldenView(WidgetTester t, double dpr, {Size size = const Size(1200, 900)}) {
  t.view
    ..devicePixelRatio = dpr
    ..physicalSize = size * dpr;
  addTearDown(t.view.reset);
}

/// Cattura l'ospite alla risoluzione fisica.
Future<ui.Image> captureGolden(WidgetTester t) async {
  final ro = t.renderObject<RenderRepaintBoundary>(find.byKey(_capKey));
  return (await t.runAsync(() => ro.toImage(pixelRatio: t.view.devicePixelRatio)))!;
}

/// Immagine RGBA non premoltiplicata.
final class Px {
  Px(this.width, this.height, this.rgba);
  final int width;
  final int height;
  final Uint8List rgba;

  int at(int x, int y) {
    final i = (y * width + x) * 4;
    return (rgba[i + 3] << 24) | (rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2];
  }
}

Future<Px> pixelsOf(WidgetTester t, ui.Image img) async {
  final bd = (await t.runAsync(() => img.toByteData(format: ui.ImageByteFormat.rawStraightRgba)))!;
  return Px(img.width, img.height, bd.buffer.asUint8List());
}

/// Tutti i colori pieni (opachi) di uno schema, più il trasparente.
Set<int> schemePalette(MsColors c, {Iterable<Color> extra = const []}) {
  final all = <Color>[
    c.bg, c.bg2, c.panel, c.panelHi, c.inset, c.overlay, c.text, c.text2, c.text3, //
    c.pxLight, c.pxShadow, c.pxOutline, c.accent, c.accentHi, c.accentLo, c.accentHover,
    c.onAccent, c.accentBg, c.accentInk, c.ok, c.onOk, c.okBg, c.warn, c.onWarn, c.warnBg,
    c.err, c.onErr, c.errBg, c.errHi, c.errLo, c.errHover, c.info, c.onInfo, c.infoBg,
    c.lockFree, c.lockPlay, c.lockStale, c.focus, c.focusHalo, c.sel, c.selText,
    c.logoO, c.logoH, c.logoG, c.logoD, c.logoK, c.logoW, c.conBg, c.conText, c.conDim,
    c.conInfo, c.conWarn, c.conErr, c.conJoin, c.conOk, c.conCmd, c.conWarnBg, c.conErrBg,
    c.conHover, c.conMatch, c.conInput, c.conFocus, c.av1, c.av2, c.av3, c.av4, c.av5,
    c.av6, c.av7, c.av8, ...extra,
  ];
  return {0x00000000, for (final x in all) x.toARGB32()};
}

/// Pixel fuori da [palette]: numero ed esempi.
({int bad, List<String> samples}) impurePixels(Px img, Set<int> palette) {
  var bad = 0;
  final samples = <String>[];
  for (var y = 0; y < img.height; y++) {
    for (var x = 0; x < img.width; x++) {
      final c = img.at(x, y);
      if (!palette.contains(c)) {
        bad++;
        if (samples.length < 8) samples.add('($x,$y)=#${c.toRadixString(16).padLeft(8, '0')}');
      }
    }
  }
  return (bad: bad, samples: samples);
}

/// Golden di [child] a ogni dpr di [goldenDprs], in `goldens/<name>/dpr_X.png`
/// accanto al test. Con [pure] verifica anche che non ci siano pixel sfumati
/// (da usare per la sola geometria, senza testo vettoriale); [extraColors] si
/// aggiungono ai colori ammessi (es. i colori del logo, fuori dallo schema).
Future<void> expectGoldens(
  WidgetTester t,
  String name,
  Widget child, {
  MsThemeData theme = const MsThemeData(),
  bool pure = false,
  Iterable<Color> extraColors = const [],
  Size size = const Size(1200, 900),
}) async {
  // la geometria pura si controlla senza il testo, l'unica cosa con antialiasing
  debugHideText = pure;
  addTearDown(() => debugHideText = false);
  for (final dpr in goldenDprs) {
    setGoldenView(t, dpr, size: size);
    await t.pumpWidget(goldenHost(dpr, child, theme: theme));
    await t.pump();
    final img = await captureGolden(t);
    if (pure) {
      final r = impurePixels(
        await pixelsOf(t, img),
        schemePalette(theme.colors, extra: extraColors),
      );
      expect(r.bad, 0, reason: '$name dpr $dpr: ${r.samples}');
    }
    await expectLater(img, matchesGoldenFile('goldens/$name/dpr_${dpr.toStringAsFixed(2)}.png'));
    img.dispose();
  }
}
