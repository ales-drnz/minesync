// Schermate del README dell'hub web, in inglese: golden che stanno in imgs/
// alla radice del repository. Dopo un cambio grafico:
//   flutter test --update-goldens test/readme
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_hub_web/src/state/hub_state.dart';
import 'package:ms_l10n/ms_l10n.dart';

import '../admin_test.dart' show adminState;
import '../support/harness.dart';
import '../support/server_fixtures.dart';

/// Disegna [state] in inglese, tema scuro, e lo confronta con imgs/[name].png.
Future<void> shot(
  WidgetTester t,
  String name,
  HubState state, {
  String location = '/',
  Size size = const Size(1280, 900),
  double dpr = 1.5,
}) async {
  state
    ..setLang(Lang.en)
    ..setTheme(ThemeChoice.dark);
  await pumpHub(t, state, location: location, dpr: dpr, size: size);
  await settle(t);
  final ro = t.renderObject<RenderRepaintBoundary>(find.byKey(const Key('app')));
  final img = (await t.runAsync(() => ro.toImage(pixelRatio: dpr)))!;
  await expectLater(img, matchesGoldenFile('../../../../imgs/$name.png'));
  img.dispose();
}

/// Uno schermo di telefono vero, non tutta la pagina.
const _phone = Size(390, 844);

void main() {
  setUpAll(loadFonts);

  testWidgets('panoramica', (t) async {
    await shot(t, 'hub', testState(), size: const Size(1280, 1000));
  });

  testWidgets('admin', (t) async {
    final (s, _) = adminState();
    await shot(t, 'hub-admin', s, location: '/admin/general', size: const Size(1280, 1000));
  });

  testWidgets('telefono: panoramica', (t) async {
    await shot(t, 'phone-home', testState(), size: _phone, dpr: 2);
  });

  testWidgets('telefono: server', (t) async {
    await shot(
      t,
      'phone-server',
      serverState(),
      location: '/server/survival',
      size: _phone,
      dpr: 2,
    );
  });

  testWidgets('telefono: download', (t) async {
    final s = testState(platform: FakePlatform(userAgent: uaIphone));
    await shot(t, 'phone-download', s, location: '/dl', size: _phone, dpr: 2);
  });
}
