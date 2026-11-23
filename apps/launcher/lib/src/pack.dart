// Preparazione di un rilascio firmato: tar.gz della cartella dell'app,
// manifest con ogni file (dimensione, sha256, permessi o destinazione del
// symlink) e firma ed25519 dei byte esatti del manifest. Lo usano il tool di
// rilascio e i test.
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'install.dart';
import 'manifest.dart';
import 'tar.dart';

/// Impacchetta [src] e pubblica in `<out>/update/<platform>/` archivio,
/// manifest.json e manifest.json.sig, firmati col seme [seedB64].
Future<Manifest> packRelease({
  required String seedB64,
  required String version,
  required String platform,
  required String entrypoint,
  required String src,
  required String out,
  String? launcher,
}) async {
  final entries = <TarEntryIn>[];
  final files = <ManifestFile>[];
  final list = await Directory(src).list(recursive: true, followLinks: false).toList();
  list.sort((a, b) => a.path.compareTo(b.path));
  for (final e in list) {
    final rel = p.split(p.relative(e.path, from: src)).join('/');
    if (rel == versionManifestName) continue;
    if (e is Link) {
      final t = await e.target();
      entries.add(TarEntryIn.link(rel, t));
      files.add(ManifestFile(rel, 0, '', 511, t));
    } else if (e is File) {
      final data = await e.readAsBytes();
      // Su Windows non ci sono permessi POSIX: si scrive 0755 per tutti.
      final mode = Platform.isWindows ? 493 : (await e.stat()).mode & 0x1ff;
      entries.add(TarEntryIn.file(rel, data, mode: mode));
      files.add(ManifestFile(rel, data.length, sha256.convert(data).toString(), mode, null));
    }
  }
  final tgz = Uint8List.fromList(GZipCodec(level: 6).encode(buildTar(entries)));
  final name = 'minesync-$version-$platform.tar.gz';
  final m = Manifest(
    version: version,
    platform: platform,
    kind: PackageKind.archive,
    archiveName: name,
    archiveSize: tgz.length,
    archiveSha256: sha256.convert(tgz).toString(),
    entrypoint: entrypoint,
    launcher: launcher,
    files: files,
  );
  final dir = p.join(out, 'update', platform);
  await Directory(dir).create(recursive: true);
  await File(p.join(dir, name)).writeAsBytes(tgz, flush: true);
  await writeSignedManifest(dir, m.encode(), seedB64);
  return m;
}

/// Scrive manifest.json e la sua firma (manifest.json.sig) in [dir].
Future<void> writeSignedManifest(String dir, Uint8List bytes, String seedB64) async {
  await File(p.join(dir, 'manifest.json')).writeAsBytes(bytes, flush: true);
  final sig = await signBytes(bytes, seedB64);
  await File(p.join(dir, 'manifest.json.sig')).writeAsString('$sig\n', flush: true);
}
