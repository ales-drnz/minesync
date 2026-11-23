import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';

double _lum(Color c) {
  double ch(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double contrast(Color a, Color b) {
  final x = _lum(a), y = _lum(b);
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

void main() {
  test('tokens.g.dart allineato a tokens.json', () {
    final r = Process.runSync(
      Platform.resolvedExecutable.contains('flutter') ? 'dart' : Platform.resolvedExecutable,
      ['run', 'tool/gen_tokens.dart', '--check'],
    );
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
  });

  test('i quattro schemi', () {
    const d = MsThemeData();
    expect(d.colors, same(pratoDark));
    expect(d.copyWith(brightness: Brightness.light).colors, same(pratoLight));
    expect(d.copyWith(palette: MsPalette.abisso).colors, same(abissoDark));
    expect(
      d.copyWith(palette: MsPalette.abisso, brightness: Brightness.light).colors,
      same(abissoLight),
    );
  });

  test('contrasto del testo almeno 4.5:1 in ogni schema', () {
    for (final (name, c) in [
      ('prato scuro', pratoDark),
      ('prato chiaro', pratoLight),
      ('abisso scuro', abissoDark),
      ('abisso chiaro', abissoLight),
    ]) {
      for (final (role, fg) in [('text', c.text), ('text2', c.text2), ('text3', c.text3)]) {
        for (final (bgName, bg) in [('bg', c.bg), ('panel', c.panel)]) {
          expect(contrast(fg, bg), greaterThanOrEqualTo(4.5), reason: '$name $role su $bgName');
        }
      }
      expect(contrast(c.onAccent, c.accent), greaterThanOrEqualTo(4.5), reason: '$name onAccent');
      expect(contrast(c.conText, c.conBg), greaterThanOrEqualTo(4.5), reason: '$name console');
    }
  });

  test('griglia: floor con passo della dimensione dell\'interfaccia', () {
    expect(PixelGrid.forDpr(1.25).unitPx, 2);
    expect(PixelGrid.forDpr(1.25, step: 1).unitPx, 3);
    expect(PixelGrid.forDpr(1.0, step: -1).unitPx, 1);
    expect(PixelGrid.forDpr(1.0, step: -5).unitPx, 1);
    expect(PixelGrid.forDpr(2.0).scale, 1.0);
  });

  test('testo leggibile ovunque: Atkinson, etichette e titoli in grassetto', () {
    const c = Color(0xff000000);
    const t = MsTypography();
    for (final r in MsTextRole.values) {
      final st = t.style(r, c);
      expect(
        st.font,
        r == MsTextRole.con || r == MsTextRole.mono ? PixelFont.mono : PixelFont.sans,
      );
    }
    expect(t.style(MsTextRole.label, c).weight, 700);
    expect(t.style(MsTextRole.h2, c).weight, 700);
    expect(t.style(MsTextRole.md, c).weight, 400);
  });

  testWidgets('MsTheme fornisce tema e griglia', (t) async {
    late MsThemeData got;
    late PixelGrid grid;
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MsTheme(
        data: const MsThemeData(palette: MsPalette.abisso, sizeStep: 1),
        child: Builder(
          builder: (c) {
            got = MsTheme.of(c);
            grid = PixelScope.of(c);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(got.palette, MsPalette.abisso);
    expect(grid.unitPx, 3); // dpr 1.0 del tester: 2 + 1
  });
}
