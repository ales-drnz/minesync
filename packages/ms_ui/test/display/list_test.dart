import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';

import 'support.dart';

void main() {
  setUpAll(loadMsFonts);

  testWidgets('righe di lista: normale, hover, selezionata, focus, disattivata', (t) async {
    await displayGoldens(
      t,
      'list',
      () => gallery(width: 480, [
        MsList(
          semanticLabel: 'Server',
          children: [
            MsListRow(
              title: 'Survival',
              meta: 'collegato · #128',
              lead: const MsSlot.square(child: MsTexture(MsTextureKind.grass)),
              trail: const MsLock(label: 'Libero'),
              onTap: () {},
            ),
            MsListRow(
              title: 'Creativo',
              meta: 'pre-scarico 63 % · #41',
              lead: const MsSlot.square(child: MsTexture(MsTextureKind.stone)),
              onTap: () {},
              forceHover: true,
            ),
            MsListRow(
              title: 'Avventura',
              meta: 'collegato · #9',
              lead: const MsSlot.square(child: MsTexture(MsTextureKind.wood)),
              selected: true,
              onTap: () {},
            ),
            MsListRow(
              title: 'Minigiochi',
              meta: 'non collegato · #3',
              lead: const MsSlot.square(child: MsTexture(MsTextureKind.dirt)),
              onTap: () {},
              forceFocus: true,
            ),
            MsListRow(
              title: 'Vecchio mondo',
              meta: 'in eliminazione',
              lead: const MsSlot.square(child: MsTexture(MsTextureKind.slate)),
              enabled: false,
              trail: const MsSpinner(),
              onTap: () {},
            ),
          ],
        ),
        const MsList(
          children: [
            MsListRow(
              titleSpans: [MsSpan('alice', strong: true), MsSpan(' ha preso il lock')],
              meta: 'Survival',
              lead: MsBadge('Avvio', kind: MsBadgeKind.lock),
              time: '18:47',
            ),
            MsListRow(
              titleSpans: [MsSpan('bob', strong: true), MsSpan(' ha caricato la generazione #127')],
              meta: 'Survival · +12 ~48 −3',
              lead: MsBadge('Salva', kind: MsBadgeKind.push),
              time: '12:34',
            ),
          ],
        ),
        const MsList(
          flat: true,
          gap: 4,
          children: [
            MsText.mono('region/r.0.0.mca · 7,8 MB', tone: MsTextTone.secondary),
            MsText.mono('region/r.-1.0.mca · 6,1 MB', tone: MsTextTone.secondary),
          ],
        ),
      ]),
      size: const Size(560, 720),
    );
  });

  testWidgets('tabella e scorrimento orizzontale', (t) async {
    await displayGoldens(
      t,
      'table',
      () => gallery(width: 560, [
        const MsTable(
          semanticLabel: 'Storia',
          columns: [
            MsTableColumn('Gen', width: 64),
            MsTableColumn('Chi'),
            MsTableColumn('Attività', flex: 1),
            MsTableColumn('Dimensione', end: true),
          ],
          rows: [
            [
              MsText.small('#128', tabular: true),
              MsText.small('alice'),
              MsBadge('Salva', kind: MsBadgeKind.push),
              MsText.small('31 MB', tabular: true),
            ],
            [
              MsText.small('#127', tabular: true),
              MsText.small('bob'),
              MsBadge('Ripristino', kind: MsBadgeKind.restore),
              MsText.small('1,4 GB', tabular: true),
            ],
          ],
        ),
        const SizedBox(
          width: 240,
          child: MsScrollX(
            child: SizedBox(
              width: 480,
              child: MsTable(
                columns: [MsTableColumn('A', width: 200), MsTableColumn('B', width: 200)],
                rows: [
                  [MsText.small('uno'), MsText.small('due')],
                ],
              ),
            ),
          ),
        ),
      ]),
      size: const Size(640, 320),
    );
  });

  testWidgets('geometria delle righe senza testo (pixel pura)', (t) async {
    await displayGoldens(
      t,
      'list_geometry',
      () => gallery(width: 320, [
        MsList(
          children: [
            MsListRow(title: '', onTap: () {}),
            MsListRow(title: '', onTap: () {}, forceHover: true),
            MsListRow(title: '', onTap: () {}, selected: true),
            MsListRow(title: '', onTap: () {}, forceFocus: true),
            const MsListRow(title: '', enabled: false),
          ],
        ),
      ]),
      pure: true,
      size: const Size(400, 400),
    );
  });

  testWidgets('riga: clic, Invio e semantica', (t) async {
    final h = t.ensureSemantics();
    var taps = 0;
    await t.pumpWidget(
      host(
        Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 300,
            child: MsList(
              children: [
                MsListRow(title: 'Survival', selected: true, onTap: () => taps++),
                const MsListRow(title: 'Creativo', enabled: false),
              ],
            ),
          ),
        ),
      ),
    );
    await t.tap(find.bySemanticsLabel('Survival'));
    expect(taps, 1);
    expect(
      t.getSemantics(find.bySemanticsLabel('Survival')),
      isSemantics(isButton: true, isSelected: true, isEnabled: true),
    );
    final frame = find.descendant(
      of: find.byType(MsListRow).first,
      matching: find.byType(PixelFrame),
    );
    Focus.of(t.element(frame.first)).requestFocus();
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(taps, 2);
    h.dispose();
  });

  testWidgets('riga: il titolo va a capo con titleMaxLines null', (t) async {
    const long = 'carol ha chiuso il server dopo 2 h 05 min e ha salvato la versione nuova';
    Future<double> height(int? lines) async {
      await t.pumpWidget(
        host(
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 240,
              child: MsListRow(
                titleSpans: const [MsSpan(long)],
                meta: 'Creativo',
                titleMaxLines: lines,
              ),
            ),
          ),
        ),
      );
      return t.getSize(find.byType(MsListRow)).height;
    }

    final one = await height(1);
    final wrapped = await height(null);
    expect(wrapped, greaterThan(one));
  });
}
