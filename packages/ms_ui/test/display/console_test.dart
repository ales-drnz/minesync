import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';

import 'support.dart';

String _live(int n) => '$n righe nuove · torna live';

const _sample = [
  MsConsoleLine(
    '[MineSync] Avvio con Java 21 · run.sh · 6 GB',
    time: '17:30:04',
    level: 'MS',
    kind: MsLineKind.dim,
  ),
  MsConsoleLine('Preparing level "world"', time: '17:30:11', level: 'INFO'),
  MsConsoleLine(
    '[MineSync] Server pronto: gli amici possono entrare',
    time: '17:30:19',
    level: 'MS',
    kind: MsLineKind.ok,
  ),
  MsConsoleLine(
    'alice joined the game',
    time: '17:31:02',
    level: 'JOIN',
    kind: MsLineKind.join,
    match: true,
  ),
  MsConsoleLine('<alice> ciao! porto i semi', time: '17:35:40', level: 'INFO', match: true),
  MsConsoleLine(
    "Can't keep up! Is the server overloaded? Running 2300ms or 46 ticks behind",
    time: '17:52:13',
    level: 'WARN',
    kind: MsLineKind.warn,
  ),
  MsConsoleLine(
    '[create] Failed to load contraption data at -112 64 380, skipping',
    time: '18:12:44',
    level: 'ERR',
    kind: MsLineKind.err,
  ),
  MsConsoleLine('> time set day', time: '18:20:31', level: 'CMD', kind: MsLineKind.cmd),
  MsConsoleLine('Set the time to 1000', time: '18:20:31', level: 'INFO'),
  MsConsoleLine('bob left the game', time: '18:33:58', level: 'LEFT', kind: MsLineKind.join),
];

/// Righe deterministiche di prova.
List<MsConsoleLine> _lines(int n, [int from = 0]) => [
  for (var i = from; i < from + n; i++) _sample[i % _sample.length].copyWith(match: false),
];

Widget _console({
  required List<MsConsoleLine> lines,
  Key? key,
  bool chrome = true,
  bool wrap = true,
}) => MsConsole(
  key: key,
  lines: lines,
  liveLabel: _live,
  wrap: wrap,
  semanticLabel: 'Console del server',
  toolbar: chrome
      ? const MsRow(children: [MsChip('Tutto'), MsChip('Errori'), MsLive('3 risultati')])
      : null,
  input: chrome
      ? Builder(
          builder: (context) =>
              MsText.mono('say ciao', color: MsTheme.colorsOf(context).conDim, maxLines: 1),
        )
      : null,
  footer: chrome ? const MsRow(children: [MsChip('list'), MsChip('time set day')]) : null,
);

void main() {
  setUpAll(loadMsFonts);

  testWidgets('console: righe, barra, campo (normale)', (t) async {
    await displayGoldens(
      t,
      'console',
      () => SizedBox(width: 640, height: 420, child: _console(lines: _sample)),
      size: const Size(680, 460),
    );
  });

  testWidgets('console alta e senza a capo', (t) async {
    await displayGoldens(
      t,
      'console_nowrap',
      () => Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 16,
        children: [
          SizedBox(width: 640, height: 300, child: _console(lines: _sample)),
          SizedBox(
            width: 400,
            height: 200,
            child: _console(lines: _sample, chrome: false, wrap: false),
          ),
        ],
      ),
      size: const Size(680, 560),
    );
  });

  testWidgets('console: pulsante "torna live" dopo lo scorrimento indietro', (t) async {
    final lines = _lines(200);
    final key = GlobalKey<MsConsoleState>();
    for (final dpr in [1.0, 2.0]) {
      setGoldenView(t, dpr, size: const Size(680, 460));
      await t.pumpWidget(
        goldenHost(
          dpr,
          SizedBox(
            width: 640,
            height: 420,
            child: _console(lines: lines, key: key),
          ),
        ),
      );
      await t.pump();
      await t.drag(find.byType(ListView), const Offset(0, 300));
      await t.pump();
      lines.addAll(_lines(12, 200));
      await t.pumpWidget(
        goldenHost(
          dpr,
          SizedBox(
            width: 640,
            height: 420,
            child: _console(lines: lines, key: key),
          ),
        ),
      );
      await t.pump();
      expect(key.currentState!.isLive, isFalse);
      expect(key.currentState!.newLines, 12);
      final img = await captureGolden(t);
      await expectLater(
        img,
        matchesGoldenFile('goldens/console_live/dpr_${dpr.toStringAsFixed(2)}.png'),
      );
      img.dispose();
      lines.removeRange(200, lines.length);
      key.currentState!.goLive();
      await t.pump();
    }
  });

  testWidgets('virtualizzata: con 2000 righe costruisce solo quelle visibili', (t) async {
    final lines = _lines(2000);
    await t.pumpWidget(
      host(SizedBox(width: 600, height: 400, child: _console(lines: lines, chrome: false))),
    );
    await t.pump();
    final built = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_LineView');
    expect(built.evaluate().length, lessThan(60));
    // parte in fondo (live)
    final pos = t.state<ScrollableState>(find.byType(Scrollable)).position;
    expect(pos.pixels, pos.maxScrollExtent);
  });

  testWidgets('segue le righe nuove a 60 Hz finché è live', (t) async {
    final lines = _lines(500);
    final key = GlobalKey<MsConsoleState>();
    Widget build() => host(
      SizedBox(
        width: 600,
        height: 400,
        child: _console(lines: lines, key: key, chrome: false),
      ),
    );
    await t.pumpWidget(build());
    await t.pump();
    final sw = Stopwatch()..start();
    for (var f = 0; f < 120; f++) {
      lines.add(_sample[f % _sample.length]);
      await t.pumpWidget(build());
      await t.pump(const Duration(milliseconds: 16));
    }
    sw.stop();
    final pos = t.state<ScrollableState>(find.byType(Scrollable)).position;
    expect(pos.pixels, pos.maxScrollExtent);
    expect(key.currentState!.isLive, isTrue);
    expect(key.currentState!.newLines, 0);
    // 120 fotogrammi con 620 righe: ben sotto il secondo anche in debug
    expect(sw.elapsedMilliseconds, lessThan(5000));
  });

  testWidgets('scorrendo indietro la vista resta ferma; torna live con il pulsante', (t) async {
    final lines = _lines(300);
    final key = GlobalKey<MsConsoleState>();
    bool? liveEvent;
    Widget build() => host(
      SizedBox(
        width: 600,
        height: 400,
        child: MsConsole(
          key: key,
          lines: lines,
          liveLabel: _live,
          onLiveChanged: (v) => liveEvent = v,
        ),
      ),
    );
    await t.pumpWidget(build());
    await t.pump();
    final pos = t.state<ScrollableState>(find.byType(Scrollable)).position;
    // rotella del mouse verso l'alto
    final center = t.getCenter(find.byType(ListView));
    t.binding.handlePointerEvent(
      PointerScrollEvent(position: center, scrollDelta: const Offset(0, -400)),
    );
    await t.pump();
    expect(key.currentState!.isLive, isFalse);
    expect(liveEvent, isFalse);
    final before = pos.pixels;
    lines.addAll(_lines(5, 300));
    await t.pumpWidget(build());
    await t.pump();
    expect(pos.pixels, before);
    expect(find.bySemanticsLabel(_live(5)), findsOneWidget);
    lines.addAll(_lines(7, 305));
    await t.pumpWidget(build());
    await t.pump();
    expect(find.bySemanticsLabel(_live(12)), findsOneWidget);
    await t.tap(find.bySemanticsLabel(_live(12)));
    await t.pump();
    await t.pump();
    expect(key.currentState!.isLive, isTrue);
    expect(liveEvent, isTrue);
    expect(pos.pixels, pos.maxScrollExtent);
    expect(find.bySemanticsLabel(RegExp('torna live')), findsNothing);
  });

  testWidgets('il tasto Fine torna live; tornando in fondo a mano si è live', (t) async {
    final lines = _lines(300);
    final key = GlobalKey<MsConsoleState>();
    await t.pumpWidget(
      host(
        SizedBox(
          width: 600,
          height: 400,
          child: _console(lines: lines, key: key),
        ),
      ),
    );
    await t.pump();
    await t.drag(find.byType(ListView), const Offset(0, 300));
    await t.pump();
    expect(key.currentState!.isLive, isFalse);
    // trascinando di nuovo fino in fondo si torna live
    await t.drag(find.byType(ListView), const Offset(0, -2000));
    await t.pump();
    expect(key.currentState!.isLive, isTrue);
    // Fine
    await t.drag(find.byType(ListView), const Offset(0, 300));
    await t.pump();
    expect(key.currentState!.isLive, isFalse);
    Focus.of(t.element(find.byType(ListView))).requestFocus();
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.end);
    await t.pump();
    await t.pump();
    expect(key.currentState!.isLive, isTrue);
  });

  testWidgets('selezione e copia del testo', (t) async {
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
      if (c.method == 'Clipboard.setData') {
        copied = (c.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () =>
          t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await t.pumpWidget(
      host(
        Overlay(
          initialEntries: [
            OverlayEntry(
              builder: (_) => Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 600,
                  height: 400,
                  child: _console(lines: _sample, chrome: false),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    await t.pump();
    final region = t.state<SelectableRegionState>(find.byType(SelectableRegion));
    region.selectAll(SelectionChangedCause.keyboard);
    await t.pump();
    Actions.invoke(t.element(find.byType(ListView)), CopySelectionTextIntent.copy);
    await t.pump();
    expect(copied, contains('Preparing level "world"'));
    expect(copied, contains('17:30:11'));
  });

  test('testo semplice per "copia tutto"', () {
    expect(
      MsConsole.plainText(_sample.take(2)),
      '17:30:04 MS [MineSync] Avvio con Java 21 · run.sh · 6 GB\n'
      '17:30:11 INFO Preparing level "world"',
    );
    expect(MsConsole.plainText(const [MsConsoleLine('solo testo')]), 'solo testo');
  });

  testWidgets('semantica: nome della console e ultima riga annunciata', (t) async {
    final h = t.ensureSemantics();
    final lines = _lines(20);
    Widget build() =>
        host(SizedBox(width: 600, height: 400, child: _console(lines: lines, chrome: false)));
    await t.pumpWidget(build());
    expect(find.bySemanticsLabel('Console del server'), findsOneWidget);
    lines.add(const MsConsoleLine('carol joined the game', kind: MsLineKind.join));
    await t.pumpWidget(build());
    await t.pump();
    final last = find.bySemanticsLabel('carol joined the game');
    expect(last, findsWidgets);
    expect(t.getSemantics(last.last), isSemantics(isLiveRegion: true));
    h.dispose();
  });
}
