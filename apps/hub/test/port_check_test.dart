// Prova della porta di chi ospita (protocol.md, "Lock, port test and DNS").
// Connettore e orologio finti: nessuna attesa vera, tranne il test sul
// loopback con un ServerSocket.
import 'dart:async';
import 'dart:io';

import 'package:minesync_hub/minesync_hub.dart';
import 'package:minesync_hub/src/state.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:test/test.dart';

import 'support.dart';

const ttl = Duration(seconds: 90);

final class Rig {
  Rig() {
    checker = PortChecker(
      clock: clock,
      locks: () => [for (final e in locks.entries) (e.key, e.value)],
      lockTtl: ttl,
      enabled: (id) => enabled,
      connect: (host, port, timeout) {
        calls.add('$host:$port');
        expect(timeout, const Duration(seconds: 3));
        return answer(host, port);
      },
      publish: (id, data) => events.add('$id ${data['state']} ${data['port']}'),
    );
  }

  final clock = FakeClock(DateTime.utc(2026, 11, 1, 12));
  final locks = <String, LockState>{};
  final calls = <String>[];
  final events = <String>[];
  bool enabled = true;
  Future<bool> Function(String host, int port) answer = (_, _) async => false;
  late final PortChecker checker;

  LockState lock(String id, {String action = 'play', int? port, String? ip = '192.0.2.10'}) =>
      locks[id] = LockState(
        token: 't$id',
        memberId: 'a1a1a1a1a1',
        name: 'alice',
        since: clock.wallMs(),
        lastBeat: clock.wallMs(),
        lastBeatMono: clock.monoMs(),
        info: LockInfo(client: 'test', action: action, port: port),
        ip: ip,
      );

  /// Avanza di [d] a passi di 1 s (come il timer vero), un giro per passo,
  /// tenendo vivo il lock.
  Future<void> run(Duration d) async {
    for (var i = 0; i < d.inSeconds; i++) {
      clock.advance(const Duration(seconds: 1));
      for (final l in locks.values) {
        l.beat(clock);
      }
      await checker.tick();
    }
  }

  PortState? state(String id) => locks[id]?.portCheck?.state;
}

void main() {
  late Rig r;
  setUp(() => r = Rig());

  group('macchina a stati', () {
    test('lock play: pending, una prova ogni 10 s, il primo successo dà reachable', () async {
      r.lock('s1');
      await r.checker.tick();
      expect(r.state('s1'), PortState.pending);
      expect(r.locks['s1']!.portCheck!.port, defaultGamePort);
      expect(r.locks['s1']!.portCheck!.checkedAt, isNull);
      expect(r.calls, ['192.0.2.10:25565']);
      await r.run(const Duration(seconds: 9));
      expect(r.calls, hasLength(1));
      await r.run(const Duration(seconds: 1));
      expect(r.calls, hasLength(2));
      r.answer = (_, _) async => true;
      await r.run(const Duration(seconds: 10));
      expect(r.state('s1'), PortState.reachable);
      expect(r.locks['s1']!.portCheck!.checkedAt, r.clock.wallMs());
      expect(r.events, ['s1 reachable 25565']);
      // niente altre prove una volta deciso
      final n = r.calls.length;
      await r.run(const Duration(minutes: 5));
      expect(r.calls, hasLength(n));
      expect(r.events, hasLength(1));
      // e il LockHolder la porta con sé
      expect(r.locks['s1']!.holder(r.clock, ttl).portCheck!.state, PortState.reachable);
    });

    test('mai raggiungibile: blocked dopo 3 minuti, un solo evento, 18 prove', () async {
      r.lock('s1', port: 25570);
      await r.checker.tick();
      await r.run(const Duration(minutes: 2, seconds: 59));
      expect(r.state('s1'), PortState.pending);
      await r.run(const Duration(seconds: 1));
      expect(r.state('s1'), PortState.blocked);
      expect(r.events, ['s1 blocked 25570']);
      expect(r.calls, everyElement('192.0.2.10:25570'));
      expect(r.calls, hasLength(18));
      await r.run(const Duration(minutes: 1));
      expect(r.calls, hasLength(18));
    });

    test('lock di solo push o prova spenta: off, nessuna connessione', () async {
      r.lock('p', action: 'push');
      r.lock('s1');
      r.enabled = false;
      await r.checker.tick();
      expect(r.state('p'), PortState.off);
      expect(r.state('s1'), PortState.off);
      expect(r.calls, isEmpty);
      // riaccesa: la finestra parte da adesso
      r.enabled = true;
      await r.run(const Duration(seconds: 1));
      expect(r.state('s1'), PortState.pending);
      expect(r.state('p'), PortState.off);
      expect(r.calls, ['192.0.2.10:25565']);
      expect(r.events, isEmpty);
    });

    test('cambio di porta o di indirizzo, lock nuovo: la finestra riparte', () async {
      r.lock('s1');
      await r.checker.tick();
      await r.run(const Duration(minutes: 3));
      expect(r.state('s1'), PortState.blocked);
      r.locks['s1']!.info = const LockInfo(action: 'play', port: 25599);
      await r.run(const Duration(seconds: 1));
      expect(r.state('s1'), PortState.pending);
      expect(r.calls.last, '192.0.2.10:25599');
      r.answer = (_, _) async => true;
      r.locks['s1']!.ip = '192.0.2.11';
      await r.run(const Duration(seconds: 1));
      expect(r.calls.last, '192.0.2.11:25599');
      expect(r.state('s1'), PortState.reachable);
      // un altro lock (rilascio e nuova presa)
      r.lock('s1');
      await r.run(const Duration(seconds: 1));
      expect(r.locks['s1']!.portCheck!.state, PortState.reachable);
      expect(r.events, ['s1 blocked 25565', 's1 reachable 25599', 's1 reachable 25565']);
    });

    test(
      'lock scaduto: nessuna prova finché non torna vivo; rilascio: stato dimenticato',
      () async {
        r.lock('s1');
        await r.checker.tick();
        r.clock.advance(const Duration(seconds: 91));
        await r.checker.tick();
        expect(r.calls, hasLength(1));
        r.locks['s1']!.beat(r.clock);
        await r.checker.tick();
        // di nuovo vivo: le prove riprendono
        expect(r.state('s1'), PortState.pending);
        expect(r.calls, hasLength(2));
        r.locks.remove('s1');
        await r.checker.tick();
        expect(r.checker.stateOf('s1'), isNull);
      },
    );

    test('esito di una prova arrivato dopo il cambio del lock: scartato', () async {
      final gate = Completer<bool>();
      r.answer = (_, _) => gate.future;
      r.lock('s1');
      final first = r.checker.tick();
      r.lock('s1'); // lock nuovo mentre la prova è in corso
      r.answer = (_, _) async => false;
      await r.checker.tick();
      gate.complete(true);
      await first;
      expect(r.state('s1'), PortState.pending);
      expect(r.events, isEmpty);
    });

    test('senza indirizzo del socket non si prova nulla e finisce blocked', () async {
      r.lock('s1', ip: null);
      await r.checker.tick();
      await r.run(const Duration(minutes: 3));
      expect(r.calls, isEmpty);
      expect(r.state('s1'), PortState.blocked);
    });
  });

  group('POST port-check', () {
    test('not_locked, feature_off, rate_limited e ripartenza', () async {
      Matcher code(ErrorCode c) => throwsA(isA<ApiError>().having((e) => e.code, 'code', c));
      expect(() => r.checker.restart('s1'), code(ErrorCode.notLocked));
      r.lock('s1', action: 'push');
      expect(() => r.checker.restart('s1'), code(ErrorCode.notLocked));
      r.lock('s1');
      r.clock.advance(const Duration(seconds: 91)); // scaduto
      expect(() => r.checker.restart('s1'), code(ErrorCode.notLocked));
      r.locks['s1']!.beat(r.clock);
      r.enabled = false;
      expect(() => r.checker.restart('s1'), code(ErrorCode.featureOff));
      r.enabled = true;
      await r.checker.tick(); // la presa del lock fa partire la finestra
      await r.run(const Duration(seconds: 4));
      try {
        r.checker.restart('s1');
        fail('rate_limited atteso');
      } on ApiError catch (e) {
        expect(e.code, ErrorCode.rateLimited);
        expect(e.details['retryMs'], 6000);
      }
      await r.run(const Duration(minutes: 3));
      expect(r.state('s1'), PortState.blocked);
      final calls = r.calls.length;
      final c = r.checker.restart('s1');
      expect(c.state, PortState.pending);
      expect(c.port, defaultGamePort);
      expect(r.state('s1'), PortState.pending);
      r.answer = (_, _) async => true;
      await r.checker.tick();
      expect(r.calls, hasLength(calls + 1));
      expect(r.state('s1'), PortState.reachable);
      expect(() => r.checker.restart('s1'), code(ErrorCode.rateLimited));
    });
  });

  group('hub', () {
    late TestHub t;
    late String space;
    final calls = <String>[];
    var open = false;

    setUp(() async {
      calls.clear();
      open = false;
      final d = await Directory.systemTemp.createTemp('minesync-hub-test-');
      t = await TestHub.start(dir: d);
      await t.hub.close();
      // stesso hub con un connettore finto
      t.hub = await Hub.start(
        HubConfig(
          dataDir: d.path,
          address: InternetAddress.loopbackIPv4,
          port: 0,
          admins: const ['carol'],
        ),
        resolver: t.resolver,
        clock: t.clock,
        disk: t.disk.probe,
        options: t.options,
        log: t.logs.add,
        portConnector: (host, port, _) async {
          calls.add('$host:$port');
          return open;
        },
      );
      space = await t.createSpace('Survival');
    });
    tearDown(() => t.close());

    test('il bersaglio è l\'IP del socket, mai info.address; stato e evento port', () async {
      final r = await t.req(
        'POST',
        '/spaces/$space/lock',
        body: {
          'info': {'client': 'test', 'action': 'play', 'port': 25570, 'address': '198.51.100.7'},
        },
      );
      expect(r.status, 200);
      open = true;
      await t.hub.portChecks.tick();
      expect(calls.toSet(), {'127.0.0.1:25570'});
      final d = await t.get('/spaces/$space');
      final lock = LockHolder.fromJson((d.obj['lock']! as Map<String, Object?>));
      expect(lock.portCheck!.state, PortState.reachable);
      expect(lock.portCheck!.port, 25570);
      final ev = await t.get('/events?after=0');
      final port = (ev.obj['events']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .where((e) => e['type'] == 'port')
          .toList();
      expect(port, hasLength(1));
      expect(port.single['data'], {'state': 'reachable', 'port': 25570});
      expect(port.single['space'], space);

      // il corpo della richiesta non sceglie il bersaglio
      final p = await t.req(
        'POST',
        '/spaces/$space/lock/port-check',
        body: {'ip': '198.51.100.9', 'port': 22},
      );
      expect(p.status, 429);
      expect(p.code, 'rate_limited');
      expect(p.details['retryMs'], isA<int>());
      t.clock.advance(const Duration(seconds: 11));
      final q = await t.req('POST', '/spaces/$space/lock/port-check', body: {'ip': '198.51.100.9'});
      expect(q.status, 200);
      expect(PortCheck.fromJson(q.json).state, PortState.pending);
      await t.hub.portChecks.tick();
      expect(calls.toSet(), {'127.0.0.1:25570'});
    });

    test('409 not_locked senza lock play vivo; X-MineSync richiesto', () async {
      final a = await t.req('POST', '/spaces/$space/lock/port-check');
      expect(a.status, 409);
      expect(a.code, 'not_locked');
      await t.lock(space); // lock senza action: non è play
      expect((await t.req('POST', '/spaces/$space/lock/port-check')).code, 'not_locked');
      final b = await t.req('POST', '/spaces/$space/lock/port-check', csrf: false);
      expect(b.status, 403);
    });
  });

  test('connessione TCP vera sul loopback: aperta sì, chiusa no', () async {
    final ss = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = ss.first;
    expect(await tcpConnect('127.0.0.1', ss.port, const Duration(seconds: 3)), isTrue);
    (await accepted).destroy();
    final port = ss.port;
    await ss.close();
    expect(await tcpConnect('127.0.0.1', port, const Duration(seconds: 3)), isFalse);
  });
}
