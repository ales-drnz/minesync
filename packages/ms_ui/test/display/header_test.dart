import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';

import 'support.dart';

void main() {
  setUpAll(loadMsFonts);

  testWidgets('header dell\'hub e layout di servizio', (t) async {
    await displayGoldens(
      t,
      'header',
      () => gallery(width: 900, [
        MsHeader(
          navLabel: 'Sezioni',
          brand: MsHeaderBrand(
            name: 'MineSync',
            version: '0.1.0',
            logo: const MsTexture(MsTextureKind.grass, width: 32, height: 32),
            onTap: () {},
          ),
          nav: [
            MsHeaderLink(label: 'Server', current: true, onTap: () {}),
            MsHeaderLink(label: 'Storia', onTap: () {}, forceHover: true),
            MsHeaderLink(label: 'Mod', onTap: () {}, forceFocus: true),
          ],
          end: const [MsLive('Online'), MsText('alice', weight: 600, maxLines: 1)],
        ),
        const MsHorizon(),
        const MsStack(
          gap: 8,
          children: [
            MsRow(children: [MsChip('uno'), MsChip('due'), MsChip('tre')]),
            MsRow(wrap: false, children: [MsChip('a sinistra'), Spacer(), MsChip('a destra')]),
          ],
        ),
      ]),
      extra: (c) => textureColors(c),
      size: const Size(960, 300),
    );
  });

  testWidgets('voce corrente selezionata e cliccabile', (t) async {
    final h = t.ensureSemantics();
    var taps = 0;
    await t.pumpWidget(
      host(
        Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 600,
            child: MsHeader(
              nav: [MsHeaderLink(label: 'Server', current: true, onTap: () => taps++)],
            ),
          ),
        ),
      ),
    );
    await t.tap(find.bySemanticsLabel('Server'));
    expect(taps, 1);
    expect(
      t.getSemantics(find.bySemanticsLabel('Server')),
      isSemantics(isButton: true, isSelected: true),
    );
    h.dispose();
  });
}
