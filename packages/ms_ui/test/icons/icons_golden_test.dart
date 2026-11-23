// Golden di icone, logo e illustrazioni: geometria pura (solo colori pieni)
// a 100, 125, 150 e 200 %.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';

import '../support/golden.dart';

const _schemes = {
  'prato_dark': MsThemeData(),
  'prato_light': MsThemeData(brightness: Brightness.light),
  'abisso_dark': MsThemeData(palette: MsPalette.abisso),
  'abisso_light': MsThemeData(palette: MsPalette.abisso, brightness: Brightness.light),
};

Widget _row(List<Widget> children) => Padding(
  padding: const EdgeInsets.only(bottom: 8),
  child: Wrap(spacing: 8, runSpacing: 8, children: children),
);

void main() {
  testWidgets('icone a 16, 24 e 32', (t) async {
    await expectGoldens(
      t,
      'icons',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final size in [16.0, 24.0, 32.0])
            _row([for (final i in MsIcons.values) MsIcon(i, size: size)]),
          // Colore esplicito e colore da IconTheme.
          _row([
            MsIcon(MsIcons.play, size: 32, color: pratoDark.accent),
            IconTheme(
              data: IconThemeData(color: pratoDark.warn),
              child: const MsIcon(MsIcons.warn, size: 32),
            ),
          ]),
        ],
      ),
      pure: true,
    );
  });

  for (final MapEntry(key: name, value: theme) in _schemes.entries) {
    testWidgets('logo e illustrazioni, $name', (t) async {
      final logo = msLogoPaletteOf(theme.palette);
      await expectGoldens(
        t,
        'logo_$name',
        _row([
          for (final size in [16.0, 20.0, 24.0, 32.0, 40.0, 48.0, 64.0, 128.0]) MsLogo(size: size),
          for (final art in [MsArts.crackedBlock, MsArts.emptyIsland]) MsArt(art),
        ]),
        theme: theme,
        pure: true,
        extraColors: [for (final c in logo.roles) Color(c)],
      );
    });
  }
}
