// Supporto degli scenari: compila launcher (due build, per provarne
// l'auto-aggiornamento) e app finta, genera chiavi usa e getta, prepara
// rilasci firmati (buoni e manomessi) e installazioni di prova.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:minesync_launcher/update.dart';
import 'package:path/path.dart' as p;

import 'fake_hub.dart';

final isWin = Platform.isWindows;
final exeExt = isWin ? '.exe' : '';
final launcherName = 'minesync-launcher$exeExt';
final appExe = 'minesync_desktop$exeExt';
final platform = currentPlatform();

final class Harness {
  Harness._(this.work);

  final String work;
  late final String launcherB1, launcherB2, fakeApp, goodKey, evilKey, pubKey;

  String get releases => p.join(work, 'releases');
  String get bundles => p.join(work, 'bundles');

  static Future<Harness> build() async {
    final h = Harness._(Directory.systemTemp.createTempSync('ms_launcher_e2e').path);
    final bin = p.join(h.work, 'bin');
    await Directory(bin).create(recursive: true);
    final (good, pub) = await generateKeyPair();
    final (evil, _) = await generateKeyPair();
    h
      ..goodKey = good
      ..evilKey = evil
      ..pubKey = pub
      ..launcherB1 = p.join(bin, 'launcher_b1$exeExt')
      ..launcherB2 = p.join(bin, 'launcher_b2$exeExt')
      ..fakeApp = p.join(bin, appExe);
    final pkg = Directory.current.path; // dart test gira nella cartella del pacchetto
    await Future.wait([
      _compile(p.join(pkg, 'bin', 'minesync_launcher.dart'), h.launcherB1, ['LAUNCHER_BUILD=1']),
      _compile(p.join(pkg, 'bin', 'minesync_launcher.dart'), h.launcherB2, ['LAUNCHER_BUILD=2']),
      _compile(p.join(pkg, 'test', 'support', 'fake_app.dart'), h.fakeApp, [
        'MINESYNC_UPDATE_PUBKEY=$pub',
      ]),
    ]);
    await h._prepareReleases();
    return h;
  }

  Future<void> dispose() async {
    try {
      await Directory(work).delete(recursive: true);
    } on FileSystemException {
      // Windows: un processo ucciso può tenere aperto un file ancora per poco
    }
  }

  static Future<void> _compile(String src, String out, List<String> defines) async {
    final r = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      ...defines.map((d) => '-D$d'),
      '-o',
      out,
      src,
    ]);
    if (r.exitCode != 0) throw StateError('compilazione di $src: ${r.stdout}${r.stderr}');
  }

  /// Cartella con la forma di un bundle Flutter desktop: eseguibile, lib/
  /// (librerie native + symlink di versione), data/ (molti file piccoli),
  /// più il launcher da distribuire.
  Future<String> bundle(String version, String behavior, {String? launcher}) async {
    final dir = p.join(bundles, '$version-$behavior');
    if (await Directory(dir).exists()) return dir;
    final rnd = Random(version.hashCode);
    Uint8List bytes(int n) => Uint8List.fromList(List.generate(n, (_) => rnd.nextInt(256)));
    Future<void> put(String rel, List<int> data) async {
      final f = File(p.joinAll([dir, ...rel.split('/')]));
      await f.parent.create(recursive: true);
      await f.writeAsBytes(data);
    }

    await Directory(dir).create(recursive: true);
    await File(fakeApp).copy(p.join(dir, appExe));
    await put('lib/libapp.so', bytes(1 << 20));
    await put('lib/libflutter_linux_gtk.so', bytes(2 << 20));
    if (!isWin) await Link(p.join(dir, 'lib', 'libapp.so.1')).create('libapp.so');
    for (var i = 0; i < 60; i++) {
      await put('data/flutter_assets/assets/a$i.json', utf8.encode('{"i":$i,"v":"$version"}'));
    }
    await put('data/icudtl.dat', bytes(256 << 10));
    await put('data/version.txt', utf8.encode(version));
    await put('data/behavior.txt', utf8.encode(behavior));
    if (launcher != null) await File(launcher).copy(p.join(dir, launcherName));
    return dir;
  }

  /// Pubblica un rilascio in `releases/<name>/update/<platform>/`.
  Future<Manifest> publish(
    String name,
    String version,
    String behavior, {
    String? launcher,
    String? key,
  }) async => packRelease(
    seedB64: key ?? goodKey,
    version: version,
    platform: platform,
    entrypoint: appExe,
    launcher: launcher == null ? null : launcherName,
    src: await bundle(version, behavior, launcher: launcher),
    out: p.join(releases, name),
  );

  String rel(String name) => p.join(releases, name, 'update', platform);

  Future<void> _prepareReleases() async {
    await publish('1.0.0', '1.0.0', 'ok', launcher: launcherB1);
    await publish('1.1.0', '1.1.0', 'ok', launcher: launcherB2);
    await publish('1.2.0', '1.2.0', 'ok', launcher: launcherB2);
    await publish('0.9.0', '0.9.0', 'ok');
    await publish('1.5.0-crash', '1.5.0', 'crash');
    await publish('1.6.0-hang', '1.6.0', 'hang');
    await publish('1.1.0-evil', '1.1.0', 'ok', key: evilKey);

    // Manifest manomesso dopo la firma (versione cambiata, firma originale).
    await copyDir(p.join(releases, '1.1.0'), p.join(releases, '1.1.0-tampered'));
    final mt = File(p.join(rel('1.1.0-tampered'), 'manifest.json'));
    await mt.writeAsString((await mt.readAsString()).replaceFirst('"1.1.0"', '"1.1.1"'));

    // Firma non base64.
    await copyDir(p.join(releases, '1.1.0'), p.join(releases, '1.1.0-garbagesig'));
    await File(p.join(rel('1.1.0-garbagesig'), 'manifest.json.sig')).writeAsString('no!!\n');

    // Archivio alterato (stessa lunghezza, un byte cambiato) e troncato.
    for (final (name, trunc) in [('1.1.0-flipped', false), ('1.1.0-truncated', true)]) {
      await copyDir(p.join(releases, '1.1.0'), p.join(releases, name));
      final a = File(p.join(rel(name), 'minesync-1.1.0-$platform.tar.gz'));
      final b = await a.readAsBytes();
      if (trunc) {
        await a.writeAsBytes(b.sublist(0, b.length ~/ 2));
      } else {
        b[b.length ~/ 2] ^= 0xff;
        await a.writeAsBytes(b);
      }
    }

    // Manifest firmato correttamente ma con l'hash di un file interno errato:
    // l'archivio passa, l'estrazione deve fermarsi.
    await copyDir(p.join(releases, '1.1.0'), p.join(releases, '1.1.0-filehash'));
    final mf = File(p.join(rel('1.1.0-filehash'), 'manifest.json'));
    final j = jsonDecode(await mf.readAsString()) as Map<String, Object?>;
    final files = (j['files']! as List<Object?>).cast<Map<String, Object?>>();
    files.firstWhere((f) => (f['path']! as String).endsWith('icudtl.dat'))['sha256'] = '0' * 64;
    await writeSignedManifest(
      rel('1.1.0-filehash'),
      utf8.encode(const JsonEncoder.withIndent('  ').convert(j)),
      goodKey,
    );
  }

  /// "Installer": radice con launcher b1 e versione 1.0.0 come current.
  Future<Install> install(String name, {bool state = true}) async {
    final root = p.join(work, 'installs', name);
    await rmDir(root);
    await Directory(p.join(root, 'versions')).create(recursive: true);
    await File(launcherB1).copy(p.join(root, launcherName));
    final v = p.join(root, 'versions', '1.0.0');
    await copyDir(await bundle('1.0.0', 'ok', launcher: launcherB1), v);
    await File(p.join(rel('1.0.0'), 'manifest.json')).copy(p.join(v, versionManifestName));
    final inst = Install(root);
    if (state) await inst.writeState(InstallState(current: '1.0.0'));
    return inst;
  }

  /// L'hub ora offre il rilascio [name] (o niente se null).
  Future<void> serve(FakeHub hub, String? name) async {
    await rmDir(hub.root);
    await Directory(hub.root).create(recursive: true);
    if (name != null) await copyDir(p.join(releases, name), hub.root);
    hub.requests.clear();
  }
}

Future<void> rmDir(String path) async {
  if (await Directory(path).exists()) await Directory(path).delete(recursive: true);
}

Future<void> copyDir(String from, String to) async {
  await Directory(to).create(recursive: true);
  await for (final e in Directory(from).list(recursive: true, followLinks: false)) {
    final dest = p.join(to, p.relative(e.path, from: from));
    if (e is Link) {
      await Directory(p.dirname(dest)).create(recursive: true);
      await Link(dest).create(await e.target());
    } else if (e is File) {
      await Directory(p.dirname(dest)).create(recursive: true);
      await e.copy(dest);
    }
  }
}

/// Hash di tutto l'albero di una cartella (per dimostrare "nessuna corruzione").
Future<String> treeHash(String dir) async {
  final parts = <String>[];
  final list = await Directory(dir).list(recursive: true, followLinks: false).toList();
  list.sort((a, b) => a.path.compareTo(b.path));
  for (final e in list) {
    final rel = p.relative(e.path, from: dir);
    if (e is Link) parts.add('$rel -> ${await e.target()}');
    if (e is File) parts.add('$rel ${sha256.convert(await e.readAsBytes())}');
  }
  return sha256.convert(utf8.encode(parts.join('\n'))).toString();
}

Future<List<String>> versionsOf(Install inst) async {
  final d = Directory(inst.versionsDir);
  if (!await d.exists()) return [];
  return [await for (final e in d.list()) p.basename(e.path)]..sort();
}

/// Processo con l'output raccolto riga per riga.
final class Run {
  Run(this.proc) {
    for (final s in [proc.stdout, proc.stderr]) {
      s.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
        out.writeln(l);
        _lines.add(l);
      });
    }
  }

  final Process proc;
  final out = StringBuffer();
  final _lines = StreamController<String>.broadcast();

  Future<String> waitLine(RegExp re, {Duration timeout = const Duration(seconds: 60)}) {
    final m = re.firstMatch(out.toString());
    if (m != null) return Future.value(m[0]);
    return _lines.stream
        .firstWhere(re.hasMatch)
        .then((l) => re.firstMatch(l)![0]!)
        .timeout(timeout);
  }
}
