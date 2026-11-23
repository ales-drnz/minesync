// Contratto web ↔ hub: un hub vero in-process (apps/hub) su una porta
// effimera e HttpHubApi sopra un trasporto dart:io. Ogni chiamata della web
// UI deve passare per l'hub vero e decodificarsi nei modelli di
// ms_protocol: se l'hub cambia forma, questo test lo dice prima del browser.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_hub/minesync_hub.dart';
import 'package:minesync_hub_web/src/api/http_hub_api.dart';
import 'package:minesync_hub_web/src/api/hub_api.dart';
import 'package:ms_protocol/ms_protocol.dart';

import 'support/io_transport.dart';

const _alice = Identity('a1a1a1a1a1', 'alice');
const _bob = Identity('b2b2b2b2b2', 'bob');

String _sha(List<int> b) => sha256.convert(b).toString();

/// Telegram finto: il bot non parte mai, ogni chiamata risponde 401.
final class _NoTelegram implements TelegramTransport {
  @override
  Future<({int status, Object? body})> call(
    String token,
    String method,
    Map<String, Object?> body,
    Duration timeout,
  ) async => (status: 401, body: const {'ok': false, 'description': 'Unauthorized'});

  @override
  void close() {}
}

void main() {
  late Directory dir;
  late Hub hub;
  late IoTransport aliceT;
  late IoTransport bobT;
  late HttpHubApi admin;
  late HttpHubApi member;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('minesync-web-contract-');
    hub = await Hub.start(
      HubConfig(
        dataDir: dir.path,
        address: InternetAddress.loopbackIPv4,
        port: 0,
        admins: const ['alice'],
        keepAlive: const Duration(milliseconds: 200),
      ),
      resolver: StaticResolver({'127.0.0.1': _alice, '127.0.0.2': _bob}),
      disk: (_) => (free: 100 << 30, total: 200 << 30),
      options: const StoreOptions(maintenanceDelay: Duration(days: 1)),
      log: (_) {},
      // nessuna connessione vera verso la porta di gioco
      portConnector: (host, port, timeout) async => false,
    );
    // Telegram si aggancia fuori da Hub.start (come in bin/hub.dart)
    final file = TelegramConfigFile('${dir.path}/telegram.json');
    final bot = TelegramBot(
      transport: _NoTelegram(),
      clock: hub.store.clock,
      spaces: hub.store.listSpaces,
      config: await file.load(),
    );
    hub.apiRoutes.add(
      TelegramRoutes(
        bot: bot,
        file: file,
        clock: hub.store.clock,
        spaceNames: () => {for (final s in hub.store.listSpaces()) s.id: s.name},
      ).handle,
    );
    final origin = Uri.parse('http://127.0.0.1:${hub.port}/server/x');
    aliceT = IoTransport('127.0.0.1');
    bobT = IoTransport('127.0.0.2');
    admin = HttpHubApi(aliceT, origin);
    member = HttpHubApi(bobT, origin);
  });

  tearDownAll(() async {
    await aliceT.close();
    await bobT.close();
    await hub.close();
    await dir.delete(recursive: true);
  });

  /// Chiamata grezza (lock e push non sono nell'API della web UI).
  Future<Map<String, Object?>> raw(String method, String path, [Object? body]) async {
    final r = await aliceT.send(
      method,
      Uri.parse('http://127.0.0.1:${hub.port}/api/v1/$path'),
      headers: {csrfHeader: '1', 'Content-Type': 'application/json'},
      body: body == null ? null : jsonEncode(body),
    );
    expect(r.status, lessThan(300), reason: '$method $path: ${r.body}');
    return r.body.isEmpty ? const {} : jsonDecode(r.body) as Map<String, Object?>;
  }

  /// Push di [files] sulla HEAD di [space] con il lock [token].
  Future<void> push(String space, String token, Map<String, List<int>> files) async {
    final head = await admin.generation(space);
    final m = Manifest({
      for (final e in files.entries) e.key: FileEntry(size: e.value.length, h: _sha(e.value)),
    });
    final b = await raw(
      'POST',
      'spaces/$space/pushes',
      PushBegin(parent: head.n, parentDigest: head.digest, lockToken: token, manifest: m).toJson(),
    );
    final byHash = {for (final v in files.values) _sha(v): v};
    for (final h in (b['missing']! as List<Object?>).cast<String>()) {
      final r = await aliceT.send(
        'PUT',
        Uri.parse('http://127.0.0.1:${hub.port}/api/v1/pushes/${b['pushId']}/blobs/$h'),
        headers: {csrfHeader: '1', 'Content-Type': 'application/octet-stream'},
        body: latin1.decode(Uint8List.fromList(byHash[h]!)),
      );
      expect(r.status, anyOf(200, 201), reason: r.body);
    }
    await raw('POST', 'pushes/${b['pushId']}/commit');
  }

  test('hub, spazi, creazione e dettaglio', () async {
    final info = await admin.hub();
    expect(info.me.admin, isTrue);
    expect(info.api, apiVersion);
    expect((await member.hub()).me.admin, isFalse);

    final d = await admin.createSpace('Survival', Profile.minecraft);
    expect(d.summary.name, 'Survival');
    expect(d.summary.head, isNull);
    final list = await member.spaces();
    expect(list.map((s) => s.id), contains(d.summary.id));

    final det = await member.space(d.summary.id);
    expect(det.settings, isNotNull);
    expect(det.inherited, isNotNull);
    expect(det.profileExclusions, isNotEmpty);

    // un membro non crea server
    await expectLater(
      member.createSpace('Creativo', Profile.generic),
      throwsA(isA<ApiError>().having((e) => e.code, 'code', ErrorCode.forbidden)),
    );
  });

  test('spazio vuoto: mondo, giocatori, mod, statistiche, storia', () async {
    final id = (await admin.createSpace('Vuoto', Profile.minecraft)).summary.id;
    final w = await member.world(id);
    expect(w.n, 0);
    expect((await member.players(id)).players, isEmpty);
    final mods = await member.mods(id);
    expect(mods.mods, isEmpty);
    expect(mods.bytes, 0);
    final st = await member.stats(id);
    expect(st.sessions, isEmpty);
    expect(await member.generations(id), isEmpty);
    expect((await member.generation(id)).n, 0);
  });

  test('storia: generazioni, diff, freed, zip, restore, elimina, pulizia', () async {
    final id = (await admin.createSpace('Avventura', Profile.generic)).summary.id;
    final lock = await raw('POST', 'spaces/$id/lock', {
      'info': {'client': 'contract', 'action': 'push'},
    });
    final token = lock['token']! as String;
    await push(id, token, {'a.txt': utf8.encode('uno'), 'b.txt': utf8.encode('due')});
    await push(id, token, {'a.txt': utf8.encode('uno!'), 'c.txt': utf8.encode('tre')});
    await raw('DELETE', 'spaces/$id/lock', {'token': token});

    final gens = await member.generations(id);
    expect(gens.map((g) => g.n), [2, 1]);
    expect(await member.generations(id, before: 2, limit: 10), hasLength(1));
    final head = await member.generation(id);
    expect(head.n, 2);
    expect(head.manifest.files.keys, containsAll(['a.txt', 'c.txt']));

    final diff = await member.diff(id, 2, limit: 120);
    expect(diff.parent, 1);
    expect(diff.added.items.map((e) => e.path), ['c.txt']);
    expect(diff.changed.items.single.path, 'a.txt');
    expect(diff.changed.items.single.prevSize, 3);
    expect(diff.removed.total, 1);

    expect(await admin.freed(id, 1), greaterThanOrEqualTo(0));
    await expectLater(
      member.freed(id, 1),
      throwsA(isA<ApiError>().having((e) => e.code, 'code', ErrorCode.forbidden)),
    );

    final zip = await bobT.send('GET', member.zipUrl(id, n: 1));
    expect(zip.status, 200);
    expect(zip.headers['content-type'], contains('application/zip'));

    final restored = await admin.restore(id, 1);
    expect(restored.n, 3);
    expect(restored.restoredFrom, 1);
    expect(restored.kind, GenerationKind.restore);

    final file = await admin.restoreFile(id, const RestoreFileRequest(path: 'a.txt', from: 2));
    expect(file.n, 4);
    expect(file.restoredPath, 'a.txt');

    await expectLater(
      admin.deleteGeneration(id, 4),
      throwsA(isA<ApiError>().having((e) => e.code, 'code', ErrorCode.isHead)),
    );
    final del = await admin.deleteGeneration(id, 2);
    expect(del.deleted, 2);

    final pre = await admin.gcPreview(space: id, keep: 1);
    expect(pre.spaces.single.id, id);
    expect(pre.spaces.single.now, 3);
    expect(pre.spaces.single.after, 1);
    final draft = await admin.gcPreview(
      space: id,
      history: const HistorySettings(keepLast: 1, keepHours: 0, keepDays: 0),
    );
    expect(draft.spaces.single.after, lessThanOrEqualTo(3));
    final gc = await admin.gc(space: id, keep: 2);
    expect(gc.generations, 1);

    final usage = await member.usage();
    expect(usage.disk.total, 200 << 30);
  });

  test('modifica dello spazio: nome, esclusioni, sovrascritture, eliminazione', () async {
    final id = (await admin.createSpace('Creativo', Profile.minecraft)).summary.id;
    final d = await admin.updateSpace(
      id,
      const SpacePatch(
        name: 'Creativo 2',
        exclusions: ['bluemap/**'],
        overrides: {
          'sessions': {'autosaveMinutes': 10},
          'history': {'keepLast': 5},
        },
      ),
    );
    expect(d.summary.name, 'Creativo 2');
    expect(d.ownExclusions, ['bluemap/**']);
    expect(d.settings!.sessions.autosaveMinutes, 10);
    expect(d.settings!.history.keepLast, 5);
    expect(d.inherited!.sessions.autosaveMinutes, const SessionSettings().autosaveMinutes);
    expect((d.overrides['sessions']! as Map<String, Object?>)['autosaveMinutes'], 10);

    // {} = di nuovo eredita
    final back = await admin.updateSpace(id, const SpacePatch(overrides: {'sessions': {}}));
    expect(back.settings!.sessions.autosaveMinutes, const SessionSettings().autosaveMinutes);
    expect(back.settings!.history.keepLast, 5);

    await expectLater(
      admin.updateSpace(
        id,
        const SpacePatch(
          overrides: {
            'sessions': {'autosaveMinutes': 0},
          },
        ),
      ),
      throwsA(isA<ApiError>().having((e) => e.code, 'code', ErrorCode.badRequest)),
    );

    // con un lock vivo l'eliminazione è rifiutata
    final lock = await raw('POST', 'spaces/$id/lock', {
      'info': {'client': 'contract', 'action': 'push'},
    });
    await expectLater(
      admin.deleteSpace(id),
      throwsA(isA<ApiError>().having((e) => e.code, 'code', ErrorCode.locked)),
    );
    await raw('DELETE', 'spaces/$id/lock', {'token': lock['token']});
    await admin.deleteSpace(id);
    expect((await admin.spaces()).map((s) => s.id), isNot(contains(id)));
  });

  test('lock: prova della porta e rilascio forzato', () async {
    final id = (await admin.createSpace('Porta', Profile.minecraft)).summary.id;
    await expectLater(
      member.portCheck(id),
      throwsA(isA<ApiError>().having((e) => e.code, 'code', ErrorCode.notLocked)),
    );
    await raw('POST', 'spaces/$id/lock', {
      'info': {'client': 'contract', 'action': 'play', 'port': 25565},
    });
    final sp = (await member.spaces()).firstWhere((s) => s.id == id);
    expect(sp.lock!.name, 'alice');
    expect(sp.lock!.ip, '127.0.0.1');
    final pc = await member.portCheck(id);
    expect(pc.port, 25565);
    await expectLater(
      member.portCheck(id),
      throwsA(isA<ApiError>().having((e) => e.code, 'code', ErrorCode.rateLimited)),
    );
    // un lock vivo di un altro lo forza solo un admin
    await expectLater(
      member.forceReleaseLock(id),
      throwsA(isA<ApiError>().having((e) => e.code, 'code', ErrorCode.forbidden)),
    );
    await admin.forceReleaseLock(id);
    expect((await member.space(id)).summary.lock, isNull);
  });

  test('membri, sistema, impostazioni, Telegram, download', () async {
    final m = await admin.members();
    expect(m.members.map((x) => x.name), contains('alice'));
    final sys = await admin.system();
    expect(sys.dataDir, isNotEmpty);
    final st = await admin.settings();
    expect(st.defaults.history.keepLast, 30);
    final patched = await admin.patchSettings('sessions', {'autosaveMinutes': 7});
    expect(patched.sections.sessions.autosaveMinutes, 7);
    expect(patched.changed?.section, 'sessions');
    await expectLater(
      member.settings(),
      throwsA(isA<ApiError>().having((e) => e.code, 'code', ErrorCode.forbidden)),
    );
    final tg = await admin.telegram();
    expect(tg.settings.enabled, isFalse);
    final dl = await member.downloads();
    expect(dl.files, isEmpty);
    expect(member.downloadUrl('x.exe').path, '/dl/x.exe');
  });

  test('pacchetto per i giocatori: riassunto, .mrpack, solo le mod, file del pack', () async {
    final id = (await admin.createSpace('Survival', Profile.minecraft)).summary.id;
    // senza minesync-pack.json: niente pacchetto, i file sono 404
    final none = await member.pack(id);
    expect(none.available, isFalse);
    expect(await member.packFile(id), isNull);
    expect((await bobT.send('GET', member.packUrl(id))).status, 404);

    final jar = utf8.encode('jar:create-6.0.8.jar');
    const cdn = 'https://cdn.modrinth.com/data/AAAAAAAA/versions/BBBBBBBB/create-6.0.8.jar';
    final pack = {
      'format': 1,
      'name': 'Survival',
      'minecraft': '1.21.1',
      'loader': 'fabric',
      'loaderVersion': '0.16.14',
      'mods': [
        {
          'path': 'mods/create-6.0.8.jar',
          'name': 'Create',
          'sha1': sha1.convert(jar).toString(),
          'sha512': sha512.convert(jar).toString(),
          'size': jar.length,
          'side': 'both',
          'source': 'modrinth',
          'projectId': 'AAAAAAAA',
          'versionId': 'BBBBBBBB',
          'versionNumber': '6.0.8',
          'downloads': [cdn],
        },
        {
          'path': 'mods/tweaks.jar',
          'sha1': sha1.convert(utf8.encode('t')).toString(),
          'sha512': sha512.convert(utf8.encode('t')).toString(),
          'size': 1,
          'side': 'server',
          'source': 'manual',
        },
      ],
    };
    final lock = await raw('POST', 'spaces/$id/lock', {
      'info': {'client': 'contract', 'action': 'push'},
    });
    final token = lock['token']! as String;
    await push(id, token, {
      'minesync-pack.json': utf8.encode('${const JsonEncoder.withIndent('  ').convert(pack)}\n'),
      'mods/create-6.0.8.jar': jar,
      'mods/tweaks.jar': utf8.encode('t'),
    });
    await raw('DELETE', 'spaces/$id/lock', {'token': token});

    final p = await member.pack(id);
    expect(p.available, isTrue);
    expect(p.n, 1);
    expect(p.loader, Loader.fabric);
    expect(p.mcVersion, '1.21.1');
    expect(p.required, 1);
    expect(p.serverOnly, 1);
    expect(p.manual, 1);
    expect(p.fileName, 'Survival-1.mrpack');

    final mr = await bobT.send('GET', member.packUrl(id));
    expect(mr.status, 200);
    expect(mr.headers['content-type'], contains('modrinth'));
    final zip = await bobT.send('GET', member.packModsUrl(id));
    expect(zip.status, 200);
    expect(zip.headers['content-type'], contains('application/zip'));

    final f = await member.packFile(id);
    expect(f!.loader, 'fabric');
    expect(f.byFile['create-6.0.8.jar']!.side, 'both');
    expect(f.byFile['tweaks.jar']!.side, 'server');
    expect(f.byFile['tweaks.jar']!.source, 'manual');
  });

  test('eventi: pagine prima e dopo, flusso dal vivo', () async {
    final first = await member.events(after: 0, limit: 1000);
    expect(first.events, isNotEmpty);
    final last = first.last;
    final older = await member.events(before: last + 1, limit: 2);
    expect(older.events, hasLength(2));
    expect(older.events.first.seq, greaterThan(older.events.last.seq));
    expect(older.more, isTrue);

    final got = Completer<HubEvent>();
    final sub = member.eventStream(after: last).listen((e) {
      if (!got.isCompleted && e.type == EventType.spaceCreate) got.complete(e);
    }, onError: (Object _) {});
    await admin.createSpace('Dal vivo', Profile.generic);
    final e = await got.future.timeout(const Duration(seconds: 10));
    expect(e.seq, greaterThan(last));
    await sub.cancel();
  });
}
