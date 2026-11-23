// Download e aggiornamento automatico da MINESYNC_DL (protocol.md,
// "Downloads (/dl) and self-update"; B-DL-01).
import 'dart:convert';
import 'dart:io';

import 'package:minesync_hub/minesync_hub.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:test/test.dart';

import 'support.dart';
import 'web_support.dart';

void main() {
  late Directory dl;
  late Directory outside;
  late TestHub t;

  const exe = 'minesync-0.1.0-windows-x64.exe';
  const deb = 'minesync_0.1.0_amd64.deb';
  const dmg = 'minesync-0.1.0-macos-universal.dmg';
  const appimage = 'minesync-0.1.0-rc.2-aarch64.AppImage';
  final exeBytes = List.generate(1000, (i) => i % 251);
  final exeSum = 'ab' * 32;
  // byte esatti firmati: spazi e a capo devono restare quelli
  const manifest = '{\n  "schema": 1,\n  "app": "minesync-desktop",\n  "version": "0.1.1"\n}';
  final archive = List.generate(4096, (i) => i % 7);

  setUp(() async {
    dl = await Directory.systemTemp.createTemp('minesync-dl-');
    outside = await Directory.systemTemp.createTemp('minesync-dl-out-');
    await writeTree(outside, {'secret.exe': 'segreto', 'secret.txt': 'segreto'});
    await writeTree(dl, {
      exe: exeBytes,
      deb: 'deb',
      dmg: 'dmg',
      appimage: 'appimage',
      'readme.txt': 'non elencato',
      '.hidden.exe': 'nascosto',
      'SHA256SUMS': '$exeSum  $exe\n${'cd' * 32} *$deb\nriga non valida\n',
      'SHA256SUMS.sig': 'firma',
      'update/linux-x64/manifest.json': manifest,
      'update/linux-x64/manifest.json.sig': 'c2ln',
      'update/linux-x64/minesync-0.1.1-linux-x64.tar.gz': archive,
      'update/windows-x64/manifest.json': '{"version": "0.1.0"}',
      'update/macos-arm64/manifest.json': 'non è JSON',
    });
    await Link('${dl.path}/evil.exe').create('${outside.path}/secret.exe');
    await Link('${dl.path}/update/linux-x64/leak.tar.gz').create('${outside.path}/secret.txt');
    await Link('${dl.path}/inside.deb').create('${dl.path}/$deb');
    t = await startHub(dl: dl.path);
  });
  tearDown(() async {
    await t.close();
    await dl.delete(recursive: true);
    await outside.delete(recursive: true);
  });

  group('elenco', () {
    test('B-DL-01 GET /api/v1/dl: solo i pacchetti, ordinati, con somme e aggiornamenti', () async {
      final r = await t.get('/dl');
      expect(r.status, 200);
      final l = DlListing.fromJson(r.json);
      expect(l.files.map((f) => f.name), [exe, dmg, 'inside.deb', appimage, deb]);
      final w = l.files.first;
      expect(w.os, DlOs.windows);
      expect(w.arch, 'x64');
      expect(w.version, '0.1.0');
      expect(w.size, exeBytes.length);
      expect(w.sha256, exeSum);
      final a = l.files[3];
      expect((a.os, a.arch, a.version, a.sha256), (DlOs.linux, 'arm64', '0.1.0-rc.2', null));
      expect(l.files[4].sha256, 'cd' * 32);
      expect(l.files[4].arch, 'x64');
      expect(l.files[1].arch, 'universal');
      expect(l.signedSums, isTrue);
      expect(l.updates.map((u) => (u.platform, u.version, u.signed)), [
        ('linux-x64', '0.1.1', true),
        ('windows-x64', '0.1.0', false),
      ]);
      final names = jsonEncode(r.json);
      for (final hidden in ['SHA256SUMS', 'readme.txt', '.hidden.exe', 'evil.exe', 'update/']) {
        expect(names, isNot(contains('"$hidden')), reason: hidden);
      }
    });

    test('il servizio per GET /system: piattaforme firmate o no', () async {
      final u = await t.hub.downloads.updates();
      expect({for (final c in u) c.platform: c.signed}, {'linux-x64': true, 'windows-x64': false});
    });

    test('nomi: sistema, architettura e versione', () {
      expect(dlOsOf('a.MSI'), DlOs.windows);
      expect(dlOsOf('a.pkg'), DlOs.macos);
      expect(dlOsOf('a.rpm'), DlOs.linux);
      expect(dlOsOf('minesync-0.1.0-macos-arm64.tar.gz'), DlOs.macos);
      expect(dlOsOf('MineSync-0.1.0-linux-x64-cli.tar.gz'), isNull);
      expect(dlOsOf('MineSync-0.1.0-windows-x64-cli.zip'), isNull);
      expect(dlOsOf('a.tar.gz'), DlOs.linux);
      expect(dlOsOf('a.zip'), isNull);
      expect(dlArchOf('minesync-0.1.0-1.x86_64.rpm'), 'x64');
      expect(dlArchOf('minesync-arm64.dmg'), 'arm64');
      expect(dlArchOf('minesync-ax64b.exe'), isNull);
      expect(dlVersionOf('MineSync-v1.2.3-x64.exe'), '1.2.3');
      expect(dlVersionOf('minesync.exe'), isNull);
      expect(dlNameOk('a-b_c.d+e'), isTrue);
      for (final bad in ['', '.', '..', '.x', 'a/b', r'a\b', 'a b', 'à']) {
        expect(dlNameOk(bad), isFalse, reason: bad);
      }
    });

    test('senza MINESYNC_DL: elenco vuoto e /dl/* 404', () async {
      final h = await startHub();
      addTearDown(h.close);
      final l = DlListing.fromJson((await h.get('/dl')).json);
      expect(l.files, isEmpty);
      expect(l.updates, isEmpty);
      expect((await fetch(h, '/dl/$exe')).status, 404);
    });
  });

  group('file', () {
    test('B-DL-01 pacchetto come allegato; SHA256SUMS in chiaro senza allegato', () async {
      final r = await fetch(t, '/dl/$exe');
      expect(r.status, 200);
      expect(r.bytes, exeBytes);
      expect(r.headers.value('content-disposition'), 'attachment; filename="$exe"');
      expect(r.headers.value('cache-control'), 'no-cache');
      expect(r.headers.value('x-content-type-options'), 'nosniff');
      final s = await fetch(t, '/dl/SHA256SUMS');
      expect(s.status, 200);
      expect(s.headers.contentType.toString(), 'text/plain; charset=utf-8');
      expect(s.headers.value('content-disposition'), isNull);
      expect((await fetch(t, '/dl/SHA256SUMS.sig')).status, 200);
    });

    test('aggiornamento come lo legge il launcher: byte esatti, tipi, no-cache + ETag', () async {
      final m = await fetch(t, '/dl/update/linux-x64/manifest.json');
      expect(m.status, 200);
      expect(utf8.decode(m.bytes), manifest);
      expect(m.headers.contentType.toString(), 'application/json; charset=utf-8');
      expect(m.headers.value('cache-control'), 'no-cache');
      expect(m.headers.value('content-disposition'), isNull);
      final etag = m.headers.value('etag')!;
      final again = await fetch(
        t,
        '/dl/update/linux-x64/manifest.json',
        headers: {'If-None-Match': etag},
      );
      expect(again.status, 304);
      final sig = await fetch(t, '/dl/update/linux-x64/manifest.json.sig');
      expect(utf8.decode(sig.bytes), 'c2ln');
      expect(sig.headers.contentType.toString(), 'text/plain; charset=utf-8');
      final a = await fetch(t, '/dl/update/linux-x64/minesync-0.1.1-linux-x64.tar.gz');
      expect(a.bytes, archive);
      expect(a.headers.contentType.toString(), 'application/gzip');
      expect(a.headers.value('content-disposition'), isNull);
    });

    test('Range: 206 con Content-Range, suffisso, 416 fuori misura; HEAD', () async {
      const path = '/dl/update/linux-x64/minesync-0.1.1-linux-x64.tar.gz';
      final r = await fetch(t, path, headers: {'Range': 'bytes=100-199'});
      expect(r.status, 206);
      expect(r.bytes, archive.sublist(100, 200));
      expect(r.headers.value('content-range'), 'bytes 100-199/4096');
      final s = await fetch(t, path, headers: {'Range': 'bytes=-10'});
      expect(s.bytes, archive.sublist(4086));
      final o = await fetch(t, path, headers: {'Range': 'bytes=5000-'});
      expect(o.status, 416);
      expect(o.headers.value('content-range'), 'bytes */4096');
      final h = await fetch(t, path, method: 'HEAD');
      expect(h.status, 200);
      expect(h.headers.contentLength, 4096);
      expect(h.headers.value('accept-ranges'), 'bytes');
    });

    test('chi non è membro: 401', () async {
      final r = await fetch(t, '/dl/$exe', from: '127.0.0.9');
      expect(r.status, 401);
      expect(r.code, 'unauthenticated');
      expect((await fetch(t, '/dl/update/linux-x64/manifest.json', from: '127.0.0.9')).status, 401);
    });

    test('symlink fuori dalla cartella, cartelle, nomi non validi, traversal: 404', () async {
      for (final p in [
        '/dl/evil.exe',
        '/dl/update/linux-x64/leak.tar.gz',
        '/dl/update',
        '/dl/update/linux-x64',
        '/dl/readme.txt',
        '/dl/.hidden.exe',
        '/dl/update/linux-x64/missing.tar.gz',
        '/dl/a/b',
        '/dl/update/linux-x64/manifest.json/x',
      ]) {
        final r = await fetch(t, p);
        expect(r.status, 404, reason: p);
        expect(utf8.decode(r.bytes), isNot(contains('segreto')), reason: p);
      }
      // il symlink che resta dentro si serve
      expect((await fetch(t, '/dl/inside.deb')).status, 200);
      for (final p in [
        '/dl/..%2F..%2Fetc%2Fpasswd',
        '/dl/update/..%2F..%2FSHA256SUMS',
        '/dl/update/%2e%2e/%2e%2e/$exe',
        '/dl/update/linux-x64/..%5Cmanifest.json',
      ]) {
        final (status, text) = await rawGet(t, p);
        expect(status, isNot(200), reason: p);
        expect(text, isNot(contains('segreto')), reason: p);
      }
    });

    test('solo GET/HEAD, senza bisogno di X-MineSync', () async {
      final p = await fetch(t, '/dl/$exe', method: 'DELETE', headers: {'X-MineSync': '1'});
      expect(p.status, 404);
      expect(File('${dl.path}/$exe').existsSync(), isTrue);
    });
  });
}
