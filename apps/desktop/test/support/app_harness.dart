// Supporto ai test delle schermate: l'app con dati pre-caricati (nessuna
// rete), caratteri del design system e golden ai dpr del design.
import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_desktop/src/app.dart';
import 'package:minesync_desktop/src/platform/platform.dart';
import 'package:minesync_desktop/src/state/app_state.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import 'modpack_fakes.dart';
import 'space_fakes.dart';

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

/// Dati di esempio: hub, giocatori e server con nomi generici.
const sampleMe = Me(id: 'a1a1a1a1a1', name: 'alice', admin: true);

HubInfo sampleHub({bool admin = true}) => HubInfo(
  name: 'Homelab',
  version: '0.1.0',
  api: 1,
  time: DateTime.utc(2026, 11, 22, 18).millisecondsSinceEpoch,
  disk: const DiskInfo(free: 18 << 30, total: 2000 << 30, minFree: 1 << 30),
  me: Me(id: sampleMe.id, name: sampleMe.name, admin: admin),
);

GenerationSummary sampleGen(int n, {String author = 'bob'}) => GenerationSummary(
  n: n,
  parent: n - 1,
  digest: n.toRadixString(16).padLeft(64, '0'),
  authorId: author,
  author: author,
  message: '',
  ts: DateTime.utc(2026, 11, 22, 17, 30).millisecondsSinceEpoch,
  kind: GenerationKind.autosave,
  stats: const GenerationStats(files: 1200, size: 900 << 20, added: 3, changed: 40),
);

List<SpaceSummary> sampleSpaces() => [
  SpaceSummary(
    id: 'survival',
    name: 'Survival',
    profile: Profile.minecraft,
    createdAt: 0,
    head: sampleGen(128),
    lock: LockHolder(
      memberId: 'b2',
      name: 'bob',
      since: DateTime.utc(2026, 11, 22, 17, 30).millisecondsSinceEpoch,
      lastBeat: DateTime.utc(2026, 11, 22, 18).millisecondsSinceEpoch,
      stale: false,
      info: const LockInfo(action: 'play', players: ['bob', 'carol'], port: 25565),
    ),
  ),
  SpaceSummary(
    id: 'creativo',
    name: 'Creativo',
    profile: Profile.minecraft,
    createdAt: 0,
    head: sampleGen(57, author: 'carol'),
    lock: null,
  ),
  SpaceSummary(
    id: 'avventura',
    name: 'Avventura',
    profile: Profile.minecraft,
    createdAt: 0,
    head: sampleGen(212),
    lock: const LockHolder(
      memberId: 'c3',
      name: 'carol',
      since: 0,
      lastBeat: 0,
      stale: true,
      info: LockInfo(action: 'play'),
    ),
  ),
];

/// Crea lo stato dell'app senza rete, in una cartella di configurazione
/// temporanea, e lo popola con [setup].
AppState testState({
  void Function(AppState)? setup,
  Map<String, Object?> prefs = const {},
  ModpackEnv? modpack,
}) {
  final dir = Directory.systemTemp.createTempSync('ms_app_test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final s = AppState(
    AppDeps(
      configDir: dir.path,
      platform: PlatformServices.inert(),
      modpack: modpack ?? fakeModpackEnv(),
    ),
  );
  s.config.prefs.addAll(prefs);
  useFakes(s);
  s.debugSet(
    connection: Connection.online,
    hub: sampleHub(),
    latencyMs: 42,
    spaces: sampleSpaces(),
  );
  setup?.call(s);
  addTearDown(s.dispose);
  return s;
}

/// Monta l'app a [dpr] su una finestra logica di [size].
Future<void> pumpApp(
  WidgetTester t,
  AppState state, {
  PlatformServices? platform,
  double dpr = 1.0,
  Size size = const Size(1280, 860),
}) async {
  t.view
    ..devicePixelRatio = dpr
    ..physicalSize = size * dpr;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    RepaintBoundary(
      key: const Key('app'),
      child: MinesyncApp(
        state: state,
        platform: platform ?? PlatformServices.inert(),
        os: MsTitlebarOs.linux,
      ),
    ),
  );
  await t.pump();
}

/// Golden dell'intera finestra a dpr 1.0 e 1.5 (alla risoluzione fisica).
Future<void> expectAppGolden(
  WidgetTester t,
  String name,
  AppState state, {
  Size size = const Size(1280, 860),
  List<double> dprs = const [1.0, 1.5],
  Future<void> Function(WidgetTester t)? prepare,
}) async {
  for (final dpr in dprs) {
    await pumpApp(t, state, dpr: dpr, size: size);
    // es. aprire un dialogo (resta aperto tra un dpr e l'altro)
    await prepare?.call(t);
    final ro = t.renderObject<RenderRepaintBoundary>(find.byKey(const Key('app')));
    final img = (await t.runAsync(() => ro.toImage(pixelRatio: dpr)))!;
    await expectLater(img, matchesGoldenFile('goldens/$name/dpr_${dpr.toStringAsFixed(2)}.png'));
    img.dispose();
  }
}
