// Sessione dell'app contro l'hub vero in-process, con il server Minecraft
// finto: EULA chiesta all'utente, avvio, giocatori, salvataggio, arresto,
// conflitto con le modifiche locali (versione dell'hub o le mie), Java
// mancante, avvio da AppState.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_desktop/src/platform/platform.dart';
import 'package:minesync_desktop/src/state/app_state.dart';
import 'package:minesync_hub/minesync_hub.dart';
import 'package:ms_core/ms_core.dart';
import 'package:ms_minecraft/ms_minecraft.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_session/ms_session.dart';
import 'package:ms_session/testing/fake_server.dart';

Future<void> until(bool Function() ok, {Duration max = const Duration(seconds: 15)}) async {
  final sw = Stopwatch()..start();
  while (!ok()) {
    if (sw.elapsed > max) throw TimeoutException('condizione non raggiunta');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

const _config = SessionConfig(
  autosaveEvery: Duration(minutes: 10),
  emptyStopAfter: null,
  maxRestarts: 1,
  flushWait: Duration(seconds: 2),
  quietStable: Duration(milliseconds: 50),
  quietCap: Duration(seconds: 1),
);

void main() {
  late Directory tmp;
  late Hub hub;
  late HubClient client;
  late String space;
  late List<FakeServer> servers;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('ms_app_session');
    hub = await Hub.start(
      HubConfig(
        dataDir: '${tmp.path}/data',
        address: InternetAddress.loopbackIPv4,
        port: 0,
        devUser: 'alice',
        admins: const ['alice'],
        keepAlive: const Duration(milliseconds: 200),
      ),
      log: (_) {},
    );
    client = HubClient(Uri.parse('http://127.0.0.1:${hub.port}/'));
    space = (await client.createSpace('Survival', Profile.minecraft)).id;
    servers = [];
  });

  tearDown(() async {
    client.close(force: true);
    await hub.close();
    tmp.deleteSync(recursive: true);
  });

  String dir(String name) => '${tmp.path}/$name';

  void put(String folder, String rel, String content) => File('$folder/$rel')
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  SessionEnv env({
    List<JavaRuntime> javas = const [JavaRuntime(path: '/x/java', major: 21, version: '21.0.5')],
  }) => SessionEnv(
    config: _config,
    start: (cmd) async {
      final s = FakeServer(cmd.workDir)..boot();
      servers.add(s);
      return s;
    },
    findJava: (_) async => javas,
    addresses: () async => ['192.0.2.10'],
  );

  SessionController controller(String folder, {SessionEnv? e}) {
    final c = SessionController(
      client: client,
      space: space,
      name: 'Survival',
      folder: folder,
      env: e ?? env(),
      me: 'alice',
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<void> pushFrom(String folder, {String message = ''}) async {
    final lock = await client.acquireLock(space, const LockInfo(client: 'test'));
    try {
      await SyncEngine(client, space, folder).push(lock: lock, message: message);
    } finally {
      await client.releaseLock(space, lock.token);
    }
  }

  test('forza e gioca: il lock dell\'altro si libera senza una partita finta', () async {
    final f = dir('pc');
    put(f, 'server.jar', 'jar');
    put(f, 'world/level.dat', 'world 0');
    put(f, 'eula.txt', 'eula=true');
    // un'altra sessione tiene il server
    await client.acquireLock(space, const LockInfo(client: 'test', action: 'play'));
    final before = (await client.events()).length;
    final c = controller(f);
    unawaited(c.start(force: true));
    await until(() => c.phase == SessionPhase.running);
    final evs = (await client.events()).skip(before).toList();
    // poi il primo caricamento della cartella nuova
    expect([for (final e in evs.where((e) => e.type != EventType.port)) e.type].take(2), [
      EventType.force,
      EventType.lock,
    ]);
    expect(evs.first.data['from'], 'alice');
    expect(evs.first.data['released'], true);
    expect(evs.where((e) => e.type == EventType.unlock), isEmpty, reason: 'nessuna partita di 0 s');
    await c.send('stop');
    await c.done;
  });

  test('sessione completa: EULA chiesta, avvio, giocatori, salva ora, arresto pulito', () async {
    final f = dir('pc');
    put(f, 'server.jar', 'jar');
    put(f, 'world/level.dat', 'world 0');
    final c = controller(f);
    final signals = <SessionSignal>[];
    c.signals.listen(signals.add);
    unawaited(c.start());
    await until(() => c.prompt == SessionPrompt.eula);
    expect(isEulaAccepted(f), isFalse);
    c.answerPrompt(true);
    await until(() => c.phase == SessionPhase.running);
    expect(isEulaAccepted(f), isTrue);
    expect(c.launchInfo!.javaVersion, '21.0.5');
    expect(c.launchInfo!.port, 25565);
    expect(c.addresses, ['192.0.2.10']);
    expect(c.console.where((l) => l.note == ConsoleNote.ready), hasLength(1));

    servers.single.join('bob');
    await until(() => c.players.containsKey('bob'));
    servers.single.play();
    expect(c.saveNow(), SaveRequest.started);
    await until(() => c.lastSaved != null);
    expect(signals.whereType<SignalSaved>(), isNotEmpty);

    await c.send('say ciao');
    expect(servers.single.commands, contains('say ciao'));
    expect(c.commandHistory, ['say ciao']);
    expect(c.console.last.kind, anyOf(ConsoleKind.cmd, ConsoleKind.info));

    // "stop" dalla console = arresto pulito
    await c.send('stop');
    await c.done;
    expect(c.phase, SessionPhase.ended);
    expect(c.active, isFalse);
    final sp = (await client.space(space)).summary;
    expect(sp.lock, isNull);
    expect(sp.headN, greaterThanOrEqualTo(2));
    expect(signals.whereType<SignalEnded>().single.ok, isTrue);
  });

  test('EULA rifiutata: niente server, il lock torna libero', () async {
    final f = dir('pc');
    put(f, 'server.jar', 'jar');
    final c = controller(f);
    unawaited(c.start());
    await until(() => c.prompt != null);
    c.answerPrompt(false);
    await c.done;
    expect(c.phase, SessionPhase.failed);
    expect(c.error, isA<EulaDeclined>());
    expect(servers, isEmpty);
    expect((await client.space(space)).summary.lock, isNull);
  });

  test('Java mancante: errore chiaro, nessun server avviato', () async {
    final f = dir('pc');
    put(f, 'server.jar', 'jar');
    put(f, 'eula.txt', 'eula=true\n');
    final c = controller(f, e: env(javas: const []));
    await c.start();
    expect(c.phase, SessionPhase.failed);
    expect(c.error, isA<JavaMissing>());
    expect(servers, isEmpty);
  });

  group('conflitto con le modifiche locali', () {
    late String mine;
    late String other;

    setUp(() async {
      mine = dir('mine');
      other = dir('other');
      put(mine, 'server.jar', 'jar');
      put(mine, 'eula.txt', 'eula=true\n');
      put(mine, 'world/level.dat', 'v1');
      await pushFrom(mine); // #1
      await SyncEngine(client, space, other).pull();
      put(other, 'world/level.dat', 'v2 di bob');
      await pushFrom(other); // #2
      put(mine, 'world/level.dat', 'v1 + mie modifiche');
    });

    test('si ferma prima del gioco e chiede; Annulla non cambia niente', () async {
      final c = controller(mine);
      await c.start();
      expect(c.phase, SessionPhase.conflict);
      expect(c.conflict!.changed, contains('world/level.dat'));
      expect(c.conflict!.base, 1);
      expect(c.conflict!.head, 2);
      await c.resolveConflict(ConflictChoice.cancel);
      await c.done;
      expect(c.phase, SessionPhase.cancelled);
      expect(File('$mine/world/level.dat').readAsStringSync(), 'v1 + mie modifiche');
      expect((await client.space(space)).summary.headN, 2);
      expect(servers, isEmpty);
    });

    test('versione dell\'hub: copia di sicurezza dei miei file, poi si gioca', () async {
      final c = controller(mine);
      await c.start();
      expect(c.phase, SessionPhase.conflict);
      unawaited(c.resolveConflict(ConflictChoice.useHub));
      await until(() => c.phase == SessionPhase.running);
      expect(File('$mine/world/level.dat').readAsStringSync(), 'v2 di bob');
      final backups = Directory('$mine/.minesync/backup').listSync(recursive: true);
      final saved = backups.whereType<File>().where((f) => f.path.endsWith('level.dat'));
      expect(saved.single.readAsStringSync(), 'v1 + mie modifiche');
      expect(await c.stopAndWait(), isTrue);
      expect(c.phase, SessionPhase.ended);
    });

    test('le mie come nuova versione: #3 per tutti, la #2 resta nella storia', () async {
      final c = controller(mine);
      await c.start();
      unawaited(c.resolveConflict(ConflictChoice.keepMine));
      await until(() => c.phase == SessionPhase.running);
      expect(File('$mine/world/level.dat').readAsStringSync(), 'v1 + mie modifiche');
      final gens = await client.generations(space);
      expect(gens.map((g) => g.n), containsAll([1, 2, 3]));
      final head = await client.generation(space, n: 3);
      expect(head.manifest['world/level.dat'], isNotNull);
      expect(await c.stopAndWait(), isTrue);
      expect(c.notices.map((n) => n.code), contains('keptMine'));
    });
  });

  test('AppState.play: sessione esposta, rotta della sessione, chiusura dopo la fine', () async {
    final f = dir('pc');
    put(f, 'server.jar', 'jar');
    put(f, 'eula.txt', 'eula=true\n');
    final app = AppState(
      AppDeps(
        configDir: dir('config'),
        platform: PlatformServices.inert(),
        pollEvery: const Duration(seconds: 5),
        session: env(),
      ),
    );
    addTearDown(app.dispose);
    await app.connectTo('127.0.0.1:${hub.port}');
    await app.link(space, f);
    await app.setPref('notify.everySave', true);
    final s = await app.play(space);
    expect(app.session, same(s));
    expect(app.route, ServerRoute(space));
    await until(() => s.phase == SessionPhase.running);
    expect(app.hosting, isTrue);
    await expectLater(app.play(space), throwsStateError);
    servers.single.play();
    s.saveNow();
    await until(() => s.lastSaved != null);
    final notes = app.deps.platform.notifications as InertNotifications;
    await until(() => notes.shown.isNotEmpty);
    expect(notes.shown.first.$1, 'Survival');
    expect(await s.stopAndWait(), isTrue);
    expect(app.hosting, isFalse);
    app.closeSession();
    expect(app.session, isNull);
  });

  test('righe della console: livelli e ingressi', () {
    final t = DateTime(2026);
    ConsoleEntry c(String s, {bool err = false}) => classifyLine(ServerLine(s, at: t, stderr: err));
    expect(c('[18:00:00] [Server thread/WARN]: Can\'t keep up!').kind, ConsoleKind.warn);
    expect(c('[18:00:00] [Server thread/ERROR]: boom').level, 'ERR');
    expect(c('[18:00:00] [Server thread/INFO]: bob joined the game').kind, ConsoleKind.join);
    expect(c('[18:00:00] [Server thread/INFO]: <bob> bob joined the game').kind, ConsoleKind.info);
    expect(c('[18:00:00] [Server thread/INFO] [minecraft/X]: Done').text, 'Done');
    expect(c('qualcosa', err: true).kind, ConsoleKind.err);
  });

  group('impostazioni delle sessioni dall\'hub', () {
    /// Regola propria del server (Admin › server › Sessioni).
    Future<void> override(Map<String, Object?> sessions) async {
      final h = HttpClient();
      try {
        final req = await h.openUrl(
          'PATCH',
          Uri.parse('http://127.0.0.1:${hub.port}/api/v1/spaces/$space'),
        );
        req.headers
          ..set(csrfHeader, '1')
          ..contentType = ContentType.json;
        req.write(
          jsonEncode({
            'overrides': {'sessions': sessions},
          }),
        );
        final res = await req.close();
        await res.drain<void>();
        expect(res.statusCode, 200);
      } finally {
        h.close();
      }
    }

    Future<SessionController> running({ServerPrefs prefs = const ServerPrefs()}) async {
      final f = dir('pc');
      put(f, 'server.jar', 'jar');
      put(f, 'eula.txt', 'eula=true');
      put(f, 'world/level.dat', 'world 0');
      final c = SessionController(
        client: client,
        space: space,
        name: 'Survival',
        folder: f,
        env: env(),
        prefs: prefs,
        me: 'alice',
      );
      addTearDown(c.dispose);
      unawaited(c.start());
      await until(() => c.phase == SessionPhase.running);
      return c;
    }

    test('salvataggio, spegnimento e riavvii come li vuole l\'hub per il server', () async {
      await override({
        'autosaveMinutes': 7,
        'autostop': false,
        'autostopMinutes': 3,
        'crashRestarts': 4,
      });
      final c = await running();
      expect(c.config.autosaveEvery, const Duration(minutes: 7));
      expect(c.config.emptyStopAfter, const Duration(minutes: 3));
      expect(c.config.maxRestarts, 4);
      // i tempi interni restano quelli dell'app
      expect(c.config.flushWait, _config.flushWait);
      expect(c.autostop, isFalse);
      final next = c.nextSaveAt!;
      expect(next.difference(DateTime.now()).inMinutes, greaterThanOrEqualTo(6));
      // l'interruttore della sessione vale solo per questa sessione
      c.autostop = true;
      expect(c.autostop, isTrue);
      await c.stopAndWait();
    });

    test('la preferenza del server su questo PC vince sull\'hub', () async {
      await override({'autostop': false});
      final c = await running(prefs: const ServerPrefs(autostop: true));
      expect(c.autostop, isTrue);
      expect(c.config.autostop, isFalse);
      await c.stopAndWait();
    });
  });

  test('limite di banda dalle preferenze', () {
    expect(UploadLimit.fromPrefs(const {}).bytesPerSecond(null), 0);
    expect(UploadLimit.fromPrefs(const {}).bytesPerSecond(1000), 700);
    final p = {
      'uploadLimit': const UploadLimit(mode: UploadLimitMode.percent, percent: 50).toJson(),
    };
    expect(UploadLimit.fromPrefs(p).bytesPerSecond(1000), 500);
    expect(
      UploadLimit.fromPrefs({
        'uploadLimit': {'mode': 'fixed', 'kib': 64},
      }).bytesPerSecond(null),
      64 * 1024,
    );
    expect(
      UploadLimit.fromPrefs({
        'uploadLimit': {'mode': 'none'},
      }).bytesPerSecond(1000),
      0,
    );
  });
}
