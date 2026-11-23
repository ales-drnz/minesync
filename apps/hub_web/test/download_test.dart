// Download: file per questo PC dal sistema riconosciuto, tutte le
// piattaforme, SHA-256, stati senza file e da telefono, golden.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_hub_web/src/platform/client_os.dart';
import 'package:minesync_hub_web/src/state/hub_state.dart';
import 'package:ms_l10n/ms_l10n.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import 'support/harness.dart';

void main() {
  setUpAll(loadFonts);

  group('sistema del visitatore', () {
    test('desktop riconosciuti, telefoni no', () {
      expect(ClientOs.detect(uaWindows)?.os, DlOs.windows);
      expect(ClientOs.detect(uaWindows)?.arch, 'x64');
      expect(ClientOs.detect(uaMac)?.os, DlOs.macos);
      expect(ClientOs.detect(uaLinux)?.os, DlOs.linux);
      expect(ClientOs.detect(uaAndroid), isNull);
      expect(ClientOs.detect(uaIphone), isNull);
      expect(ClientOs.detect(''), isNull);
    });

    test('scelta del file: architettura, universal, nessun file', () {
      final files = [
        const DlFile(name: 'a-arm64.AppImage', os: DlOs.linux, size: 1, arch: 'arm64'),
        const DlFile(name: 'a-x64.AppImage', os: DlOs.linux, size: 1, arch: 'x64'),
        const DlFile(name: 'a.dmg', os: DlOs.macos, size: 1, arch: 'universal'),
      ];
      expect(const ClientOs(DlOs.linux).pick(files)?.name, 'a-x64.AppImage');
      expect(const ClientOs(DlOs.linux, arch: 'arm64').pick(files)?.name, 'a-arm64.AppImage');
      expect(const ClientOs(DlOs.macos).pick(files)?.name, 'a.dmg');
      expect(const ClientOs(DlOs.windows).pick(files), isNull);
    });
  });

  testWidgets('per questo PC: Windows, Scarica porta a /dl/<file>', (t) async {
    final s = testState();
    await pumpHub(t, s, location: '/dl', size: const Size(1280, 1800));
    await t.pump();
    expect(msText('Per questo PC: Windows'), findsWidgets);
    expect(msText('MineSync per Windows'), findsOneWidget);
    await t.tap(msButton('Scarica per Windows'));
    expect(fakePlatform(s).downloads, [Uri.parse('http://192.0.2.1/dl/MineSync-0.1.0-setup.exe')]);
    expect(documentTitle(t), 'Download (Homelab)');
  });

  testWidgets('tutte le piattaforme e SHA-256 copiabile', (t) async {
    final s = testState(platform: FakePlatform(userAgent: uaLinux));
    await pumpHub(t, s, location: '/dl', size: const Size(1280, 2000));
    await t.pump();
    expect(msText('MineSync per Linux'), findsOneWidget);
    expect(msText('MineSync-0.1.0.dmg'), findsOneWidget);
    await t.tap(msButton('Verifica l\'integrità (SHA-256)'));
    await t.pump();
    await t.tap(find.bySemanticsLabel('Copia SHA-256 MineSync-0.1.0.dmg'));
    await settle(t);
    expect(fakePlatform(s).copied, [sampleDownloads().files[1].sha256]);
    expect(
      find.byWidgetPredicate((w) => w is MsToast && w.title == 'Copiato negli appunti'),
      findsOneWidget,
    );
  });

  testWidgets('dal telefono: niente "per questo PC", c\'è la nota', (t) async {
    final s = testState(platform: FakePlatform(userAgent: uaAndroid));
    await pumpHub(t, s, location: '/dl', size: const Size(375, 2400));
    await t.pump();
    expect(msTextContaining('Per questo PC'), findsNothing);
    expect(msText('Da telefono'), findsOneWidget);
  });

  testWidgets('requisiti: Java 25 per Minecraft 26.x (come ms_minecraft requiredJava)', (t) async {
    await pumpHub(t, testState(), location: '/dl', size: const Size(1280, 2400));
    await t.pump();
    expect(msTextContaining('Minecraft 26.x richiede Java 25'), findsOneWidget);
  });

  testWidgets('nessun file: stato vuoto diverso per admin e membri', (t) async {
    await pumpHub(
      t,
      testState(
        api: FakeHubApi(dl: const DlListing(files: [])),
      ),
      location: '/dl',
    );
    await t.pump();
    expect(msText('Nessun download su questo hub'), findsOneWidget);
    expect(msTextContaining('MINESYNC_DL'), findsOneWidget);
  });

  testWidgets('errore di lettura: avviso con Riprova', (t) async {
    final api = FakeHubApi();
    final s = testState(api: api);
    api.failWith = const ApiError(ErrorCode.internal, 'boom');
    await pumpHub(t, s, location: '/dl');
    await t.pump();
    expect(msText('Impossibile leggere l\'elenco dei download'), findsOneWidget);
    api.failWith = null;
    await t.tap(msButton('Riprova'));
    await settle(t);
    expect(api.calls.where((c) => c == 'downloads').length, 2);
    expect(msText('MineSync per Windows'), findsOneWidget);
  });

  testWidgets('golden: download', (t) async {
    await expectHubGolden(
      t,
      'download',
      testState(),
      location: '/dl',
      size: const Size(1280, 1900),
      prepare: (t) => t.pump(),
    );
  });

  testWidgets('golden: download senza file, tema scuro, inglese', (t) async {
    final s = testState(
      me: bob,
      api: FakeHubApi(
        hub: sampleHub(me: bob),
        dl: const DlListing(files: []),
      ),
      setup: (s) => s
        ..setTheme(ThemeChoice.dark)
        ..setLang(Lang.en),
    );
    await expectHubGolden(
      t,
      'download_empty',
      s,
      location: '/dl',
      size: const Size(1280, 1000),
      prepare: (t) => t.pump(),
    );
  });

  testWidgets('golden: download da telefono', (t) async {
    final s = testState(platform: FakePlatform(userAgent: uaIphone));
    await expectHubGolden(
      t,
      'download_phone',
      s,
      location: '/dl',
      size: const Size(375, 3000),
      prepare: (t) => t.pump(),
    );
  });
}
