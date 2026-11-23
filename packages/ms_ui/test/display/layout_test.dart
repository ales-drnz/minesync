import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';
import 'package:ms_ui/src/components/display/common.dart';

import 'support.dart';

Iterable<Color> _extra(MsColors c) => [msBlend(c.drop, c.bg)];

const _a = Key('a');
const _b = Key('b');
const _c = Key('c');

// Una pagina con due colonne: a sinistra un pannello alto, a destra due
// pannelli corti (il secondo si allunga) come Home e Panoramica.
Widget _columns() => const SizedBox(
  width: 600,
  child: MsEqualRow(
    flex: [2, 1],
    children: [
      MsPanel(
        key: _a,
        title: 'Attività',
        foot: [SizedBox(width: 80, height: 20)],
        child: SizedBox(height: 180),
      ),
      MsStack(
        gap: 24,
        fillLast: true,
        children: [
          MsPanel(
            key: _b,
            title: 'Rete',
            actions: [MsPill('Off', tone: MsStatusTone.warn)],
            child: SizedBox(height: 24),
          ),
          MsPanel(
            key: _c,
            title: 'Questo PC',
            foot: [SizedBox(width: 60, height: 20)],
            child: SizedBox(height: 24),
          ),
        ],
      ),
    ],
  ),
);

void main() {
  setUpAll(loadMsFonts);

  testWidgets('colonne alte uguali: pannelli, testate e piedi (pixel puri)', (t) async {
    await displayGoldens(
      t,
      'columns',
      _columns,
      pure: true,
      extra: _extra,
      size: const Size(640, 420),
    );
  });

  testWidgets('MsEqualRow: colonne alte quanto la più alta, pesi e distanza', (t) async {
    await t.pumpWidget(host(Center(child: _columns())));
    final a = t.getRect(find.byKey(_a));
    final b = t.getRect(find.byKey(_b));
    final c = t.getRect(find.byKey(_c));
    // il fondo della colonna di destra (ultimo pannello allungato) coincide
    // con quello di sinistra
    expect(c.bottom, a.bottom);
    expect(b.top, a.top);
    // pesi 2:1 con 24 px di distanza su 600
    expect(a.width, closeTo((600 - 24) * 2 / 3, 1));
    expect(b.left - a.right, closeTo(24, 1));
  });

  testWidgets('testata di pannello: sempre 40 px, anche con una pillola', (t) async {
    await t.pumpWidget(
      host(
        const Center(
          child: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                MsPanelHead(key: _a, title: 'Sul tuo PC'),
                MsPanelHead(
                  key: _b,
                  title: 'Sull\'hub',
                  actions: [MsPill('Non collegato', tone: MsStatusTone.warn)],
                ),
                MsPanelHead(key: _c, title: 'Attività', actions: [MsLive('Live')]),
              ],
            ),
          ),
        ),
      ),
    );
    for (final k in [_a, _b, _c]) {
      expect(t.getSize(find.byKey(k)).height, 40, reason: '$k');
    }
  });

  testWidgets('pannello: con altezza imposta il piede va in fondo, senza segue il contenuto', (
    t,
  ) async {
    const foot = Key('foot');
    const body = Key('body');
    Widget panel() => const MsPanel(
      title: 'Pannello',
      foot: [SizedBox(key: foot, width: 40, height: 20)],
      child: SizedBox(key: body, height: 30),
    );
    await t.pumpWidget(host(Center(child: SizedBox(width: 300, height: 400, child: panel()))));
    final r = t.getRect(find.byType(MsPanel));
    expect(r.height, 400);
    // piede: padding inferiore 12 + contorno 2 dal bordo
    expect(t.getRect(find.byKey(foot)).bottom, closeTo(r.bottom - 14, 1));
    // corpo in alto: testata 40 + padding 16 + contorno 2
    expect(t.getRect(find.byKey(body)).top, closeTo(r.top + 58, 1));

    // altezza solo limitata (dialogo): il pannello segue il contenuto
    await t.pumpWidget(
      host(
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300, maxHeight: 400),
            child: panel(),
          ),
        ),
      ),
    );
    final h = t.getSize(find.byType(MsPanel)).height;
    expect(h, lessThan(200));
  });

  testWidgets('MsStack(fillLast): l\'ultimo figlio si allunga solo con altezza imposta', (t) async {
    Widget stack() => const MsStack(
      fillLast: true,
      children: [
        SizedBox(key: _a, height: 40),
        SizedBox(key: _b, height: 40),
      ],
    );
    await t.pumpWidget(host(Center(child: SizedBox(width: 200, height: 300, child: stack()))));
    expect(t.getSize(find.byKey(_b)).height, 300 - 40 - 16);
    await t.pumpWidget(host(Center(child: SizedBox(width: 200, child: stack()))));
    expect(t.getSize(find.byKey(_b)).height, 40);
    expect(t.getSize(find.byType(MsStack)).height, 96);
  });

  testWidgets('MsEqualRow: se il contenuto di una colonna cresce la riga si rimisura', (t) async {
    final tall = ValueNotifier(false);
    addTearDown(tall.dispose);
    await t.pumpWidget(
      host(
        Center(
          child: SizedBox(
            width: 400,
            child: MsEqualRow(
              children: [
                const MsPanel(key: _a, title: 'A', child: SizedBox(height: 40)),
                MsPanel(
                  key: _b,
                  title: 'B',
                  foot: const [SizedBox(width: 20, height: 20)],
                  child: ValueListenableBuilder(
                    valueListenable: tall,
                    builder: (_, v, _) => SizedBox(height: v ? 200 : 20),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final before = t.getSize(find.byKey(_a)).height;
    tall.value = true;
    await t.pump();
    expect(t.takeException(), isNull);
    final after = t.getSize(find.byKey(_a)).height;
    expect(after, greaterThan(before + 100));
    expect(t.getSize(find.byKey(_b)).height, after);
  });
}
