// Stato dell'app contro l'hub vero in-process: primo avvio, connessione,
// eventi live, caduta e ritorno dell'hub.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_desktop/src/platform/platform.dart';
import 'package:minesync_desktop/src/state/app_state.dart';
import 'package:minesync_hub/minesync_hub.dart';
import 'package:ms_core/ms_core.dart';
import 'package:ms_protocol/ms_protocol.dart';

Future<void> until(bool Function() ok, {Duration max = const Duration(seconds: 10)}) async {
  final sw = Stopwatch()..start();
  while (!ok()) {
    if (sw.elapsed > max) throw TimeoutException('condizione non raggiunta');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Directory tmp;
  late Hub hub;
  late AppState app;
  late int port;

  Future<void> bootHub() async {
    hub = await Hub.start(
      HubConfig(
        dataDir: '${tmp.path}/data',
        address: InternetAddress.loopbackIPv4,
        port: port,
        devUser: 'alice',
        admins: const ['alice'],
        keepAlive: const Duration(milliseconds: 200),
      ),
      log: (_) {},
    );
    port = hub.port;
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('ms_app');
    port = 0;
    await bootHub();
    app = AppState(
      AppDeps(
        configDir: '${tmp.path}/config',
        platform: PlatformServices.inert(),
        pollEvery: const Duration(milliseconds: 300),
        retryEvery: const Duration(milliseconds: 200),
      ),
    );
  });

  tearDown(() async {
    app.dispose();
    await hub.close();
    tmp.deleteSync(recursive: true);
  });

  test('senza hub: primo avvio; collegamento salvato solo se l\'hub risponde', () async {
    await app.start();
    expect(app.route, isA<FirstRunRoute>());
    await expectLater(app.connectTo('127.0.0.1:1'), throwsA(isA<HubUnreachable>()));
    expect(AppConfig.load('${tmp.path}/config').hub, isNull);
    final info = await app.connectTo('127.0.0.1:$port');
    expect(info.me.name, 'alice');
    expect(app.connection, Connection.online);
    expect(app.route, isA<HomeRoute>());
    expect(AppConfig.load('${tmp.path}/config').hub, 'http://127.0.0.1:$port');
  });

  test('eventi live: un server creato altrove compare da solo', () async {
    await app.connectTo('127.0.0.1:$port');
    expect(app.spaces, isEmpty);
    final other = HubClient(Uri.parse('http://127.0.0.1:$port/'));
    addTearDown(other.close);
    await other.createSpace('Survival', Profile.minecraft);
    await until(() => app.spaces.isNotEmpty);
    expect(app.spaces.single.name, 'Survival');
    expect(app.events.first.type, 'space.create');
  });

  test('hub che cade e torna: offline e poi di nuovo online da solo', () async {
    await app.connectTo('127.0.0.1:$port');
    await hub.close();
    await until(() => app.connection == Connection.offline);
    expect(app.offlineSince, isNotNull);
    // stessa porta: il socket in ascolto può metterci un attimo a liberarsi
    for (var i = 0; ; i++) {
      try {
        await bootHub();
        break;
      } on SocketException {
        if (i > 50) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    await until(() => app.connection == Connection.online, max: const Duration(seconds: 15));
    expect(app.latencyMs, isNotNull);
  });

  test('preferenze di tema e lingua salvate', () async {
    await app.setTheme(app.theme.copyWith(reducedMotion: true, sizeStep: 1));
    final again = AppState(
      AppDeps(configDir: '${tmp.path}/config', platform: PlatformServices.inert()),
    );
    addTearDown(again.dispose);
    expect(again.theme.reducedMotion, isTrue);
    expect(again.theme.sizeStep, 1);
  });

  test('tutta l\'attività: pagine più vecchie lette dall\'hub', () async {
    final other = HubClient(Uri.parse('http://127.0.0.1:$port/'));
    addTearDown(other.close);
    for (final n in ['Survival', 'Creativo', 'Avventura', 'Mondo 4', 'Mondo 5']) {
      await other.createSpace(n, Profile.minecraft);
    }
    await app.connectTo('127.0.0.1:$port');
    expect(app.events, hasLength(5));
    expect(app.olderEventsEnd, isTrue);
    // come se in memoria ci fossero solo le ultime due
    final recent = app.events.take(2).toList().reversed.toList();
    app.debugSet(events: recent, olderEnd: false);
    await app.loadOlderEvents(page: 2);
    expect([for (final e in app.events) e.seq], [5, 4, 3, 2]);
    expect(app.olderEventsEnd, isFalse);
    await app.loadOlderEvents(page: 2);
    expect([for (final e in app.events) e.seq], [5, 4, 3, 2, 1]);
    expect(app.olderEventsEnd, isTrue);
    // un evento nuovo va in cima, le pagine vecchie restano
    await other.createSpace('Nuovo', Profile.minecraft);
    await until(() => app.events.length == 6);
    expect(app.events.first.type, EventType.spaceCreate);
    expect(app.events.last.seq, 1);
  });

  test('prova della porta senza nessuno che ospita: rifiuto dell\'hub', () async {
    await app.connectTo('127.0.0.1:$port');
    final sp = await app.createSpace('Survival', Profile.minecraft);
    await expectLater(
      app.retryPortCheck(sp.id),
      throwsA(isA<ApiError>().having((e) => e.code, 'code', ErrorCode.notLocked)),
    );
  });

  test('pulizia manuale: anteprima e pulizia (admin), impostazioni del server', () async {
    await app.connectTo('127.0.0.1:$port');
    final sp = await app.createSpace('Survival', Profile.minecraft);
    final p = await app.gcPreview(20);
    expect(p.keep, 20);
    expect(p.spaces.single.id, sp.id);
    expect(p.bytes, 0);
    final r = await app.runGc(20);
    expect(r.generations, 0);
    await until(() => app.events.any((e) => e.type == EventType.gc));
    // impostazioni effettive del server (default di fabbrica)
    expect(app.details(sp.id), isNull);
    await app.loadDetails(sp.id);
    expect(app.sessionSettings(sp.id).autosaveMinutes, 5);
    expect(app.details(sp.id)!.settings, isNotNull);
  });
}
