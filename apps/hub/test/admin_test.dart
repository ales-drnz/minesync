// Area Admin: pulizia e anteprima, uso del disco, prova delle
// esclusioni, membri e ZTNET, sistema, eventi, DNS e punti di estensione.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:minesync_hub/minesync_hub.dart';
import 'package:ms_core/ms_core.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  String hashOf(List<int> b) => sha256Hex(Uint8List.fromList(b));

  group('pulizia', () {
    late TestHub t;
    late String a, b;
    setUp(() async {
      t = await TestHub.start();
      a = await t.createSpace('Avventura');
      b = await t.createSpace('Creativo');
    });
    tearDown(() => t.close());

    Future<List<int>> history(String s) async {
      final r = await t.get('/spaces/$s/generations?limit=500');
      return [for (final g in r.obj['generations']! as List) (g as Map)['n'] as int];
    }

    test('anteprima keep: niente cancellato; poi POST /gc keep con evento e chi', () async {
      final bs = [for (var i = 0; i < 5; i++) bytes('blob $i')];
      for (final x in bs) {
        await t.push(a, {'f': x});
      }
      await t.push(b, {'f': bytes('altro')});
      final p = GcPreview.fromJson(
        (await t.req('POST', '/gc/preview', as: 'carol', body: {'keep': 2})).json,
      );
      expect(p.keep, 2);
      final row = p.spaces.firstWhere((r) => r.id == a);
      expect((row.now, row.after), (5, 2));
      expect(row.bytes, bs[0].length + bs[1].length + bs[2].length);
      expect(p.spaces.firstWhere((r) => r.id == b).after, 1);
      expect(p.bytes, row.bytes);
      expect(await history(a), [5, 4, 3, 2, 1], reason: 'l\'anteprima non cancella');
      final r = GcReport.fromJson(
        (await t.req('POST', '/gc', as: 'carol', body: {'keep': 2})).json,
      );
      expect(r.generations, 3);
      expect(r.blobs, 3);
      expect(await history(a), [5, 4]);
      final e = t.hub.events.after(0).lastWhere((e) => e.type == EventType.gc);
      expect(e.actor, 'carol');
      expect(e.data['keep'], 2);
      expect(e.data['generations'], 3);
    });

    test('B-GC-08 keep non numerico, zero, negativo o troppo grande: 400', () async {
      for (final k in [0, -1, 'x', 10001, 1.5]) {
        final r = await t.req('POST', '/gc', as: 'carol', body: {'keep': k});
        expect(r.status, 400, reason: '$k');
        expect(r.details['field'], 'keep');
      }
      expect((await t.req('POST', '/gc', as: 'carol')).status, 200, reason: 'senza keep');
      expect((await t.req('POST', '/gc', body: {'keep': 1})).status, 403);
    });

    test('anteprima con regole in bozza: chi ha regole proprie le tiene (ownRules)', () async {
      for (var i = 0; i < 4; i++) {
        await t.push(a, {'f': bytes('a$i')});
        await t.push(b, {'f': bytes('b$i')});
      }
      await t.req(
        'PATCH',
        '/spaces/$b',
        as: 'carol',
        body: {
          'overrides': {
            'history': {'keepLast': 3},
          },
        },
      );
      final draft = {'keepLast': 1, 'keepHours': 0, 'keepDays': 0};
      final p = GcPreview.fromJson(
        (await t.req('POST', '/gc/preview', as: 'carol', body: {'history': draft})).json,
      );
      final ra = p.spaces.firstWhere((r) => r.id == a);
      final rb = p.spaces.firstWhere((r) => r.id == b);
      expect((ra.after, ra.ownRules), (1, false));
      expect(rb.ownRules, isTrue);
      expect(rb.after, 4, reason: 'keepLast 3 ma le 24 h di default tengono tutto');
      // anteprima di uno spazio: la bozza vale per lui
      final ps = GcPreview.fromJson(
        (await t.req('POST', '/spaces/$b/gc/preview', as: 'carol', body: {'history': draft})).json,
      );
      expect(ps.spaces.single.after, 1);
      final bad = await t.req(
        'POST',
        '/gc/preview',
        as: 'carol',
        body: {
          'history': {'keepLast': 0},
        },
      );
      expect(bad.details['field'], 'history.keepLast');
    });

    test('pulizia di uno spazio: gli altri restano; la testa resta sempre', () async {
      for (var i = 0; i < 3; i++) {
        await t.push(a, {'f': bytes('a$i')});
        await t.push(b, {'f': bytes('b$i')});
      }
      final r = await t.req('POST', '/spaces/$a/gc', as: 'carol', body: {'keep': 1});
      expect(GcReport.fromJson(r.json).generations, 2);
      expect(await history(a), [3]);
      expect(await history(b), [3, 2, 1]);
      expect(t.hub.events.after(0).lastWhere((e) => e.type == EventType.gc).space, a);
    });

    test('uso del disco: logico, referenziato, esclusivo, blob', () async {
      final shared = noise(1000, 1), onlyA = noise(500, 2);
      await t.push(a, {'s': shared, 'x': onlyA});
      await t.push(a, {'s': shared});
      await t.push(b, {'s': shared});
      final u = HubUsage.fromJson((await t.get('/usage')).json);
      final ua = u.spaces[a]!;
      expect(ua.generations, 2);
      expect(ua.oldest, 1);
      expect(ua.logical, 1500 + 1000);
      expect(ua.referenced, 1500);
      expect(ua.exclusive, 500);
      expect(u.spaces[b]!.exclusive, 0);
      expect(u.blobs, 1500);
      expect(u.dl, 0);
      expect(u.computedAt, greaterThan(0));
      expect(SpaceDetails.fromJson((await t.get('/spaces/$a')).json).usage?.referenced, 1500);
      t.hub.extras.dlBytes = () async => 42;
      await t.req('POST', '/gc', as: 'carol');
      await eventually(() => t.hub.events.after(0).isNotEmpty);
      expect(HubUsage.fromJson((await t.get('/usage')).json).dl, anyOf(0, 42));
    });
  });

  group('prova delle esclusioni', () {
    late TestHub t;
    late String s;
    setUp(() async {
      t = await TestHub.start();
      s = await t.createSpace('Survival');
      await t.req(
        'PATCH',
        '/spaces/$s',
        as: 'carol',
        body: {
          'exclusions': ['bluemap/**'],
        },
      );
    });
    tearDown(() => t.close());

    Future<ExclusionTest> probe(Map<String, Object?> b) async => ExclusionTest.fromJson(
      (await t.req('POST', '/exclusions/test', as: 'carol', body: b)).json,
    );

    test('sorgente: sistema, profilo, spazio, bozza; cartelle con la barra finale', () async {
      var r = await probe({'path': 'logs/', 'spaceId': s});
      expect((r.excluded, r.pattern, r.source), (true, 'logs/**', ExclusionSource.profile));
      r = await probe({'path': 'bluemap/web/x.png', 'spaceId': s});
      expect((r.pattern, r.source), ('bluemap/**', ExclusionSource.space));
      r = await probe({'path': '.minesync/base.json', 'profile': 'generic'});
      expect(r.source, ExclusionSource.system);
      r = await probe({
        'path': 'world/level.dat',
        'patterns': ['world/*.dat'],
      });
      expect((r.excluded, r.source), (true, ExclusionSource.draft));
      r = await probe({'path': 'world/level.dat', 'spaceId': s});
      expect(r.excluded, isFalse);
      expect(r.pattern, isNull);
      expect((await t.req('POST', '/exclusions/test', body: {'path': 'x'})).status, 403);
      final long = await t.req('POST', '/exclusions/test', as: 'carol', body: {'path': 'x' * 1025});
      expect(long.status, 400);
    });
  });

  group('membri e ZTNET', () {
    late TestHub t;
    late List<Map<String, Object?>> roster;
    late bool fail;
    ZtnetResolver? z;

    setUp(() async {
      fail = false;
      roster = [
        {
          'id': alice.id,
          'name': 'alice',
          'authorized': true,
          'ipAssignments': ['192.0.2.1'],
        },
        {
          'id': carol.id,
          'name': 'carol',
          'authorized': true,
          'ipAssignments': ['192.0.2.3'],
        },
        {'id': 'd4d4d4d4d4', 'name': 'dave', 'authorized': true},
        {'id': 'e5e5e5e5e5', 'name': 'mallory', 'authorized': false},
      ];
      t = await TestHub.start(
        resolver: (base) => ChainResolver([
          base,
          z = ZtnetResolver.roster(() async {
            if (fail) throw const SocketException('irraggiungibile');
            return parseZtnetRoster(jsonDecode(jsonEncode(roster)));
          }, clock: FakeClock()),
        ]),
      );
    });
    tearDown(() => t.close());

    Future<MemberList> list() async =>
        MemberList.fromJson((await t.get('/members', as: 'carol')).json);

    test('elenco unito: visti e ZTNET, non autorizzati, admin per primi', () async {
      await t.get('/hub', as: 'bob');
      var l = await list();
      expect(l.ztnet.state, ZtnetState.ok);
      expect(l.ztnet.lastRefresh, isNull, reason: 'ZTNET non ancora letto');
      final st = ZtnetStatus.fromJson((await t.req('POST', '/members/refresh', as: 'carol')).json);
      expect(st.members, 3);
      expect(st.lastRefresh, isNotNull);
      l = await list();
      expect(l.members.first.name, 'carol');
      expect(l.members.first.role, MemberRole.admin);
      expect(l.members.first.fromConfig, isTrue);
      final by = {for (final m in l.members) m.name: m};
      expect(by['mallory']!.authorized, isFalse);
      expect(by['dave']!.lastSeen, isNull);
      expect(by['bob']!.authorized, isFalse, reason: 'visto ma non in ZTNET');
      expect(by['alice']!.ip, '192.0.2.1');
      expect((await t.get('/members')).status, 403);
    });

    test('ruoli: promozione, from_config, evento member.role, 404', () async {
      await t.get('/hub', as: 'alice');
      var r = await t.req('PUT', '/members/${alice.id}/role', as: 'carol', body: {'role': 'admin'});
      expect(MemberInfo.fromJson(r.json).role, MemberRole.admin);
      expect((await t.get('/members', as: 'alice')).status, 200, reason: 'vale subito');
      final e = t.hub.events.after(0).lastWhere((e) => e.type == EventType.memberRole);
      expect(e.data, {'memberId': alice.id, 'member': 'alice', 'role': 'admin'});
      expect(e.actor, 'carol');
      r = await t.req('PUT', '/members/${carol.id}/role', as: 'alice', body: {'role': 'member'});
      expect(r.code, 'from_config');
      r = await t.req('PUT', '/members/${alice.id}/role', as: 'carol', body: {'role': 'member'});
      expect(r.status, 200);
      expect((await t.get('/members', as: 'alice')).status, 403);
      expect(
        (await t.req('PUT', '/members/nope/role', as: 'carol', body: {'role': 'admin'})).status,
        404,
      );
      expect(
        (await t.req('PUT', '/members/${alice.id}/role', as: 'carol', body: {'role': 'x'})).code,
        'bad_request',
      );
      await t.restart();
      expect((await t.get('/members', as: 'alice')).status, 403, reason: 'salvato');
    });

    test('last_admin: non si declassa l\'ultimo admin', () async {
      await t.close();
      t = await TestHub.start(admins: const []);
      await t.get('/hub', as: 'alice');
      await t.hub.members.setRole(alice.id, 'alice', Role.admin);
      final r = await t.req(
        'PUT',
        '/members/${alice.id}/role',
        as: 'alice',
        body: {'role': 'member'},
      );
      expect(r.code, 'last_admin');
      final st = MemberList.fromJson((await t.get('/members', as: 'alice')).json).ztnet;
      expect(st.state, ZtnetState.off);
    });

    test('stato ZTNET: errore e ripresa pubblicano ztnet, l\'ultimo errore resta', () async {
      await t.req('POST', '/members/refresh', as: 'carol');
      fail = true;
      var st = ZtnetStatus.fromJson((await t.req('POST', '/members/refresh', as: 'carol')).json);
      expect(st.state, ZtnetState.error);
      expect(st.lastError, contains('irraggiungibile'));
      fail = false;
      st = ZtnetStatus.fromJson((await t.req('POST', '/members/refresh', as: 'carol')).json);
      expect(st.state, ZtnetState.ok);
      expect(st.lastError, isNotNull);
      final evs = t.hub.events.after(0).where((e) => e.type == EventType.ztnet).toList();
      expect([for (final e in evs) e.data['state']], ['error', 'ok']);
    });

    test('Admin › Membri si applica subito al resolver', () async {
      await t.req(
        'PATCH',
        '/settings/members',
        as: 'carol',
        body: {'trustHours': 0, 'refreshSeconds': 120},
      );
      expect(z!.ttl, const Duration(seconds: 120));
      expect(z!.grace, Duration.zero);
    });
  });

  group('sistema, eventi, DNS, estensioni', () {
    late TestHub t;
    late String s;
    setUp(() async {
      t = await TestHub.start();
      s = await t.createSpace('Survival');
    });
    tearDown(() => t.close());

    test('GET /system: versione, disco, http, DNS, update da /dl', () async {
      var si = SystemInfo.fromJson((await t.get('/system', as: 'carol')).json);
      expect(si.version, hubVersion);
      expect(si.dataDir, t.data);
      expect(si.http, ':0');
      expect(si.dns.on, isFalse);
      expect(si.admins, ['carol']);
      expect(si.updates, isEmpty);
      expect(si.time - si.startedAt, 0);
      t.hub.dns
        ..zone = 'mc.example'
        ..addr = ':53'
        ..error = 'address in use';
      t.hub.extras.updates = () async => const [
        UpdateChannel(platform: 'linux-x64', version: '0.1.0', signed: true),
      ];
      si = SystemInfo.fromJson((await t.get('/system', as: 'carol')).json);
      expect(si.dns.error, 'address in use');
      expect(si.updates.single.signed, isTrue);
      expect((await t.get('/system')).status, 403);
    });

    test('B-DNS-01 dnsZone e dnsName solo con il server DNS in ascolto', () async {
      t.hub.dns.zone = 'mc.example';
      expect(HubInfo.fromJson((await t.get('/hub')).json).dnsZone, isNull);
      t.hub.dns.running = true;
      expect(HubInfo.fromJson((await t.get('/hub')).json).dnsZone, 'mc.example');
      final l = (await t.get('/spaces')).obj['spaces']! as List;
      expect(SpaceSummary.fromJson(l.single).dnsName, 'zerotier.$s.mc.example');
    });

    test('eventi più vecchi, dal più recente, con filtri per spazio e tipo', () async {
      final o = await t.createSpace('Creativo');
      for (var i = 0; i < 5; i++) {
        await t.push(s, {'f': bytes('$i')});
      }
      await t.push(o, {'f': bytes('x')});
      final last = t.hub.events.lastSeq;
      var r = await t.get('/events?before=${last + 1}&limit=3');
      final seqs = [for (final e in r.obj['events']! as List) (e as Map)['seq'] as int];
      expect(seqs, [last, last - 1, last - 2]);
      expect(r.obj['more'], isTrue);
      r = await t.get('/events?before=${last + 1}&space=$s&types=push');
      final evs = [for (final e in r.obj['events']! as List) HubEvent.fromJson(e)];
      expect(evs, hasLength(5));
      expect(evs.every((e) => e.type == 'push' && e.space == s), isTrue);
      expect(evs.first.data['n'], 5);
      expect(r.obj['more'], isFalse);
      r = await t.get('/events?after=0&types=space.create,lock');
      expect(
        {for (final e in r.obj['events']! as List) (e as Map)['type']},
        {'space.create', 'lock'},
      );
      expect(r.obj['oldest'], 1);
    });

    test('il registro su disco: before legge i file oltre la memoria', () async {
      final dir = await Directory.systemTemp.createTemp('minesync-events-');
      addTearDown(() => dir.delete(recursive: true));
      final log = EventLog(dir.path, clock: FakeClock(), memory: 5, segmentEvents: 4);
      await log.open();
      for (var i = 1; i <= 23; i++) {
        log.publish(i.isEven ? 'push' : 'lock', space: 'w', data: {'i': i});
      }
      var r = await log.before(24, limit: 10);
      expect([for (final e in r.events) e.seq], [for (var i = 23; i > 13; i--) i]);
      expect(r.more, isTrue);
      r = await log.before(12, limit: 100, types: {'push'});
      expect([for (final e in r.events) e.seq], [10, 8, 6, 4, 2]);
      expect(r.more, isFalse);
      expect(log.oldestSeq, 1);
      await log.close();
      // dopo un riavvio, dal disco
      final again = EventLog(dir.path, clock: FakeClock(), memory: 5, segmentEvents: 4);
      await again.open();
      expect((await again.before(4)).events.map((e) => e.seq), [3, 2, 1]);
      await again.close();
    });

    test('unlock e force con durationMs; stale una volta per silenzio', () async {
      Future<String> play(String who) async {
        final r = await t.req(
          'POST',
          '/spaces/$s/lock',
          as: who,
          body: {
            'info': {'client': 'test', 'action': 'play'},
            'force': who == 'carol',
          },
        );
        return r.obj['token']! as String;
      }

      final changes = <LockChangeKind>[];
      t.store.lockListeners.add((c) => changes.add(c.kind));
      var tok = await play('alice');
      t.clock.advance(const Duration(seconds: 10));
      await t.req('DELETE', '/spaces/$s/lock', body: {'token': tok});
      var e = t.hub.events.after(0).lastWhere((e) => e.type == EventType.unlock);
      expect(e.data['durationMs'], 10000);
      tok = await play('alice');
      t.clock.advance(const Duration(seconds: 91));
      t.store.checkStaleLocks();
      t.store.checkStaleLocks();
      final stale = t.hub.events.after(0).where((e) => e.type == EventType.stale).toList();
      expect(stale, hasLength(1));
      expect(stale.single.data['holder'], 'alice');
      await t.req('POST', '/spaces/$s/lock/heartbeat', body: {'token': tok});
      t.clock.advance(const Duration(seconds: 5));
      await play('carol');
      e = t.hub.events.after(0).lastWhere((e) => e.type == EventType.force);
      expect(e.data['from'], 'alice');
      expect(e.data['durationMs'], 96000);
      expect(changes, [
        LockChangeKind.acquired,
        LockChangeKind.released,
        LockChangeKind.acquired,
        LockChangeKind.stale,
        LockChangeKind.renewed,
        LockChangeKind.forced,
        LockChangeKind.acquired,
      ]);
    });

    test('disk: warn sotto il doppio della soglia (al più ogni 6 h), full al rifiuto', () async {
      t.disk.free = 6 << 30; // soglia 4 GiB
      await t.lock(s);
      await t.req('POST', '/spaces/$s/lock', as: 'bob', body: {});
      var d = t.hub.events.after(0).where((e) => e.type == EventType.disk).toList();
      expect([for (final e in d) e.data['level']], ['warn']);
      t.disk.free = 1;
      await t.req('POST', '/spaces/$s/lock', as: 'bob', body: {});
      d = t.hub.events.after(0).where((e) => e.type == EventType.disk).toList();
      expect([for (final e in d) e.data['level']], ['warn', 'full']);
    });

    test('estensioni: endpoint in /api/v1, percorsi fuori, decoratori', () async {
      t.hub.apiRoutes.add((req, who, admin, segs) async {
        if (segs case ['spaces', final id, 'hello']) {
          await t.hub.sendJson(req, {'id': id, 'who': who.name, 'admin': admin});
          return true;
        }
        return false;
      });
      t.hub.rawRoutes.add((req) async {
        if (req.uri.path != '/extra/x') return false;
        final who = await t.hub.identify(req);
        req.response.write('ciao ${who?.name}');
        await req.response.close();
        return true;
      });
      t.store.summaryDecorators.add(
        (x) => SpaceSummary(
          id: x.id,
          name: x.name,
          profile: x.profile,
          createdAt: x.createdAt,
          head: x.head,
          lock: x.lock,
          world: const WorldChip(mcVersion: '1.21.1', mods: 3),
        ),
      );
      t.store.lockDecorator = (id, h) => LockHolder(
        memberId: h.memberId,
        name: h.name,
        since: h.since,
        lastBeat: h.lastBeat,
        stale: h.stale,
        info: h.info,
        ip: h.ip,
        portCheck: const PortCheck(state: PortState.pending),
      );
      expect((await t.get('/spaces/$s/hello')).obj, {'id': s, 'who': 'alice', 'admin': false});
      expect((await t.get('/spaces/$s/nope')).status, 404);
      final c = t.client('bob');
      final res = await (await c.getUrl(
        Uri.parse('http://127.0.0.1:${t.hub.port}/extra/x'),
      )).close();
      expect(await utf8.decoder.bind(res).join(), 'ciao bob');
      final other = await (await c.getUrl(Uri.parse('http://127.0.0.1:${t.hub.port}/zz'))).close();
      expect(other.statusCode, 404);
      await other.drain<void>();
      final r = await t.req(
        'POST',
        '/spaces/$s/lock',
        body: {
          'info': {'client': 't'},
        },
      );
      expect(LockHolder.fromJson(r.obj['lock']).portCheck?.state, PortState.pending);
      final d = SpaceDetails.fromJson((await t.get('/spaces/$s')).json);
      expect(d.summary.world?.mods, 3);
      expect(d.summary.lock?.portCheck, isNotNull);
      expect(hashOf(const []), isNotEmpty);
    });
  });
}
