// Identità e guardie delle richieste (regole AUTH, G-05, G-06) e
// impostazioni dell'hub.
import 'dart:convert';
import 'dart:io';

import 'package:minesync_hub/minesync_hub.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Richiesta HTTP scritta a mano: serve a controllare Host al byte.
Future<(int, String)> rawRequest(int port, String request) async {
  final s = await Socket.connect(InternetAddress.loopbackIPv4, port);
  s.write(request);
  await s.flush();
  final out = await utf8.decoder.bind(s).join();
  s.destroy();
  final status = int.parse(out.split(' ')[1]);
  return (status, out);
}

void main() {
  group('ZTNET resolver', () {
    final a = InternetAddress('192.0.2.5');
    final b = InternetAddress('192.0.2.6');
    late FakeClock clock;
    late Map<String, Identity> upstream;
    late bool fail;
    late int calls;

    ZtnetResolver resolver({Duration grace = const Duration(hours: 24)}) => ZtnetResolver(
      () async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (fail) throw const SocketException('irraggiungibile');
        return Map.of(upstream);
      },
      clock: clock,
      grace: grace,
    );

    setUp(() {
      clock = FakeClock();
      upstream = {a.address: alice};
      fail = false;
      calls = 0;
    });

    test('B-AUTH-01 la prima richiesta aspetta l\'elenco; noti riconosciuti, ignoti no', () async {
      final r = resolver();
      expect(await r.resolve(a), alice);
      expect(await r.resolve(b), isNull);
      expect(calls, 1);
    });

    test(
      'B-AUTH-02 cache vecchia: risposta immediata e un solo aggiornamento in background',
      () async {
        final r = resolver();
        await r.resolve(a);
        clock.advance(const Duration(seconds: 31));
        upstream[b.address] = bob;
        final rs = await Future.wait([r.resolve(a), r.resolve(b), r.resolve(b)]);
        expect(rs, [alice, null, null], reason: 'si risponde dalla cache, senza aspettare');
        expect(calls, 2, reason: 'aggiornamenti concorrenti uniti in uno');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(await r.resolve(b), bob);
      },
    );

    test('B-AUTH-03 ZTNET giù: i membri noti restano per la grazia (24 h), poi negati', () async {
      final r = resolver();
      await r.resolve(a);
      fail = true;
      clock.advance(const Duration(hours: 5));
      expect(await r.resolve(a), alice);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(r.down, isTrue);
      expect(await r.resolve(a), alice, reason: 'un aggiornamento fallito non svuota la cache');
      expect(await r.resolve(b), isNull);
      clock.advance(const Duration(hours: 20));
      expect(await r.resolve(a), isNull, reason: 'oltre la grazia');
      // grazia ≤ 0: senza limite
      final u = resolver(grace: Duration.zero);
      fail = false;
      await u.resolve(a);
      fail = true;
      clock.advance(const Duration(days: 30));
      expect(await u.resolve(a), alice);
      // nessun resolver: nessuno entra
      expect(await const ChainResolver([]).resolve(a), isNull);
    });

    test('B-AUTH-04 un membro tolto sparisce solo dopo un aggiornamento riuscito', () async {
      final r = resolver();
      await r.resolve(a);
      upstream.clear();
      fail = true;
      clock.advance(const Duration(seconds: 31));
      expect(await r.resolve(a), alice);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await r.resolve(a), alice);
      fail = false;
      clock.advance(const Duration(seconds: 31));
      await r.resolve(a);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(r.down, isFalse);
      expect(await r.resolve(a), isNull);
    });

    test('elenco ZTNET: solo membri autorizzati, nome o id', () {
      final m = parseZtnetMembers([
        {
          'id': 'A1A1A1A1A1',
          'name': 'alice',
          'authorized': true,
          'ipAssignments': ['192.0.2.5'],
        },
        {
          'id': 'b2b2b2b2b2',
          'name': '',
          'ipAssignments': ['192.0.2.6'],
        },
        {
          'id': 'c3c3c3c3c3',
          'name': 'mallory',
          'authorized': false,
          'ipAssignments': ['192.0.2.7'],
        },
      ]);
      expect(m['192.0.2.5'], const Identity('a1a1a1a1a1', 'alice'));
      expect(m['192.0.2.6'], const Identity('b2b2b2b2b2', 'b2b2b2b2b2'));
      expect(m.containsKey('192.0.2.7'), isFalse);
    });

    test('B-AUTH-09 identità di sviluppo solo dal loopback', () async {
      const d = DevResolver('alice');
      expect((await d.resolve(InternetAddress.loopbackIPv4))?.name, 'alice');
      expect((await d.resolve(InternetAddress.loopbackIPv6))?.name, 'alice');
      expect((await d.resolve(InternetAddress('::ffff:127.0.0.1')))?.name, 'alice');
      expect(await d.resolve(InternetAddress('192.0.2.5')), isNull);
    });
  });

  group('HTTP', () {
    late TestHub t;
    late String space;

    setUp(() async {
      t = await TestHub.start(
        config: (data) => HubConfig(
          dataDir: data,
          address: InternetAddress.loopbackIPv4,
          port: 0,
          admins: const ['CAROL'],
          dnsZone: 'mc.example',
          allowedHosts: const ['nas.example.org'],
        ),
      );
      space = await t.createSpace('World A');
    });
    tearDown(() => t.close());

    test(
      'B-AUTH-05 CSRF: senza X-MineSync 403 (anche PUT blob e PATCH), con sì, GET liberi, cross-site 403',
      () async {
        final noCsrf = await t.req('POST', '/spaces/$space/lock', body: {}, csrf: false);
        expect(noCsrf.status, 403);
        expect(noCsrf.code, 'forbidden');
        final put = await t.req(
          'PUT',
          '/pushes/${'0' * 32}/blobs/${'0' * 64}',
          raw: [1],
          csrf: false,
        );
        expect(put.status, 403);
        final patch = await t.req(
          'PATCH',
          '/settings/general',
          as: 'carol',
          body: {'name': 'x'},
          csrf: false,
        );
        expect(patch.status, 403);
        final del = await t.req('DELETE', '/spaces/$space', as: 'carol', csrf: false);
        expect(del.status, 403, reason: 'G-05: anche DELETE vuole X-MineSync');
        expect((await t.get('/spaces')).status, 200);
        final cross = await t.req(
          'POST',
          '/spaces/$space/lock',
          body: {},
          headers: {'Sec-Fetch-Site': 'cross-site'},
        );
        expect(cross.status, 403);
        final same = await t.req(
          'POST',
          '/spaces/$space/lock',
          body: {},
          headers: {'Sec-Fetch-Site': 'same-origin'},
        );
        expect(same.status, 200);
      },
    );

    test(
      'B-AUTH-06 B-AUTH-07 Host: IP, localhost, zona DNS, MINESYNC_HOSTS; il resto 403',
      () async {
        Future<int> withHost(String? host) async {
          final h = host == null ? '' : 'Host: $host\r\n';
          final (st, _) = await rawRequest(
            t.hub.port,
            'GET /api/v1/hub HTTP/1.1\r\n${h}Connection: close\r\n\r\n',
          );
          return st;
        }

        for (final ok in [
          '127.0.0.1',
          '127.0.0.1:8084',
          '[::1]:8084',
          'localhost:8084',
          'hub.localhost',
          'world.mc.example',
          'MC.EXAMPLE',
          'NAS.example.org:443',
        ]) {
          expect(await withHost(ok), 200, reason: ok);
        }
        for (final bad in [
          'evil.example',
          'evilmc.example',
          'mc.example.evil.example',
          'nas.example.org.evil',
          '',
        ]) {
          expect(await withHost(bad), 403, reason: bad);
        }
        expect(await withHost(null), anyOf(400, 403));
        final cfg = HubConfig.fromEnv({'MINESYNC_HOSTS': ' a.example , B.example ,,'});
        expect(cfg.allowedHosts, ['a.example', 'B.example']);
      },
    );

    test('B-AUTH-08 intestazioni di sicurezza su ogni risposta, anche sui 403', () async {
      for (final r in [
        await t.get('/hub'),
        await t.req('POST', '/spaces', body: {}, csrf: false),
        await t.get('/nope'),
      ]) {
        expect(r.headers.value('x-content-type-options'), 'nosniff');
        expect(r.headers.value('x-frame-options'), 'DENY');
        expect(r.headers.value('content-security-policy'), contains("frame-ancestors 'none'"));
      }
    });

    test('B-AUTH-10 chi non è membro riceve 401 che parla della rete, mai di password', () async {
      t.resolver.byIp.remove(ipOf['bob']);
      final r = await t.get('/hub', as: 'bob');
      expect(r.status, 401);
      expect(r.code, 'unauthenticated');
      final msg = (r.obj['error']! as Map)['message'] as String;
      expect(msg, contains('network'));
      expect(msg.toLowerCase(), isNot(anyOf(contains('password'), contains('token'))));
    });

    test('B-AUTH-11 G-05 gli endpoint admin e distruttivi rispondono 403 ai membri', () async {
      await t.push(space, {'a': bytes('1')});
      final calls = <(String, String, Object?)>[
        ('POST', '/spaces', {'name': 'X'}),
        ('PATCH', '/spaces/$space', {'name': 'Y'}),
        ('DELETE', '/spaces/$space', null),
        ('POST', '/spaces/$space/restore', {'generation': 1}),
        ('GET', '/settings', null),
        ('PATCH', '/settings/history', {'keepLast': 5}),
        ('DELETE', '/spaces/$space/lock', {'force': true}),
      ];
      for (final (m, p, b) in calls) {
        final r = await t.req(m, p, as: 'bob', body: b);
        expect(r.status, 403, reason: '$m $p');
        expect(r.code, 'forbidden');
      }
      // carol è admin (MINESYNC_ADMINS senza maiuscole/minuscole)
      expect(HubInfo.fromJson((await t.get('/hub', as: 'carol')).json).me.admin, isTrue);
      expect((await t.get('/settings', as: 'carol')).status, 200);
    });

    test('G-06 le intestazioni inoltrate non cambiano chi chiama', () async {
      final r = await t.req(
        'GET',
        '/hub',
        headers: {
          'X-Forwarded-For': ipOf['carol']!,
          'X-Real-IP': ipOf['carol']!,
          'Forwarded': 'for=${ipOf['carol']}',
        },
      );
      final me = HubInfo.fromJson(r.json).me;
      expect(me.name, 'alice');
      expect(me.admin, isFalse);
      final c = await t.req(
        'POST',
        '/spaces',
        body: {'name': 'X'},
        headers: {'X-Forwarded-For': ipOf['carol']!},
      );
      expect(c.status, 403);
    });

    test(
      'members.json registra i membri visti; il ruolo admin vale come MINESYNC_ADMINS',
      () async {
        await t.get('/hub', as: 'bob');
        await t.hub.members.flush();
        final f = File('${t.data}/members.json');
        final j = jsonDecode(f.readAsStringSync()) as Map;
        final ms = j['members'] as Map;
        expect((ms[bob.id] as Map)['name'], 'bob');
        expect(f.statSync().mode & 0x3f, 0);
        (ms[bob.id] as Map)['role'] = 'admin';
        f.writeAsStringSync(jsonEncode(j));
        await t.restart();
        expect(HubInfo.fromJson((await t.get('/hub', as: 'bob')).json).me.admin, isTrue);
      },
    );

    test('GET /hub: nome, versione, API, ora, disco, me', () async {
      final h = HubInfo.fromJson((await t.get('/hub')).json);
      expect(h.version, '0.1.0');
      expect(h.version, File('../../VERSION').readAsStringSync().trim());
      expect(h.api, 1);
      expect(h.time, t.clock.wallMs());
      expect(h.me, isA<Me>().having((m) => m.name, 'name', 'alice'));
    });
  });

  group('settings', () {
    late TestHub t;
    setUp(() async => t = await TestHub.start());
    tearDown(() => t.close());

    test('sezioni validate: sezione ignota 404, campo ignoto o fuori intervallo 400', () async {
      final s = await t.get('/settings', as: 'carol');
      final hs = HubSettings.fromJson(s.json);
      expect(hs.sections.toJson(), const SettingsSections().toJson());
      expect(hs.defaults.toJson(), const SettingsSections().toJson());
      expect(hs.changed, isNull);
      expect((await t.req('PATCH', '/settings/telegram', as: 'carol', body: {})).status, 404);
      final unknown = await t.req('PATCH', '/settings/history', as: 'carol', body: {'keep': 1});
      expect(unknown.code, 'bad_request');
      expect(unknown.details['field'], 'history.keep');
      for (final bad in [
        {'keepLast': 0},
        {'keepLast': 'x'},
        {'keepHours': -1},
      ]) {
        expect((await t.req('PATCH', '/settings/history', as: 'carol', body: bad)).status, 400);
      }
      expect(
        (await t.req(
          'PATCH',
          '/settings/protection',
          as: 'carol',
          body: {'massDeleteRatio': 1.5},
        )).status,
        400,
      );
      expect(
        (await t.req('PATCH', '/settings/general', as: 'carol', body: {'name': ''})).status,
        400,
      );
    });

    test('PATCH applicato subito, salvato 0600 e ricaricato al riavvio', () async {
      final r = await t.req(
        'PATCH',
        '/settings/general',
        as: 'carol',
        body: {'name': '  Hub di casa '},
      );
      expect(r.status, 200);
      expect(HubInfo.fromJson((await t.get('/hub')).json).name, 'Hub di casa');
      final f = File('${t.data}/settings.json');
      expect(f.statSync().mode & 0x3f, 0);
      await t.restart();
      expect(HubInfo.fromJson((await t.get('/hub')).json).name, 'Hub di casa');
      final e = t.hub.events.after(0).lastWhere((e) => e.type == 'settings');
      expect(e.actor, 'carol');
      expect(e.data['section'], 'general');
    });
  });

  test('B-AUTH-09 l\'hub con MINESYNC_DEV_USER riconosce il loopback', () async {
    final dir = await Directory.systemTemp.createTemp('minesync-hub-dev-');
    final hub = await Hub.start(
      HubConfig.fromEnv({
        'MINESYNC_DATA': dir.path,
        'MINESYNC_ADDR': '127.0.0.1:0',
        'MINESYNC_DEV_USER': 'alice',
        'MINESYNC_ADMINS': 'alice',
      }),
      disk: FakeDisk().probe,
      log: (_) {},
    );
    addTearDown(() async {
      await hub.close();
      await dir.delete(recursive: true);
    });
    final c = HttpClient();
    final r = await (await c.getUrl(Uri.parse('http://127.0.0.1:${hub.port}/api/v1/hub'))).close();
    final j = jsonDecode(await utf8.decoder.bind(r).join());
    c.close();
    final me = HubInfo.fromJson(j).me;
    expect(me.name, 'alice');
    expect(me.admin, isTrue);
  });
}
