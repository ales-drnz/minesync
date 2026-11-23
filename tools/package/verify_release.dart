// Controlli di un rilascio desktop, per la CI e per chi firma:
//
//   dart run tools/package/verify_release.dart <outdir> [opzioni]
//     --pub <base64>        verifica le firme (manifest.json.sig, SHA256SUMS.sig)
//     --version <v>         ogni manifest deve essere di questa versione
//     --tree <platform> <dir>
//                           <dir> è una cartella di versione installata o
//                           inclusa in un pacchetto: .manifest.json uguale a
//                           update/<platform>/manifest.json e ogni file come
//                           dice il manifest (dimensione, sha256, symlink)
//     --pe-gui <exe>        <exe> è un eseguibile Windows del sottosistema GUI
//
// Esce con 1 al primo problema. Gira dalla radice del workspace (usa il
// package_config del workspace per minesync_launcher e cryptography: tools/
// non è un pacchetto, da qui l'ignore sotto).
//
// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:minesync_launcher/minesync_launcher.dart';
import 'package:minesync_launcher/update.dart';
import 'package:path/path.dart' as p;

Never fail(String msg) {
  stderr.writeln('ERRORE: $msg');
  exit(1);
}

void ok(String msg) => stdout.writeln('ok  $msg');

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    fail(
      'uso: verify_release.dart <outdir> [--pub b64] [--version v] [--tree platform dir] [--pe-gui exe]',
    );
  }
  final out = args.first;
  String? pub, version;
  final trees = <(String, String)>[];
  final guis = <String>[];
  for (var i = 1; i < args.length; i++) {
    String next() => i + 1 < args.length ? args[++i] : fail('valore mancante per ${args[i]}');
    switch (args[i]) {
      case '--pub':
        pub = next().trim();
      case '--version':
        version = next();
      case '--tree':
        final platform = next();
        trees.add((platform, next()));
      case '--pe-gui':
        guis.add(next());
      default:
        fail('opzione sconosciuta: ${args[i]}');
    }
  }

  final manifests = <String, (Uint8List, Manifest)>{};
  final updateDir = Directory(p.join(out, 'update'));
  if (await updateDir.exists()) {
    await for (final d in updateDir.list()) {
      if (d is! Directory) continue;
      final platform = p.basename(d.path);
      final bytes = await File(p.join(d.path, 'manifest.json')).readAsBytes();
      final Manifest m;
      if (pub != null) {
        final sigFile = File(p.join(d.path, 'manifest.json.sig'));
        if (!await sigFile.exists()) fail('$platform: manifest.json.sig mancante');
        try {
          m = await verifyManifest(bytes, await sigFile.readAsString(), pub);
        } on SignatureException catch (e) {
          fail('$platform: $e');
        }
        ok('$platform: firma del manifest');
      } else {
        m = Manifest.fromJson((jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>());
      }
      if (m.platform != platform) fail('$platform: il manifest dice ${m.platform}');
      if (version != null && m.version != version) {
        fail('$platform: versione ${m.version}, attesa $version');
      }
      final archive = File(p.join(d.path, m.archiveName));
      if (!await archive.exists()) fail('$platform: archivio ${m.archiveName} mancante');
      final data = await archive.readAsBytes();
      if (data.length != m.archiveSize) fail('$platform: dimensione dell\'archivio');
      if (sha256.convert(data).toString() != m.archiveSha256) {
        fail('$platform: sha256 dell\'archivio');
      }
      ok(
        '$platform: ${m.version}, ${m.archiveName} (${data.length} byte, ${m.files.length} file), entrypoint ${m.entrypoint}',
      );
      manifests[platform] = (bytes, m);
    }
  }

  final sums = File(p.join(out, 'SHA256SUMS'));
  if (await sums.exists()) {
    final bytes = await sums.readAsBytes();
    if (pub != null) {
      final sig = File('${sums.path}.sig');
      if (!await sig.exists()) fail('SHA256SUMS.sig mancante');
      if (!await _verifyRaw(bytes, await sig.readAsString(), pub)) fail('firma di SHA256SUMS');
      ok('firma di SHA256SUMS');
    }
    final listed = <String>{};
    for (final line in const LineSplitter().convert(utf8.decode(bytes))) {
      final m = RegExp(r'^([0-9a-f]{64})  (\S+)$').firstMatch(line);
      if (m == null) fail('riga di SHA256SUMS non valida: "$line"');
      final f = File(p.join(out, m[2]!));
      if (!await f.exists()) fail('SHA256SUMS: ${m[2]} mancante');
      if (sha256.convert(await f.readAsBytes()).toString() != m[1]) fail('SHA256SUMS: ${m[2]}');
      listed.add(m[2]!);
    }
    await for (final e in Directory(out).list()) {
      final name = p.basename(e.path);
      if (e is File && name.startsWith('MineSync-') && !listed.contains(name)) {
        fail('$name non è in SHA256SUMS');
      }
    }
    ok('SHA256SUMS: ${listed.length} file');
  }

  for (final (platform, dir) in trees) {
    final entry = manifests[platform];
    if (entry == null) fail('--tree: nessun manifest per $platform');
    final (bytes, m) = entry;
    final copy = File(p.join(dir, versionManifestName));
    if (!await copy.exists()) fail('$dir: $versionManifestName mancante');
    if (!_same(await copy.readAsBytes(), bytes)) {
      fail('$dir: $versionManifestName diverso dal manifest');
    }
    for (final f in m.files) {
      final path = p.joinAll([dir, ...f.path.split('/')]);
      if (f.isLink) {
        final l = Link(path);
        if (!await l.exists() || await l.target() != f.link) fail('$dir: symlink ${f.path}');
        continue;
      }
      final file = File(path);
      if (!await file.exists()) fail('$dir: manca ${f.path}');
      final data = await file.readAsBytes();
      if (data.length != f.size || sha256.convert(data).toString() != f.sha256) {
        fail('$dir: ${f.path} diverso dal manifest');
      }
      if (!Platform.isWindows && f.mode & 0x49 != 0 && (await file.stat()).mode & 0x49 == 0) {
        fail('$dir: ${f.path} non è eseguibile');
      }
    }
    final entryFile = File(p.joinAll([dir, ...m.entrypoint.split('/')]));
    if (!await entryFile.exists()) fail('$dir: entrypoint ${m.entrypoint} mancante');
    ok('$dir: ${m.files.length} file come nel manifest $platform');
  }

  for (final exe in guis) {
    final s = peSubsystem(await File(exe).readAsBytes());
    if (s != peSubsystemGui) fail('$exe: sottosistema PE $s, atteso GUI ($peSubsystemGui)');
    ok('$exe: sottosistema GUI');
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Future<bool> _verifyRaw(Uint8List bytes, String sigB64, String pubB64) async {
  try {
    final sig = base64.decode(sigB64.trim());
    final pub = base64.decode(pubB64.trim());
    return await Ed25519().verify(
      bytes,
      signature: Signature(sig, publicKey: SimplePublicKey(pub, type: KeyPairType.ed25519)),
    );
  } on FormatException {
    return false;
  }
}
