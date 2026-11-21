// Tool di firma dei rilasci (equivalente Dart di scripts/sign).
//
//   signtool keygen --out <dir>             -> signing.key (seme, 0600), signing.pub
//   signtool pack --key <signing.key> --version 1.2.3 --platform linux-x64 \
//        --entry minesync [--launcher launcher] --src <bundle> --hub <dir>
//                                           -> <hub>/update/<platform>/{tar.gz, manifest.json, .sig}
//   signtool pack-file --key K --version V --platform linux-x64-appimage --file F --hub <dir>
//   signtool sign --key K <file>            -> <file>.sig
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:spike_update/src/fsutil.dart';
import 'package:spike_update/src/manifest.dart';
import 'package:spike_update/src/tar.dart';

Never usage() {
  stderr.writeln('uso: signtool keygen|pack|pack-file|sign ... (vedi sorgente)');
  exit(64);
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) usage();
  String opt(String k) {
    final i = args.indexOf(k);
    if (i < 0 || i + 1 >= args.length) usage();
    return args[i + 1];
  }

  String? optional(String k) {
    final i = args.indexOf(k);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  switch (args[0]) {
    case 'keygen':
      final out = opt('--out');
      await Directory(out).create(recursive: true);
      final (seed, pub) = await generateKeyPair();
      final keyPath = p.join(out, 'signing.key');
      await File(keyPath).writeAsString('$seed\n');
      chmodPosix(keyPath, 384); // 0600
      await File(p.join(out, 'signing.pub')).writeAsString('$pub\n');
      stdout.writeln(pub);
    case 'sign':
      final f = args.last;
      final sig = await signBytes(await File(f).readAsBytes(), await File(opt('--key')).readAsString());
      await File('$f.sig').writeAsString('$sig\n');
    case 'pack':
      await pack(opt('--key'), opt('--version'), opt('--platform'), opt('--entry'), optional('--launcher'),
          opt('--src'), opt('--hub'));
    case 'pack-file':
      await packFile(opt('--key'), opt('--version'), opt('--platform'), opt('--file'), opt('--hub'));
    default:
      usage();
  }
}

Future<void> pack(String key, String version, String platform, String entry, String? launcher, String src,
    String hub) async {
  final entries = <TarEntryIn>[];
  final files = <ManifestFile>[];
  final list = await Directory(src).list(recursive: true, followLinks: false).toList();
  list.sort((a, b) => a.path.compareTo(b.path));
  for (final e in list) {
    final rel = p.split(p.relative(e.path, from: src)).join('/');
    if (e is Link) {
      final t = await e.target();
      entries.add(TarEntryIn.link(rel, t));
      files.add(ManifestFile(rel, 0, '', 511, t));
    } else if (e is File) {
      final data = await e.readAsBytes();
      final mode = (await e.stat()).mode & 0x1ff;
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
    entrypoint: entry,
    launcher: launcher,
    files: files,
  );
  await _publish(hub, platform, name, tgz, m, key);
}

Future<void> packFile(String key, String version, String platform, String file, String hub) async {
  final data = await File(file).readAsBytes();
  final name = p.basename(file);
  final m = Manifest(
    version: version,
    platform: platform,
    kind: PackageKind.file,
    archiveName: name,
    archiveSize: data.length,
    archiveSha256: sha256.convert(data).toString(),
    entrypoint: name,
  );
  await _publish(hub, platform, name, data, m, key);
}

Future<void> _publish(String hub, String platform, String name, Uint8List payload, Manifest m, String key) async {
  final dir = p.join(hub, 'update', platform);
  await Directory(dir).create(recursive: true);
  await File(p.join(dir, name)).writeAsBytes(payload, flush: true);
  final bytes = m.encode();
  await File(p.join(dir, 'manifest.json')).writeAsBytes(bytes, flush: true);
  final sig = await signBytes(bytes, await File(key).readAsString());
  await File(p.join(dir, 'manifest.json.sig')).writeAsString('$sig\n', flush: true);
  stdout.writeln('pubblicato ${m.version} ($platform): $name ${payload.length} byte, ${m.files.length} file');
}
