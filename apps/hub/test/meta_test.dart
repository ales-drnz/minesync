// Extra sul mondo: /world, /players, /mods, icone (B-META-01…05), file a
// chunk letti dai blob, sessioni e statistiche dal lock `play`.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:minesync_hub/minesync_hub.dart';
import 'package:minesync_hub/src/meta/blob_source.dart';
import 'package:ms_core/ms_core.dart';
import 'package:ms_minecraft/ms_minecraft.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Zip minimo (voci compresse con deflate).
Uint8List zip(Map<String, Object> entries) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  for (final MapEntry(key: name, value: content) in entries.entries) {
    final raw = content is String ? utf8.encode(content) : content as List<int>;
    final data = ZLibEncoder(raw: true).convert(raw);
    final nb = utf8.encode(name);
    final offset = out.length;
    out
      ..add(
        (ByteData(30)
              ..setUint32(0, 0x04034b50, Endian.little)
              ..setUint16(8, 8, Endian.little)
              ..setUint32(18, data.length, Endian.little)
              ..setUint32(22, raw.length, Endian.little)
              ..setUint16(26, nb.length, Endian.little))
            .buffer
            .asUint8List(),
      )
      ..add(nb)
      ..add(data);
    central
      ..add(
        (ByteData(46)
              ..setUint32(0, 0x02014b50, Endian.little)
              ..setUint16(10, 8, Endian.little)
              ..setUint32(20, data.length, Endian.little)
              ..setUint32(24, raw.length, Endian.little)
              ..setUint16(28, nb.length, Endian.little)
              ..setUint32(42, offset, Endian.little))
            .buffer
            .asUint8List(),
      )
      ..add(nb);
  }
  final cdOff = out.length;
  final cd = central.takeBytes();
  out
    ..add(cd)
    ..add(
      (ByteData(22)
            ..setUint32(0, 0x06054b50, Endian.little)
            ..setUint16(8, entries.length, Endian.little)
            ..setUint16(10, entries.length, Endian.little)
            ..setUint32(12, cd.length, Endian.little)
            ..setUint32(16, cdOff, Endian.little))
          .buffer
          .asUint8List(),
    );
  return out.takeBytes();
}

int _crc(List<int> d) {
  var c = 0xffffffff;
  for (final b in d) {
    c ^= b;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (c >> 1) ^ 0xedb88320 : c >> 1;
    }
  }
  return c ^ 0xffffffff;
}

/// PNG 1×1 generato qui; [tint] cambia il pixel (e quindi l'hash).
Uint8List png([int tint = 0]) {
  final out = BytesBuilder()..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String t, List<int> d) {
    final tb = ascii.encode(t);
    out
      ..add((ByteData(4)..setUint32(0, d.length)).buffer.asUint8List())
      ..add(tb)
      ..add(d)
      ..add((ByteData(4)..setUint32(0, _crc([...tb, ...d]))).buffer.asUint8List());
  }

  chunk('IHDR', [0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0]);
  chunk('IDAT', ZLibEncoder().convert([0, tint, 0x80, 0x40, 0xFF]));
  chunk('IEND', const []);
  return out.takeBytes();
}

Uint8List levelDat() {
  final w = NbtWriter()
    ..begin('')
    ..begin('Data')
    ..string('LevelName', 'Survival')
    ..int32('DataVersion', 3955)
    ..begin('Version')
    ..string('Name', '1.21.1')
    ..end()
    ..byte('Difficulty', 3)
    ..byte('hardcore', 0)
    ..int32('GameType', 1)
    ..int64('Time', 24000 * 5)
    ..begin('WorldGenSettings')
    ..int64('seed', 1234567890123456789)
    ..end()
    ..int32('SpawnX', 8)
    ..int32('SpawnY', 70)
    ..int32('SpawnZ', -8)
    ..end()
    ..end();
  return Uint8List.fromList(gzip.encode(w.takeBytes()));
}

const aliceUuid = '11111111-1111-1111-1111-111111111111';
const bobUuid = '22222222-2222-2222-2222-222222222222';

Uint8List fabricJar({String version = '1.0.0'}) => zip({
  'fabric.mod.json': jsonEncode({
    'id': 'fab',
    'name': 'Fab Mod',
    'version': version,
    'authors': ['alice'],
    'contact': {'homepage': 'javascript:alert(1)'},
    'icon': 'assets/fab/icon.png',
  }),
  'assets/fab/icon.png': png(1),
});

Map<String, List<int>> worldFiles() => {
  'server.properties': bytes(
    'motd=\\u00a7aBenvenuti\nmax-players=8\nwhite-list=true\nlevel-name=world\nonline-mode=true\n',
  ),
  'world/level.dat': levelDat(),
  'world/stats/$aliceUuid.json': bytes(
    jsonEncode({
      'stats': {
        'minecraft:custom': {
          'minecraft:play_time': 36000,
          'minecraft:deaths': 2,
          'minecraft:walk_one_cm': 300,
        },
      },
    }),
  ),
  'ops.json': bytes(
    jsonEncode([
      {'uuid': aliceUuid, 'name': 'alice_mc', 'level': 4},
    ]),
  ),
  'whitelist.json': bytes(
    jsonEncode([
      {'uuid': aliceUuid, 'name': 'alice_mc'},
      {'uuid': bobUuid, 'name': 'bob_mc'},
    ]),
  ),
  'usercache.json': bytes(
    jsonEncode([
      {'uuid': bobUuid, 'name': 'bob_mc', 'expiresOn': '2026-12-22 10:00:00 +0000'},
    ]),
  ),
  'server-icon.png': png(),
  'fabric-server-launch.jar': bytes('launcher'),
  'libraries/net/fabricmc/fabric-loader/0.16.5/fabric-loader-0.16.5.jar': bytes('x'),
  'mods/fab.jar': fabricJar(),
  'mods/zeta.jar': zip({
    'META-INF/mods.toml': '[[mods]]\nmodId="zeta"\ndisplayName="Alpha Forge"\nversion="2"\n',
  }),
  'mods/plain.jar': bytes('not a zip'),
};

void main() {
  late TestHub t;
  late String space;

  setUp(() async {
    t = await TestHub.start();
    space = await t.createSpace('Survival');
  });
  tearDown(() => t.close());

  group('mondo', () {
    test('spazio senza HEAD: n 0 e dati vuoti, icona 404, spazio ignoto 404', () async {
      final w = await t.get('/spaces/$space/world');
      expect(w.status, 200);
      expect(WorldInfo.fromJson(w.json).n, 0);
      expect(PlayerList.fromJson((await t.get('/spaces/$space/players')).json).players, isEmpty);
      expect(ModList.fromJson((await t.get('/spaces/$space/mods')).json).mods, isEmpty);
      expect((await t.get('/spaces/$space/icon')).status, 404);
      expect((await t.get('/spaces/nope/world')).status, 404);
      expect((await t.get('/spaces/nope/stats')).status, 404);
    });

    test('B-META-01 /world: level.dat, server.properties, chip, giocatori, icona', () async {
      expect((await t.push(space, worldFiles())).status, 200);
      final w = WorldInfo.fromJson((await t.get('/spaces/$space/world')).json);
      expect(w.n, 1);
      expect(w.level!.toJson(), {
        'name': 'Survival',
        'version': '1.21.1',
        'dataVersion': 3955,
        'difficulty': 'hard',
        'hardcore': false,
        'gameMode': 'creative',
        'day': 5,
        'timeTicks': 120000,
        'spawn': {'x': 8, 'y': 70, 'z': -8},
        'seed': '1234567890123456789',
      });
      expect(w.properties!.toJson(), {
        'motd': 'Benvenuti',
        'maxPlayers': 8,
        'whitelist': true,
        'whitelistCount': 2,
        'onlineMode': true,
      });
      expect(w.chip.toJson(), {
        'mcVersion': '1.21.1',
        'loader': 'fabric',
        'loaderVersion': '0.16.5',
        'mods': 3,
      });
      expect(w.players, 2);
      expect(w.icon, isTrue);
      // il riassunto dello spazio riceve il chip appena calcolato
      final list = await t.get('/spaces');
      final s = SpaceSummary.fromJson((list.obj['spaces']! as List<Object?>).first);
      expect(s.world?.loader, Loader.fabric);
    });

    test('B-META-06 dopo un salvataggio il riassunto non sparisce e si aggiorna da solo', () async {
      Future<WorldChip?> chip() async => SpaceSummary.fromJson(
        ((await t.get('/spaces')).obj['spaces']! as List<Object?>).first,
      ).world;
      await t.push(space, worldFiles());
      await t.get('/spaces/$space/world');
      expect((await chip())?.mods, 3);
      final files = worldFiles()..['mods/extra.jar'] = fabricJar(version: '9.9.9');
      expect((await t.push(space, files)).status, 200);
      // subito dopo: quello della versione prima, mai null
      expect((await chip())?.mods, anyOf(3, 4));
      // senza che nessuno legga /world: calcolato dopo il salvataggio
      for (var i = 0; i < 200 && (await chip())?.mods != 4; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect((await chip())?.mods, 4);
    });

    test('B-META-06 un calcolo vecchio che finisce dopo non sostituisce il riassunto', () {
      final w = t.hub.world.world;
      w.debugKeepChip(space, 12, const WorldChip(mcVersion: '1.21.1', mods: 97));
      // il calcolo della #11, partito prima, finisce dopo
      w.debugKeepChip(space, 11, const WorldChip(mcVersion: '1.21.1', mods: 95));
      expect(w.debugLastChip(space)?.mods, 97);
      w.debugKeepChip(space, 13, const WorldChip(mcVersion: '1.21.1', mods: 96));
      expect(w.debugLastChip(space)?.mods, 96);
    });

    test('giocatori: unione di stats, ops e whitelist; online dal lock play', () async {
      await t.push(space, worldFiles());
      final tok = t.tokens['$space/alice']!;
      await t.req(
        'POST',
        '/spaces/$space/lock/heartbeat',
        body: {
          'token': tok,
          'info': {
            'client': 'test',
            'action': 'play',
            'players': ['ALICE_MC'],
          },
        },
      );
      final p = PlayerList.fromJson((await t.get('/spaces/$space/players')).json);
      expect(p.n, 1);
      final a = p.players.firstWhere((x) => x.uuid == aliceUuid);
      expect(a.toJson(), {
        'uuid': aliceUuid,
        'name': 'alice_mc',
        'op': true,
        'opLevel': 4,
        'whitelisted': true,
        'online': true,
        'playTicks': 36000,
        'deaths': 2,
        'mobKills': 0,
        'distanceCm': 300,
      });
      final b = p.players.firstWhere((x) => x.uuid == bobUuid);
      expect(b.online, isFalse);
      expect(b.op, isFalse);
      expect(b.lastSeen, DateTime.utc(2026, 11, 22, 10).millisecondsSinceEpoch);
    });

    test(
      'B-META-02/03/05 /mods: metadati, ordine, icona, homepage sicura, changed/since',
      () async {
        await t.push(space, worldFiles());
        var m = ModList.fromJson((await t.get('/spaces/$space/mods')).json);
        expect([for (final x in m.mods) x.file], ['zeta.jar', 'fab.jar', 'plain.jar']);
        final fab = m.mods[1];
        expect(fab.name, 'Fab Mod');
        expect(fab.loader, Loader.fabric);
        expect(fab.homepage, isNull);
        expect(fab.icon, isTrue);
        expect(fab.changed, isTrue);
        expect(fab.since, 1);
        expect(m.mods[0].loader, Loader.forge);
        expect(m.mods[2].bare, isTrue);
        expect(m.bytes, m.mods.fold<int>(0, (a, x) => a + x.size));

        // seconda generazione: fab aggiornata, zeta invariata
        final files = worldFiles()..['mods/fab.jar'] = fabricJar(version: '1.1.0');
        expect((await t.push(space, files)).status, 200);
        m = ModList.fromJson((await t.get('/spaces/$space/mods')).json);
        final f2 = m.mods.firstWhere((x) => x.file == 'fab.jar');
        final z2 = m.mods.firstWhere((x) => x.file == 'zeta.jar');
        expect((f2.version, f2.changed, f2.since, f2.updated), ('1.1.0', true, 1, 2));
        expect((z2.changed, z2.since, z2.updated), (false, 1, 1));
      },
    );

    test('icone: image/png, cache privata, ETag = hash del blob, 304, ignote 404', () async {
      await t.push(space, worldFiles());
      final r = await t.get('/spaces/$space/icon');
      expect(r.status, 200);
      expect(r.headers.contentType!.mimeType, 'image/png');
      expect(r.headers.value('cache-control'), 'private, max-age=86400');
      expect(r.headers.value('etag'), '"${sha256Hex(png())}"');
      expect(r.bytes, png());
      final again = await t.req(
        'GET',
        '/spaces/$space/icon',
        headers: {'If-None-Match': r.headers.value('etag')!},
      );
      expect(again.status, 304);
      final mi = await t.get('/spaces/$space/mods/fab.jar/icon');
      expect(mi.status, 200);
      expect(mi.bytes, png(1));
      expect(mi.headers.value('etag'), '"${sha256Hex(fabricJar())}"');
      expect((await t.get('/spaces/$space/mods/zeta.jar/icon')).status, 404);
      expect((await t.get('/spaces/$space/mods/nope.jar/icon')).status, 404);
      expect(
        (await t.get('/spaces/$space/mods/${Uri.encodeComponent('../fab.jar')}/icon')).status,
        404,
      );
    });

    test('cache su disco per digest: sopravvive al riavvio, sparisce con lo spazio', () async {
      await t.push(space, worldFiles());
      await t.get('/spaces/$space/world');
      final dir = Directory('${t.data}/cache/world/$space');
      expect(dir.listSync().length, 1);
      await t.restart();
      expect(WorldInfo.fromJson((await t.get('/spaces/$space/world')).json).players, 2);
      await t.store.release(carol, admin: true, id: space, force: true);
      expect((await t.req('DELETE', '/spaces/$space', as: 'carol')).status, 200);
      await eventually(() => !dir.existsSync());
    });
  });

  test('file a chunk: lettura a cavallo dei chunk e jar diviso', () async {
    final jar = fabricJar();
    final cut = [0, 100, 101, jar.length ~/ 2, jar.length];
    final chunks = <Chunk>[];
    for (var i = 0; i + 1 < cut.length; i++) {
      final part = Uint8List.sublistView(jar, cut[i], cut[i + 1]);
      final h = sha256Hex(part);
      await t.store.blobs.put(h, part.length, Stream.value(part));
      chunks.add(Chunk(h, part.length));
    }
    final e = FileEntry(size: jar.length, h: sha256Hex(jar), chunks: chunks);
    final src = ManifestFileSource(t.store.blobs, e);
    expect(await src.read(95, 10), Uint8List.sublistView(jar, 95, 105));
    expect(await readManifestFile(t.store.blobs, e, max: 1 << 20), jar);
    expect(await readManifestFile(t.store.blobs, e, max: 10), isNull);
    final z = await ZipArchive.open(src);
    expect((await readModMeta(z!))!.name, 'Fab Mod');
  });

  group('sessioni', () {
    SessionRecorder rec() => t.hub.world.sessions;

    Future<String> play({
      String as = 'alice',
      bool force = false,
      List<String> players = const [],
    }) async {
      final r = await t.req(
        'POST',
        '/spaces/$space/lock',
        as: as,
        body: {
          'info': {'client': 'test', 'action': 'play', 'players': players},
          if (force) 'force': true,
        },
      );
      expect(r.status, 200, reason: '$r');
      return r.obj['token']! as String;
    }

    Future<void> beat(String tok, {String as = 'alice', List<String> players = const []}) async {
      final r = await t.req(
        'POST',
        '/spaces/$space/lock/heartbeat',
        as: as,
        body: {
          'token': tok,
          'info': {'client': 'test', 'action': 'play', 'players': players},
        },
      );
      expect(r.status, 200, reason: '$r');
    }

    Future<SpaceStats> stats() async =>
        SpaceStats.fromJson((await t.get('/spaces/$space/stats')).json);

    test('presa → heartbeat → rilascio: tempo ai giocatori (con tetto), hosting', () async {
      final start = t.clock.wallMs();
      final tok = await play(players: ['steve']);
      var s = await stats();
      expect(s.kept, 40);
      expect(s.sessions.single.ended, SessionEnd.ongoing);
      for (var i = 0; i < 3; i++) {
        t.clock.advance(const Duration(seconds: 20));
        await beat(tok, players: ['steve', 'alex']);
        rec().sample();
      }
      // un buco lungo conta al più 2 × heartbeat
      t.clock.advance(const Duration(seconds: 80));
      await beat(tok, players: ['steve']);
      rec().sample();
      t.clock.advance(const Duration(seconds: 5));
      final r = await t.req('DELETE', '/spaces/$space/lock', body: {'token': tok});
      expect(r.status, 200);
      s = await stats();
      final one = s.sessions.single;
      expect(one.ended, SessionEnd.released);
      expect(one.start, start);
      expect(one.end, start + 145000);
      expect(one.players, {'steve': 100000, 'alex': 60000});
      expect([for (final p in s.play) (p.name, p.ms)], [('steve', 100000), ('alex', 60000)]);
      expect(s.hosting.single.toJson(), {'name': 'alice', 'ms': 145000, 'memberId': alice.id});
      final sum = SpaceSummary.fromJson(
        ((await t.get('/spaces')).obj['spaces']! as List<Object?>).first,
      );
      expect(sum.lastSession?.ended, SessionEnd.released);
      // su disco, nel formato del contratto (la scrittura è accodata)
      await rec().flush();
      final disk = jsonDecode(File('${t.data}/spaces/$space/sessions.json').readAsStringSync());
      expect(SessionRecord.fromJson((disk as List<Object?>).first).ended, SessionEnd.released);
    });

    test('lock solo di push: nessuna sessione', () async {
      await t.lock(space);
      rec().sample();
      expect((await stats()).sessions, isEmpty);
    });

    test('presa forzata da un admin: forced, e comincia la sessione nuova', () async {
      await play();
      t.clock.advance(const Duration(seconds: 30));
      await play(as: 'carol', force: true);
      final s = await stats();
      expect(
        [for (final x in s.sessions) (x.name, x.ended)],
        [('carol', SessionEnd.ongoing), ('alice', SessionEnd.forced)],
      );
    });

    test(
      'stale: finisce all\'ultimo heartbeat; un heartbeat la riprende; poi presa altrui',
      () async {
        final tok = await play(players: ['steve']);
        t.clock.advance(const Duration(seconds: 20));
        await beat(tok, players: ['steve']);
        rec().sample();
        final lastBeat = t.clock.wallMs();
        t.clock.advance(const Duration(seconds: 120));
        rec().sample();
        var s = await stats();
        expect((s.sessions.single.ended, s.sessions.single.end), (SessionEnd.stale, lastBeat));
        expect(t.hub.world.lastSession(space)?.ended, SessionEnd.stale);
        // rinnovato: la stessa sessione continua
        await beat(tok, players: ['steve']);
        rec().sample();
        s = await stats();
        expect(s.sessions.single.ended, SessionEnd.ongoing);
        expect(s.sessions.single.players['steve'], 20000 + 40000);
        // di nuovo stale, poi bob prende il lock libero
        final beat2 = t.clock.wallMs();
        t.clock.advance(const Duration(seconds: 120));
        await play(as: 'bob');
        s = await stats();
        expect(
          [for (final x in s.sessions) (x.name, x.ended, x.end)],
          [('bob', SessionEnd.ongoing, null), ('alice', SessionEnd.stale, beat2)],
        );
      },
    );

    test('riavvio: la sessione in corso è adottata; conservate al più sessionsKept', () async {
      final tok = await play(players: ['steve']);
      t.clock.advance(const Duration(seconds: 20));
      await beat(tok, players: ['steve']);
      rec().sample();
      await t.restart();
      t.clock.advance(const Duration(seconds: 20));
      await beat(tok, players: ['steve']);
      rec().sample();
      var s = await stats();
      expect(s.sessions.single.ended, SessionEnd.ongoing);
      expect(s.sessions.single.players['steve'], 40000);
      await t.req('DELETE', '/spaces/$space/lock', body: {'token': tok});

      rec().sessionsKeptOf = () => 2;
      for (var i = 0; i < 3; i++) {
        final k = await play();
        t.clock.advance(const Duration(seconds: 10));
        await t.req('DELETE', '/spaces/$space/lock', body: {'token': k});
      }
      s = await stats();
      expect(s.kept, 2);
      expect(s.sessions.length, 2);
    });

    test(
      'B-LOCK-04 hosting: chi non risponde conta fino all\'ultimo battito, anche dopo riavvii',
      () async {
        await play();
        t.clock.advance(const Duration(seconds: 60));
        // l'app sparisce: niente più battiti, poi il lock scade
        t.clock.advance(const Duration(seconds: 91));
        t.hub.store.checkStaleLocks();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        // l'hub riparte due volte mentre nessuno lo libera
        for (var i = 0; i < 2; i++) {
          t.clock.advance(const Duration(hours: 10));
          await t.restart();
        }
        t.clock.advance(const Duration(hours: 1));
        await play(as: 'bob');
        final s = await stats();
        final alice = s.sessions.firstWhere((x) => x.name == 'alice');
        expect(alice.ended, SessionEnd.stale);
        expect(alice.end! - alice.start, 0, reason: 'nessun battito dopo la presa');
        expect(s.hosting.firstWhere((h) => h.name == 'alice').ms, lessThan(60000));
      },
    );

    test('spazio cancellato: sessioni dimenticate', () async {
      final tok = await play();
      await t.req('DELETE', '/spaces/$space/lock', body: {'token': tok});
      expect(rec().sessions(space), hasLength(1));
      expect((await t.req('DELETE', '/spaces/$space', as: 'carol')).status, 200);
      expect(rec().sessions(space), isEmpty);
      rec().sample();
      await rec().flush();
      expect(File('${t.data}/spaces/$space/sessions.json').existsSync(), isFalse);
      expect(t.hub.world.lastSession(space), isNull);
    });
  });
}
