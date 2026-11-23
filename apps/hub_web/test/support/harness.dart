// Supporto ai test della web UI: stato con dati di esempio (nessuna rete),
// app montata su un percorso, caratteri del design system e golden ai dpr
// 1.0 e 1.5 come per l'app desktop. Golden generati su Linux con TZ=UTC.
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_hub_web/src/app.dart';
import 'package:minesync_hub_web/src/router.dart';
import 'package:minesync_hub_web/src/state/hub_state.dart';
import 'package:ms_protocol/ms_protocol.dart';

import 'fake_hub_api.dart';
import 'fake_platform.dart';
import 'fixtures.dart';

export 'fake_hub_api.dart';
export 'fake_platform.dart';
export 'finders.dart';
export 'fixtures.dart';

/// Carica i caratteri di ms_ui nel motore di test.
Future<void> loadFonts() async {
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

/// Stato con hub, server e attività di esempio, già "online", senza timer.
/// [me] sceglie chi guarda (alice admin, bob membro); [setup] lo modifica.
HubState testState({
  Me me = alice,
  FakeHubApi? api,
  FakePlatform? platform,
  void Function(HubState s)? setup,
}) {
  final a = api ?? FakeHubApi(hub: sampleHub(me: me));
  final s = HubState(HubDeps(api: a, platform: platform ?? FakePlatform(), clock: () => testNow));
  s.debugSet(
    connection: HubConnection.online,
    hub: a.hubInfo,
    latencyMs: 18,
    spaces: a.spaceList,
    events: a.eventLog,
  );
  setup?.call(s);
  addTearDown(s.dispose);
  return s;
}

/// L'API finta dietro [s].
FakeHubApi fakeApi(HubState s) => s.api as FakeHubApi;

/// La piattaforma finta dietro [s].
FakePlatform fakePlatform(HubState s) => s.platform as FakePlatform;

/// Monta l'app su [location] a [dpr] in una finestra logica di [size].
Future<void> pumpHub(
  WidgetTester t,
  HubState state, {
  String location = '/',
  double dpr = 1.0,
  Size size = const Size(1280, 900),
}) async {
  t.view
    ..devicePixelRatio = dpr
    ..physicalSize = size * dpr;
  addTearDown(t.view.reset);
  final router = buildRouter(initialLocation: location);
  addTearDown(router.dispose);
  await t.pumpWidget(
    RepaintBoundary(
      key: const Key('app'),
      child: HubWebApp(state: state, router: router),
    ),
  );
  await t.pump();
  await t.pump();
}

/// Golden della finestra intera a dpr 1.0 e 1.5 (alla risoluzione fisica).
Future<void> expectHubGolden(
  WidgetTester t,
  String name,
  HubState state, {
  String location = '/',
  Size size = const Size(1280, 900),
  List<double> dprs = const [1.0, 1.5],
  Future<void> Function(WidgetTester t)? prepare,
}) async {
  for (final dpr in dprs) {
    await pumpHub(t, state, location: location, dpr: dpr, size: size);
    await prepare?.call(t);
    final ro = t.renderObject<RenderRepaintBoundary>(find.byKey(const Key('app')));
    final img = (await t.runAsync(() => ro.toImage(pixelRatio: dpr)))!;
    await expectLater(img, matchesGoldenFile('goldens/$name/dpr_${dpr.toStringAsFixed(2)}.png'));
    img.dispose();
  }
}

/// Titolo della scheda del browser della pagina mostrata.
String documentTitle(WidgetTester t) => t.widgetList<Title>(find.byType(Title)).last.title;

/// Lascia finire animazioni brevi (dialoghi, notifiche). Non si usa
/// pumpAndSettle: la pillola "dal vivo" pulsa sempre.
Future<void> settle(WidgetTester t) async {
  await t.pump();
  for (var i = 0; i < 5; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}
