// Preparazione degli aggiornamenti nello stesso processo, contro un hub
// finto: pacchetti malformati o ostili che non devono mai lasciare tracce.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:minesync_launcher/src/tar.dart';
import 'package:minesync_launcher/update.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_hub.dart';

const plat = 'test-x64';

void main() {
  late Directory tmp;
  late FakeHub hub;
  late String seed, pub;
  late Install inst;

  setUpAll(() async => (seed, pub) = await generateKeyPair());
  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('ms_stager');
    hub = await FakeHub.start(p.join(tmp.path, 'hub'));
    inst = Install(p.join(tmp.path, 'root'));
    await Directory(inst.root).create();
    await inst.writeState(InstallState(current: '0.1.0'));
  });
  tearDown(() async {
    await hub.close();
    tmp.deleteSync(recursive: true);
  });

  Stager stager() => Stager(inst, '0.1.0', pub, platform: plat);

  /// Pubblica un pacchetto costruito a mano: [entries] nel tar, [files] nel
  /// manifest (di default quelli del tar).
  Future<void> publish(List<TarEntryIn> entries, {List<ManifestFile>? files}) async {
    final tgz = Uint8List.fromList(gzip.encode(buildTar(entries)));
    final m = Manifest(
      version: '0.2.0',
      platform: plat,
      kind: PackageKind.archive,
      archiveName: 'a.tar.gz',
      archiveSize: tgz.length,
      archiveSha256: sha256.convert(tgz).toString(),
      entrypoint: 'app',
      files:
          files ??
          [
            for (final e in entries)
              e.linkTarget != null
                  ? ManifestFile(e.path, 0, '', 511, e.linkTarget)
                  : ManifestFile(
                      e.path,
                      e.data!.length,
                      sha256.convert(e.data!).toString(),
                      e.mode,
                      null,
                    ),
          ],
    );
    final dir = p.join(hub.root, 'update', plat);
    await Directory(dir).create(recursive: true);
    await File(p.join(dir, 'a.tar.gz')).writeAsBytes(tgz);
    await writeSignedManifest(dir, m.encode(), seed);
  }

  Future<void> expectClean() async {
    final s = await inst.readState();
    expect(s.pending, isNull);
    final vd = Directory(inst.versionsDir);
    expect(vd.existsSync() ? vd.listSync() : const <FileSystemEntity>[], isEmpty);
    expect(await Directory(inst.downloadsDir).exists(), isFalse);
  }

  TarEntryIn f(String path, [String body = 'x']) =>
      TarEntryIn.file(path, Uint8List.fromList(utf8.encode(body)), mode: 493);

  test('pacchetto buono: estratto, manifest copiato, pending impostata', () async {
    await publish([f('app'), f('data/a.txt', 'ciao')]);
    final (r, v) = await stager().checkAndStage(hub.url.resolve('dl/'));
    expect((r, v), (UpdateOutcome.staged, '0.2.0'));
    expect(File(p.join(inst.versionDir('0.2.0'), 'data', 'a.txt')).readAsStringSync(), 'ciao');
    expect(await inst.entrypoint('0.2.0'), p.join(inst.versionDir('0.2.0'), 'app'));
    expect((await inst.readState()).pending, '0.2.0');
    final (again, _) = await stager().checkAndStage(hub.url.resolve('dl/'));
    expect(again, UpdateOutcome.alreadyStaged);
  });

  test('percorsi fuori dalla cartella rifiutati', () async {
    for (final bad in ['../evil', '/abs', 'a/../../evil', r'c:\x', 'a\\b']) {
      await publish([f('app'), f(bad)]);
      await expectLater(
        stager().checkAndStage(hub.url.resolve('dl/')),
        throwsA(isA<UpdateException>()),
        reason: bad,
      );
      await expectClean();
    }
  });

  test('symlink che esce dall\'albero, o scrittura attraverso un symlink', () async {
    if (Platform.isWindows) return; // su Windows i symlink sono rifiutati a priori
    await publish([f('app'), TarEntryIn.link('lib/x', '../../etc')]);
    await expectLater(
      stager().checkAndStage(hub.url.resolve('dl/')),
      throwsA(isA<UpdateException>()),
    );
    await expectClean();
    await publish([f('app'), TarEntryIn.link('lib', 'data'), f('lib/y')]);
    await expectLater(
      stager().checkAndStage(hub.url.resolve('dl/')),
      throwsA(isA<UpdateException>()),
    );
    await expectClean();
  });

  test('voci non nel manifest, mancanti, duplicate o di dimensione diversa', () async {
    final app = ManifestFile('app', 1, sha256.convert(utf8.encode('x')).toString(), 493, null);
    final other = ManifestFile('b', 1, sha256.convert(utf8.encode('x')).toString(), 420, null);
    final reserved = ManifestFile(versionManifestName, 1, '', 420, null);
    final cases = <(String, List<TarEntryIn>, List<ManifestFile>)>[
      ('voce in più', [f('app'), f('b')], [app]),
      ('voce mancante', [f('app')], [app, other]),
      ('maiuscole', [f('app'), f('b')], [app, other, ManifestFile('B', 1, '', 420, null)]),
      ('dimensione', [f('app', 'xx')], [app]),
      ('riservata', [f('app'), f(versionManifestName)], [app, reserved]),
    ];
    for (final (why, entries, files) in cases) {
      await publish(entries, files: files);
      await expectLater(
        stager().checkAndStage(hub.url.resolve('dl/')),
        throwsA(isA<UpdateException>()),
        reason: why,
      );
      await expectClean();
    }
  });

  test('manifest di un\'altra piattaforma rifiutato anche se firmato', () async {
    await publish([f('app')]);
    final src = Directory(p.join(hub.root, 'update', plat));
    await src.rename(p.join(hub.root, 'update', 'altro-x64'));
    await expectLater(
      Stager(inst, '0.1.0', pub, platform: 'altro-x64').checkAndStage(hub.url.resolve('dl/')),
      throwsA(isA<SignatureException>()),
    );
    await expectClean();
  });

  test('hub senza aggiornamenti: errore HTTP, niente scritto', () async {
    await expectLater(
      stager().checkAndStage(hub.url.resolve('dl/')),
      throwsA(isA<UpdateException>()),
    );
    await expectClean();
  });
}
