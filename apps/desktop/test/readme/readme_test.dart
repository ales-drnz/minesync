// Schermate del README, in inglese, disegnate dall'app stessa: sono golden
// che stanno in imgs/ alla radice del repository. Dopo un cambio grafico:
//   flutter test --update-goldens test/readme
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_desktop/src/state/app_state.dart';

import '../history_test.dart' show historyState;
import '../home_test.dart' show homeState;
import '../modpack_test.dart' show modState;
import '../server_test.dart' show serverState;
import '../session_screen_test.dart' show reachablePort, sessionAppState;
import '../support/app_harness.dart';
import '../support/session_fixtures.dart';

/// Disegna [state] in inglese a dpr 1.5 e lo confronta con imgs/[name].png.
Future<void> shot(
  WidgetTester t,
  String name,
  AppState state, {
  Size size = const Size(1280, 860),
  Future<void> Function(WidgetTester t)? prepare,
}) async {
  state.config.lang = 'en';
  const dpr = 1.5;
  await pumpApp(t, state, dpr: dpr, size: size);
  await prepare?.call(t);
  final ro = t.renderObject<RenderRepaintBoundary>(find.byKey(const Key('app')));
  final img = (await t.runAsync(() => ro.toImage(pixelRatio: dpr)))!;
  await expectLater(img, matchesGoldenFile('../../../../imgs/$name.png'));
  img.dispose();
}

void main() {
  setUpAll(loadFonts);

  testWidgets('home', (t) async {
    await shot(t, 'home', homeState(fullDisk: false), size: const Size(1280, 900));
  });

  testWidgets('server in gioco', (t) async {
    await shot(t, 'server', serverState(route: 'survival'), size: const Size(1280, 1000));
  });

  testWidgets('sessione', (t) async {
    await shot(
      t,
      'session',
      sessionAppState(sampleSession(), port: reachablePort),
      size: const Size(1280, 1000),
    );
  });

  testWidgets('mod', (t) async {
    await shot(t, 'mods', modState(), size: const Size(1280, 1000));
  });

  testWidgets('storia', (t) async {
    final s = historyState();
    await shot(
      t,
      'history',
      s,
      size: const Size(1280, 860),
      prepare: (t) async {
        await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await t.pump();
      },
    );
  });

  testWidgets('tema chiaro', (t) async {
    final s = homeState(fullDisk: false);
    s.config.prefs['theme'] = 'light';
    await shot(t, 'light', s, size: const Size(1280, 900));
  });
}
