import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';

import 'support.dart';

Widget _texts() => gallery(width: 560, gap: 8, [
  const MsEyebrow('Componenti'),
  const MsText.display('Gioca'),
  const MsText.h1('Il mondo condiviso'),
  const MsText.h2('Survival · generazione #128'),
  const MsText.h3('Sessione in corso'),
  const MsText('alice sta giocando su Creativo da 42 minuti.', kind: MsTextKind.lg),
  const MsText(
    'Prima di avviare scarico le differenze dall\'hub e prendo il lock: nessun altro potrà '
    'aprire il mondo finché giochi.',
  ),
  const MsText.small('bob · 18:47 · 312 file · 1,4 GB', tone: MsTextTone.secondary),
  const MsText.small('Terziario', tone: MsTextTone.tertiary),
  const MsText.label('Ultimo salvataggio'),
  const MsText.mono('zerotier.a1b2c3.local:25565'),
  const MsText('1 111 000', tabular: true),
  row([
    for (final t in [MsTextTone.ok, MsTextTone.warn, MsTextTone.err, MsTextTone.info])
      MsText(t.name, tone: t, maxLines: 1),
    const MsText('accento', tone: MsTextTone.accent, maxLines: 1),
  ]),
  row([const MsText.small('Scrivi', maxLines: 1), const MsCode('Survival')]),
  const MsDivider(),
]);

void main() {
  setUpAll(loadMsFonts);

  testWidgets('scala tipografica e aiuti', (t) async {
    await displayGoldens(t, 'text', _texts, size: const Size(640, 720));
  });

  testWidgets('eyebrow, etichetta e divisore', (t) async {
    await displayGoldens(
      t,
      'text_pixel',
      () => gallery(width: 320, [
        const MsEyebrow('Contenitori'),
        const MsText.label('Ultimo salvataggio'),
        const MsText.label('Stato', tone: MsTextTone.secondary),
        const MsDivider(),
      ]),
      pure: true,
      size: const Size(400, 200),
    );
  });

  testWidgets('il testo pixel su una riga è letto dalle tecnologie assistive', (t) async {
    final h = t.ensureSemantics();
    await t.pumpWidget(
      host(
        const Column(
          children: [
            MsText.label('Etichetta'),
            MsEyebrow('Sopra'),
            MsText('Corpo a capo', semanticsLabel: 'Corpo'),
          ],
        ),
      ),
    );
    expect(find.bySemanticsLabel('Etichetta'), findsOneWidget);
    expect(find.bySemanticsLabel('Sopra'), findsOneWidget);
    expect(find.bySemanticsLabel('Corpo'), findsOneWidget);
    h.dispose();
  });
}
