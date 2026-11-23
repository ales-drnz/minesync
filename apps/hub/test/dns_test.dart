// Server DNS della zona dell'hub (B-DNS-01…07): query vere su UDP (e TCP)
// verso 127.0.0.1, porta scelta dal sistema.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:minesync_hub/minesync_hub.dart';
import 'package:test/test.dart';

import 'support.dart';

const zone = 'mc.test';
const tA = 1, tSOA = 6, tSRV = 33, tAAAA = 28;

/// Query con id fisso; [flags] permette di forgiare risposte o altri opcode.
Uint8List query(String name, int type, {int flags = 0x0100, int id = 0x1234}) {
  final b = BytesBuilder()
    ..add([id >> 8, id & 0xff, flags >> 8, flags & 0xff, 0, 1, 0, 0, 0, 0, 0, 0]);
  for (final l in name.split('.')) {
    b
      ..addByte(l.length)
      ..add(l.codeUnits);
  }
  b
    ..addByte(0)
    ..add([type >> 8, type & 0xff, 0, 1]);
  return b.takeBytes();
}

final class Rr {
  Rr(this.type, this.data);
  final int type;
  final Uint8List data;
  String get ip => data.join('.');
  int get srvPort => data[4] << 8 | data[5];
}

final class Msg {
  Msg(this.raw);
  final Uint8List raw;
  int get id => raw[0] << 8 | raw[1];
  int get rcode => raw[3] & 0x0f;
  bool get aa => raw[2] & 0x04 != 0;
  late final List<List<Rr>> sections = _parse();
  List<Rr> get answers => sections[0];
  List<Rr> get authority => sections[1];
  List<Rr> get additional => sections[2];

  int _skipName(int off) {
    while (true) {
      final l = raw[off];
      if (l == 0) return off + 1;
      if (l & 0xc0 == 0xc0) return off + 2;
      off += l + 1;
    }
  }

  List<List<Rr>> _parse() {
    var off = _skipName(12) + 4;
    final out = <List<Rr>>[];
    for (final count in [raw[6] << 8 | raw[7], raw[8] << 8 | raw[9], raw[10] << 8 | raw[11]]) {
      final sec = <Rr>[];
      for (var i = 0; i < count; i++) {
        off = _skipName(off);
        final type = raw[off] << 8 | raw[off + 1];
        final len = raw[off + 8] << 8 | raw[off + 9];
        sec.add(Rr(type, Uint8List.sublistView(raw, off + 10, off + 10 + len)));
        off += 10 + len;
      }
      out.add(sec);
    }
    return out;
  }
}

/// Manda [q] da [from] e aspetta la risposta (null se non arriva).
Future<Msg?> ask(int port, Uint8List q, {String from = '127.0.0.1'}) async {
  final s = await RawDatagramSocket.bind(InternetAddress(from), 0);
  final c = Completer<Msg?>();
  s.listen((ev) {
    if (ev == RawSocketEvent.read) {
      final d = s.receive();
      if (d != null && !c.isCompleted) c.complete(Msg(d.data));
    }
  });
  s.send(q, InternetAddress.loopbackIPv4, port);
  final r = await c.future.timeout(const Duration(milliseconds: 400), onTimeout: () => null);
  s.close();
  return r;
}

void main() {
  late DnsServer dns;
  late Map<String, DnsEntry> table;
  var lookups = 0;

  setUp(() async {
    lookups = 0;
    table = {
      'survival': (
        exists: true,
        host: const DnsHost(ip: '192.0.2.10', lan: '198.51.100.7', port: 25570),
      ),
      'creativo': (exists: true, host: null),
      'local': (exists: true, host: const DnsHost(ip: '127.0.0.1', lan: '198.51.100.8')),
    };
    // con la porta 0 l'UDP sceglie una porta libera, ma la stessa porta TCP
    // può essere occupata da un altro test in parallelo: allora il server
    // parte solo in UDP (voluto). Qui servono entrambe: si riprova.
    for (var attempt = 0; ; attempt++) {
      dns = DnsServer(
        zone: zone,
        lookup: (id) {
          lookups++;
          return table[id] ?? (exists: false, host: null);
        },
        log: (_) {},
      );
      expect(await dns.start(InternetAddress.loopbackIPv4, 0), isTrue);
      if (dns.tcpPort != null || attempt >= 9) break;
      await dns.stop();
    }
  });
  tearDown(() => dns.stop());

  test('B-DNS-01 A di zerotier.<spazio>.<zona> con un host vivo: un record', () async {
    final m = (await ask(dns.port!, query('zerotier.survival.$zone', tA)))!;
    expect(m.id, 0x1234);
    expect(m.rcode, 0);
    expect(m.aa, isTrue);
    expect(m.answers.map((r) => r.ip), ['192.0.2.10']);
  });

  test('B-DNS-01 i nomi sono senza maiuscole', () async {
    final m = (await ask(dns.port!, query('ZeroTier.Survival.MC.Test', tA)))!;
    expect(m.answers.single.ip, '192.0.2.10');
  });

  test('B-DNS-02 orizzonte diviso: a chi ospita il suo indirizzo LAN', () async {
    final host = (await ask(dns.port!, query('zerotier.local.$zone', tA), from: '127.0.0.1'))!;
    expect(host.answers.single.ip, '198.51.100.8');
    final other = (await ask(dns.port!, query('zerotier.local.$zone', tA), from: '127.0.0.2'))!;
    expect(other.answers.single.ip, '127.0.0.1');
  });

  test('B-DNS-03 SRV _minecraft._tcp: porta pubblicata più glue A', () async {
    final m = (await ask(dns.port!, query('_minecraft._tcp.zerotier.survival.$zone', tSRV)))!;
    expect(m.rcode, 0);
    expect(m.answers, hasLength(1));
    expect(m.answers.single.type, tSRV);
    expect(m.answers.single.srvPort, 25570);
    expect(m.additional, hasLength(1));
    expect(m.additional.single.type, tA);
    expect(m.additional.single.ip, '192.0.2.10');
    expect(m.authority, isEmpty);
  });

  test('B-DNS-04 nessuno ospita: NOERROR vuoto con SOA; spazio ignoto: NXDOMAIN con SOA', () async {
    final off = (await ask(dns.port!, query('zerotier.creativo.$zone', tA)))!;
    expect(off.rcode, 0);
    expect(off.answers, isEmpty);
    expect(off.authority.map((r) => r.type), [tSOA]);
    final nx = (await ask(dns.port!, query('zerotier.avventura.$zone', tA)))!;
    expect(nx.rcode, 3);
    expect(nx.authority.map((r) => r.type), [tSOA]);
    final bad = (await ask(dns.port!, query('www.$zone', tA)))!;
    expect(bad.rcode, 3);
    // risposta positiva: niente SOA
    final on = (await ask(dns.port!, query('zerotier.survival.$zone', tA)))!;
    expect(on.authority, isEmpty);
  });

  test('B-DNS-05 fuori zona REFUSED senza SOA; AAAA NOERROR vuoto', () async {
    final out = (await ask(dns.port!, query('example.org', tA)))!;
    expect(out.rcode, 5);
    expect(out.authority, isEmpty);
    expect(out.answers, isEmpty);
    final aaaa = (await ask(dns.port!, query('zerotier.survival.$zone', tAAAA)))!;
    expect(aaaa.rcode, 0);
    expect(aaaa.answers, isEmpty);
  });

  test('B-DNS-06 risposte (QR=1) e opcode diversi da QUERY si scartano', () async {
    expect(await ask(dns.port!, query('zerotier.survival.$zone', tA, flags: 0x8100)), isNull);
    // opcode 2 (STATUS) e 4 (NOTIFY)
    expect(await ask(dns.port!, query('zerotier.survival.$zone', tA, flags: 0x1000)), isNull);
    expect(await ask(dns.port!, query('zerotier.survival.$zone', tA, flags: 0x2000)), isNull);
    // malformato
    expect(await ask(dns.port!, Uint8List.fromList([1, 2, 3])), isNull);
    // il server risponde ancora
    expect(await ask(dns.port!, query('zerotier.survival.$zone', tA)), isNotNull);
  });

  test('B-DNS-07 le risposte seguono subito la tabella (nessuna cache)', () async {
    table['creativo'] = (exists: true, host: const DnsHost(ip: '192.0.2.20'));
    expect(
      (await ask(dns.port!, query('zerotier.creativo.$zone', tA)))!.answers.single.ip,
      '192.0.2.20',
    );
    table.remove('creativo');
    expect((await ask(dns.port!, query('zerotier.creativo.$zone', tA)))!.rcode, 3);
    expect(lookups, 2);
  });

  test('B-DNS-01 anche su TCP (lunghezza su 2 byte)', () async {
    final s = await Socket.connect(InternetAddress.loopbackIPv4, dns.tcpPort!);
    final q = query('zerotier.survival.$zone', tA);
    s.add([q.length >> 8, q.length & 0xff, ...q]);
    final b = BytesBuilder();
    await for (final c in s.timeout(const Duration(seconds: 2))) {
      b.add(c);
      final got = b.toBytes();
      if (got.length >= 2 && got.length >= 2 + (got[0] << 8 | got[1])) break;
    }
    s.destroy();
    final raw = b.takeBytes();
    expect(Msg(Uint8List.sublistView(raw, 2)).answers.single.ip, '192.0.2.10');
  });

  test('stato per la pagina Sistema; bind fallito non lancia', () async {
    expect(dns.status.on, isTrue);
    expect(dns.status.zone, zone);
    expect(dns.status.addr, '127.0.0.1:${dns.port}');
    final other = DnsServer(zone: zone, lookup: (_) => (exists: false, host: null), log: (_) {});
    // stessa porta UDP già occupata
    expect(await other.start(InternetAddress.loopbackIPv4, dns.port!), isFalse);
    expect(other.status.on, isFalse);
    expect(other.status.error, isNotNull);
    await dns.stop();
    expect(dns.status.on, isFalse);
  });

  group('configurazione', () {
    test('MINESYNC_DNS_ADDR: :53 con la zona, off spegne, niente zona niente DNS', () {
      final on = HubConfig.fromEnv({'MINESYNC_DNS_ZONE': 'MC.Test'});
      expect(on.dnsZone, 'mc.test');
      expect(on.dnsBind!.$2, 53);
      final custom = HubConfig.fromEnv({
        'MINESYNC_DNS_ZONE': 'mc.test',
        'MINESYNC_DNS_ADDR': '127.0.0.1:5353',
      });
      expect(custom.dnsBind!.$1.address, '127.0.0.1');
      expect(custom.dnsBind!.$2, 5353);
      final off = HubConfig.fromEnv({'MINESYNC_DNS_ZONE': 'mc.test', 'MINESYNC_DNS_ADDR': 'off'});
      expect(off.dnsBind, isNull);
      expect(off.dnsZone, 'mc.test'); // la zona conta ancora per gli host ammessi
      expect(HubConfig.fromEnv({}).dnsBind, isNull);
      expect(
        () => HubConfig.fromEnv({'MINESYNC_DNS_ZONE': 'mc.test', 'MINESYNC_DNS_ADDR': 'x'}),
        throwsFormatException,
      );
    });
  });

  group('sui lock veri dell\'hub', () {
    late TestHub t;
    late DnsServer live;
    setUp(() async {
      t = await TestHub.start();
      live = DnsServer(
        zone: zone,
        lookup: lockLookup(
          t.store.peekSpace,
          (l) => l.isStale(t.store.clock, t.store.options.lockTtl),
        ),
        log: (_) {},
      );
      await live.start(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() async {
      await live.stop();
      await t.close();
    });

    Future<Res> play(String id, {String as = 'alice', Map<String, Object?> extra = const {}}) =>
        t.req(
          'POST',
          '/spaces/$id/lock',
          as: as,
          body: {
            'info': {'client': 'test', 'action': 'play', ...extra},
          },
        );

    test('B-DNS-07 acquire → risposta, release → vuoto, spazio cancellato → NXDOMAIN', () async {
      final id = await t.createSpace('Survival');
      final name = 'zerotier.$id.$zone';
      expect((await ask(live.port!, query(name, tA)))!.answers, isEmpty);
      final r = await play(id, extra: {'port': 25566, 'lan': '198.51.100.9'});
      expect(r.status, 200);
      final tok = r.obj['token']! as String;
      // bob vede l'indirizzo dal socket, alice (chi ospita) il suo LAN
      expect(
        (await ask(live.port!, query(name, tA), from: '127.0.0.2'))!.answers.single.ip,
        '127.0.0.1',
      );
      expect((await ask(live.port!, query(name, tA)))!.answers.single.ip, '198.51.100.9');
      final srv = (await ask(live.port!, query('_minecraft._tcp.$name', tSRV)))!;
      expect(srv.answers.single.srvPort, 25566);
      // il lock scaduto non risponde più
      t.clock.advance(t.store.options.lockTtl + const Duration(seconds: 1));
      expect((await ask(live.port!, query(name, tA)))!.answers, isEmpty);
      await t.req('POST', '/spaces/$id/lock/heartbeat', body: {'token': tok});
      expect((await ask(live.port!, query(name, tA)))!.answers, hasLength(1));
      await t.req('DELETE', '/spaces/$id/lock', body: {'token': tok});
      final off = (await ask(live.port!, query(name, tA)))!;
      expect(off.rcode, 0);
      expect(off.answers, isEmpty);
      await t.req('DELETE', '/spaces/$id', as: 'carol');
      expect((await ask(live.port!, query(name, tA)))!.rcode, 3);
    });

    test('B-DNS-07 un lock di push non è un server aperto', () async {
      final id = await t.createSpace('Creativo');
      await t.req(
        'POST',
        '/spaces/$id/lock',
        body: {
          'info': {'client': 'test', 'action': 'push'},
        },
      );
      expect((await ask(live.port!, query('zerotier.$id.$zone', tA)))!.answers, isEmpty);
    });

    test('B-DNS-07 il DNS risponde anche mentre il mutex dello spazio è preso', () async {
      final id = await t.createSpace('Avventura');
      await play(id);
      final st = t.store.peekSpace(id)!;
      final hold = Completer<void>();
      final held = st.mutex.run(() => hold.future);
      expect((await ask(live.port!, query('zerotier.$id.$zone', tA)))!.answers, hasLength(1));
      hold.complete();
      await held;
    });
  });
}
