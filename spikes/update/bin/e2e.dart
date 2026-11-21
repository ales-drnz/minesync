// Prova end-to-end dell'auto-aggiornamento: compila launcher, app finta e
// tool di firma, prepara rilasci firmati, avvia un hub finto in-process ed
// esegue gli scenari. Exit code 0 solo se tutti i controlli passano.
//
//   dart run bin/e2e.dart            (da spikes/update/, lo lancia run.sh)
//
// Funziona su Linux, macOS e Windows; lo scenario AppImage solo su Linux, i
// symlink nel pacchetto solo fuori da Windows.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:spike_update/src/fake_hub.dart';
import 'package:spike_update/src/install.dart';

final isWin = Platform.isWindows;
final exeExt = isWin ? '.exe' : '';
final spikeDir = p.dirname(p.dirname(p.fromUri(Platform.script)));
final work = p.join(spikeDir, '.tmp', 'e2e');
final build = p.join(work, 'build');
final releases = p.join(work, 'releases');
final hubDir = p.join(work, 'hub');
final platform = currentPlatform();
final launcherName = 'minesync$exeExt';
final appExe = 'minesync_app$exeExt';

late String signtool, launcherB1, launcherB2, fakeApp, goodKey, evilKey, hubUrl;
final hubLog = <String>[];
final results = <(String, bool, String)>[];
final timings = <String, String>{};
late IOSink logSink;
String scenario = '';

void check(bool ok, String what) {
  results.add((scenario, ok, what));
  logSink.writeln('CHECK ${ok ? 'PASS' : 'FAIL'}: $what');
  if (!ok) stdout.writeln('    FAIL [$scenario] $what');
}

Future<void> main() async {
  await _rm(work);
  await Directory(p.join(work, 'logs')).create(recursive: true);
  logSink = File(p.join(work, 'logs', 'e2e.log')).openWrite();
  final sw = Stopwatch()..start();

  stdout.writeln('== build ($platform)');
  await _build();
  timings['build (4x dart compile exe)'] = '${sw.elapsed.inSeconds} s';

  stdout.writeln('== rilasci firmati');
  await _prepareReleases();

  final hub = await startFakeHub(hubDir, log: hubLog.add);
  hubUrl = 'http://127.0.0.1:${hub.port}/';

  final scenarios = <String, Future<void> Function()>{
    'update_ok': scUpdateOk,
    'bad_signature': scBadSignature,
    'bad_hash': scBadHash,
    'older_version': scOlder,
    'kill_download': () => scKill('download'),
    'kill_extract': () => scKill('extract'),
    'kill_commit': () => scKill('commit'),
    'crash_rollback': scCrash,
    'hang_rollback': scHang,
    'launcher_killed_during_trial': scLauncherKilled,
    if (Platform.isLinux) 'appimage': scAppImage,
  };
  for (final e in scenarios.entries) {
    scenario = e.key;
    logSink.writeln('\n===== ${e.key}');
    final t = Stopwatch()..start();
    try {
      await e.value();
    } catch (err, st) {
      check(false, 'eccezione: $err\n$st');
    }
    final n = results.where((r) => r.$1 == e.key).toList();
    final ok = n.every((r) => r.$2) && n.isNotEmpty;
    stdout.writeln('${ok ? 'PASS' : 'FAIL'}  ${e.key.padRight(30)} ${n.where((r) => r.$2).length}/${n.length} controlli  ${t.elapsedMilliseconds} ms');
  }
  await hub.close(force: true);

  stdout.writeln('\n== misure');
  timings.forEach((k, v) => stdout.writeln('  $k: $v'));
  final failed = results.where((r) => !r.$2).length;
  stdout.writeln('\n${results.length - failed}/${results.length} controlli passati, log: ${p.relative(p.join(work, 'logs'), from: spikeDir)}');
  await logSink.close();
  exit(failed == 0 ? 0 : 1);
}

// ---------------------------------------------------------------- build

Future<void> _compile(String src, String out, [List<String> defines = const []]) async {
  final r = await Process.run(Platform.resolvedExecutable,
      ['compile', 'exe', ...defines.map((d) => '-D$d'), '-o', out, p.join(spikeDir, src)],
      workingDirectory: spikeDir);
  if (r.exitCode != 0) throw StateError('compile $src: ${r.stdout}${r.stderr}');
}

Future<void> _build() async {
  await Directory(build).create(recursive: true);
  signtool = p.join(build, 'signtool$exeExt');
  launcherB1 = p.join(build, 'launcher_b1$exeExt');
  launcherB2 = p.join(build, 'launcher_b2$exeExt');
  fakeApp = p.join(build, appExe);
  await Future.wait([
    _compile('bin/signtool.dart', signtool),
    _compile('bin/launcher.dart', launcherB1, ['LAUNCHER_BUILD=1']),
    _compile('bin/launcher.dart', launcherB2, ['LAUNCHER_BUILD=2']),
  ]);
  goodKey = p.join(work, 'keys', 'good', 'signing.key');
  evilKey = p.join(work, 'keys', 'evil', 'signing.key');
  await _sign(['keygen', '--out', p.dirname(goodKey)]);
  await _sign(['keygen', '--out', p.dirname(evilKey)]);
  final pub = (await File(p.join(p.dirname(goodKey), 'signing.pub')).readAsString()).trim();
  await _compile('bin/fake_app.dart', fakeApp, ['MINESYNC_PUBKEY=$pub']);
}

Future<String> _sign(List<String> args) async {
  final r = await Process.run(signtool, args);
  if (r.exitCode != 0) throw StateError('signtool ${args.first}: ${r.stderr}');
  logSink.write(r.stdout);
  return r.stdout as String;
}

/// Bundle con la struttura di un'app Flutter desktop Linux: eseguibile,
/// lib/ (librerie native + symlink di versione), data/ (icudtl, flutter_assets
/// con molti file piccoli), più il launcher da distribuire.
Future<String> _bundle(String version, String behavior, {String? launcher}) async {
  final dir = p.join(work, 'bundles', '$version-$behavior');
  await _rm(dir);
  final rnd = Random(version.hashCode);
  Uint8List bytes(int n) => Uint8List.fromList(List.generate(n, (_) => rnd.nextInt(256)));
  Future<void> put(String rel, List<int> data) async {
    final f = File(p.join(dir, rel));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(data);
  }

  await Directory(dir).create(recursive: true);
  await File(fakeApp).copy(p.join(dir, appExe));
  await put('lib/libapp.so', bytes(6 << 20)); // AOT dell'app
  await put('lib/libflutter_linux_gtk.so', bytes(8 << 20)); // engine
  if (!isWin) await Link(p.join(dir, 'lib', 'libapp.so.1')).create('libapp.so');
  await put('data/icudtl.dat', bytes(1 << 20));
  for (var i = 0; i < 300; i++) {
    await put('data/flutter_assets/assets/a$i.json', utf8.encode('{"i":$i,"v":"$version"}'));
  }
  await put('data/version.txt', utf8.encode(version));
  await put('data/behavior.txt', utf8.encode(behavior));
  if (launcher != null) await File(launcher).copy(p.join(dir, launcherName));
  return dir;
}

Future<void> _publish(String name, String version, String behavior, {String? launcher, String? key}) async {
  final src = await _bundle(version, behavior, launcher: launcher);
  await _sign([
    'pack', '--key', key ?? goodKey, '--version', version, '--platform', platform,
    '--entry', appExe, if (launcher != null) ...['--launcher', launcherName],
    '--src', src, '--hub', p.join(releases, name),
  ]);
}

String _rel(String name) => p.join(releases, name, 'update', platform);

Future<void> _prepareReleases() async {
  final sw = Stopwatch()..start();
  await _publish('1.0.0', '1.0.0', 'ok', launcher: launcherB1);
  timings['pack+firma di un rilascio'] = '${sw.elapsedMilliseconds} ms '
      '(${(await File(p.join(_rel('1.0.0'), 'minesync-1.0.0-$platform.tar.gz')).length()) >> 10} KiB tar.gz, 304 file)';
  await _publish('1.1.0', '1.1.0', 'ok', launcher: launcherB2);
  await _publish('1.2.0', '1.2.0', 'ok', launcher: launcherB2);
  await _publish('0.9.0', '0.9.0', 'ok');
  await _publish('1.5.0-crash', '1.5.0', 'crash');
  await _publish('1.6.0-hang', '1.6.0', 'hang');
  await _publish('1.1.0-evil', '1.1.0', 'ok', key: evilKey);

  // Manifest manomesso dopo la firma (versione cambiata, firma originale).
  await _copyDir(p.join(releases, '1.1.0'), p.join(releases, '1.1.0-tampered'));
  final mt = File(p.join(_rel('1.1.0-tampered'), 'manifest.json'));
  await mt.writeAsString((await mt.readAsString()).replaceFirst('"1.1.0"', '"1.1.1"'));

  // Firma non base64.
  await _copyDir(p.join(releases, '1.1.0'), p.join(releases, '1.1.0-garbagesig'));
  await File(p.join(_rel('1.1.0-garbagesig'), 'manifest.json.sig')).writeAsString('non-una-firma!!\n');

  // Archivio alterato (stessa lunghezza, un byte cambiato) e troncato.
  for (final (name, trunc) in [('1.1.0-flipped', false), ('1.1.0-truncated', true)]) {
    await _copyDir(p.join(releases, '1.1.0'), p.join(releases, name));
    final a = File(p.join(_rel(name), 'minesync-1.1.0-$platform.tar.gz'));
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
  await _copyDir(p.join(releases, '1.1.0'), p.join(releases, '1.1.0-filehash'));
  final mf = File(p.join(_rel('1.1.0-filehash'), 'manifest.json'));
  final j = jsonDecode(await mf.readAsString()) as Map<String, dynamic>;
  final files = (j['files'] as List).cast<Map<String, dynamic>>();
  files.firstWhere((f) => (f['path'] as String).endsWith('icudtl.dat'))['sha256'] = '0' * 64;
  await mf.writeAsString(const JsonEncoder.withIndent('  ').convert(j));
  await _sign(['sign', '--key', goodKey, mf.path]);
}

// ------------------------------------------------------------ helpers

Future<void> _rm(String path) async {
  if (await Directory(path).exists()) await Directory(path).delete(recursive: true);
}

Future<void> _copyDir(String from, String to) async {
  await for (final e in Directory(from).list(recursive: true, followLinks: false)) {
    final dest = p.join(to, p.relative(e.path, from: from));
    if (e is Link) {
      await Link(dest).create(await e.target(), recursive: true);
    } else if (e is File) {
      await Directory(p.dirname(dest)).create(recursive: true);
      await e.copy(dest);
    }
  }
}

/// L'hub ora offre il rilascio [name] (o niente se null).
Future<void> _serve(String? name) async {
  await _rm(hubDir);
  await Directory(hubDir).create(recursive: true);
  if (name != null) await _copyDir(p.join(releases, name), hubDir);
  hubLog.clear();
}

/// "Installer": radice con launcher b1 e versione 1.0.0 come current.
Future<Install> _install() async {
  final root = p.join(work, 'installs', scenario);
  await _rm(root);
  await Directory(p.join(root, 'versions')).create(recursive: true);
  await File(launcherB1).copy(p.join(root, launcherName));
  final v = p.join(root, 'versions', '1.0.0');
  await _copyDir(p.join(work, 'bundles', '1.0.0-ok'), v);
  await File(p.join(_rel('1.0.0'), 'manifest.json')).copy(p.join(v, '.manifest.json'));
  final inst = Install(root);
  await inst.writeState(InstallState(current: '1.0.0'));
  return inst;
}

/// Hash di tutto l'albero di una versione (per dimostrare "nessuna corruzione").
Future<String> _treeHash(String dir) async {
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

class Run {
  final Process proc;
  final out = StringBuffer();
  final _lines = StreamController<String>.broadcast();
  Run(this.proc) {
    for (final s in [proc.stdout, proc.stderr]) {
      s.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
        out.writeln(l);
        logSink.writeln('  | $l');
        _lines.add(l);
      });
    }
  }

  Future<String> waitLine(RegExp re, {Duration timeout = const Duration(seconds: 60)}) {
    final m = re.firstMatch(out.toString());
    if (m != null) return Future.value(m[0]);
    return _lines.stream.firstWhere(re.hasMatch).then((l) => re.firstMatch(l)![0]!).timeout(timeout);
  }
}

Future<Run> _start(Install inst, {String mode = 'run', Map<String, String> env = const {}}) async {
  final proc = await Process.start(p.join(inst.root, launcherName), [], environment: {
    'MINESYNC_HUB': hubUrl,
    'MINESYNC_APP_MODE': mode,
    ...env,
  });
  return Run(proc);
}

Future<(int, String)> _launch(Install inst, {String mode = 'run', Map<String, String> env = const {}}) async {
  final r = await _start(inst, mode: mode, env: env);
  final code = await r.proc.exitCode.timeout(const Duration(seconds: 120));
  await Future<void>.delayed(const Duration(milliseconds: 50)); // svuota i pipe
  return (code, r.out.toString());
}

Future<List<String>> _versions(Install inst) async {
  final d = Directory(inst.versionsDir);
  return [await for (final e in d.list()) p.basename(e.path)]..sort();
}

Future<void> _expectUntouched(Install inst, String before, {String why = ''}) async {
  final s = await inst.readState();
  check(s.current == '1.0.0' && s.pending == null, 'stato invariato (current=${s.current}, pending=${s.pending}) $why');
  check((await _versions(inst)).join(',') == '1.0.0', 'versions/ contiene solo 1.0.0: ${await _versions(inst)}');
  check(await _treeHash(inst.versionDir('1.0.0')) == before, 'albero di 1.0.0 identico byte per byte');
  check(!await Directory(inst.downloadsDir).exists(), 'nessun download residuo');
}

// ------------------------------------------------------------ scenari

Future<void> scUpdateOk() async {
  final inst = await _install();
  await _serve('1.1.0');
  final sw = Stopwatch()..start();
  var (code, out) = await _launch(inst, mode: 'update');
  timings['update 1.0.0 -> 1.1.0 (scarica+verifica+estrai+riavvio+promozione)'] = '${sw.elapsedMilliseconds} ms';
  check(code == 0, 'launcher esce con 0 (era $code)');
  check(out.contains('[app 1.0.0] RESULT staged'), '1.0.0 prepara 1.1.0');
  check(out.contains('[app 1.1.0] healthy'), '1.1.0 parte dopo il riavvio richiesto (exit 75)');
  check(out.contains('PROMOSSA 1.1.0'), 'launcher promuove 1.1.0');
  var s = await inst.readState();
  check(s.current == '1.1.0' && s.previous == '1.0.0' && s.pending == null,
      'stato: current=${s.current} previous=${s.previous} pending=${s.pending}');
  final st = await Process.run(p.join(inst.root, launcherName), ['--selftest']);
  check((st.stdout as String).contains('build=2'), 'launcher aggiornato a build 2: ${(st.stdout as String).trim()}');
  check(!await Directory('${inst.versionDir('1.1.0')}.partial').exists(), 'nessun .partial residuo');

  await _serve('1.2.0');
  (code, out) = await _launch(inst, mode: 'update');
  s = await inst.readState();
  check(code == 0 && s.current == '1.2.0' && s.previous == '1.1.0', 'secondo update a 1.2.0 (current=${s.current})');
  final vs = await _versions(inst);
  check(vs.join(',') == '1.1.0,1.2.0', 'pulizia: tenuta una sola versione precedente $vs');
  check(!await File(p.join(inst.root, '$launcherName.old')).exists(), 'launcher .old rimosso al giro dopo');
  // Modalità solo avvio: parte 1.2.0 e basta.
  (code, out) = await _launch(inst);
  check(code == 0 && out.contains('[app 1.2.0] healthy') && !out.contains('provo'), 'avvio normale: 1.2.0 senza prova');
}

Future<void> scBadSignature() async {
  final inst = await _install();
  final before = await _treeHash(inst.versionDir('1.0.0'));
  for (final rel in ['1.1.0-evil', '1.1.0-tampered', '1.1.0-garbagesig']) {
    await _serve(rel);
    final (code, out) = await _launch(inst, mode: 'update');
    check(code == 0 && out.contains('RESULT rejected-signature'), '$rel: rifiutato per firma');
    check(!hubLog.any((l) => l.contains('.tar.gz')), '$rel: archivio mai scaricato (firma verificata prima)');
    await _expectUntouched(inst, before, why: rel);
  }
}

Future<void> scBadHash() async {
  final inst = await _install();
  final before = await _treeHash(inst.versionDir('1.0.0'));
  for (final rel in ['1.1.0-flipped', '1.1.0-truncated', '1.1.0-filehash']) {
    await _serve(rel);
    final (code, out) = await _launch(inst, mode: 'update');
    check(code == 0 && out.contains('RESULT rejected-hash'), '$rel: rifiutato per hash');
    check(!await Directory('${inst.versionDir('1.1.0')}.partial').exists(), '$rel: nessun .partial');
    await _expectUntouched(inst, before, why: rel);
  }
}

Future<void> scOlder() async {
  final inst = await _install();
  final before = await _treeHash(inst.versionDir('1.0.0'));
  for (final rel in ['0.9.0', '1.0.0']) {
    await _serve(rel);
    final (code, out) = await _launch(inst, mode: 'update');
    check(code == 0 && out.contains('RESULT notNewer'), 'hub con $rel: ignorato');
    check(!hubLog.any((l) => l.contains('.tar.gz')), 'hub con $rel: niente download');
    await _expectUntouched(inst, before, why: rel);
  }
}

Future<void> scKill(String phase) async {
  final inst = await _install();
  final before = await _treeHash(inst.versionDir('1.0.0'));
  await _serve('1.1.0');
  final r = await _start(inst, mode: 'update', env: {'MINESYNC_TEST_HOOK': phase});
  final line = await r.waitLine(RegExp(r'HOOK \w+ pid=\d+'));
  final appPid = int.parse(line.split('=').last);
  // Equivalente a un blackout: SIGKILL sia all'app che al launcher.
  Process.killPid(appPid, ProcessSignal.sigkill);
  r.proc.kill(ProcessSignal.sigkill);
  await r.proc.exitCode;
  await Future<void>.delayed(const Duration(milliseconds: 200));
  final s0 = await inst.readState();
  final vs0 = await _versions(inst);
  logSink.writeln('dopo kill: state=${jsonEncode(s0.toJson())} versions=$vs0');
  check(s0.current == '1.0.0' && s0.pending == null, 'dopo kill@$phase: current=1.0.0, pending=null');
  final residue = switch (phase) {
    'download' => await Directory(inst.downloadsDir).exists(),
    'extract' => vs0.contains('1.1.0.partial'),
    _ => vs0.contains('1.1.0'),
  };
  check(residue, 'il kill è avvenuto davvero a metà ($phase): residuo presente $vs0');
  check(await _treeHash(inst.versionDir('1.0.0')) == before, 'albero di 1.0.0 intatto');

  var (code, out) = await _launch(inst);
  check(code == 0 && out.contains('[app 1.0.0] healthy') && !out.contains('provo'), 'la versione corrente parte ancora');

  (code, out) = await _launch(inst, mode: 'update');
  final s = await inst.readState();
  check(code == 0 && s.current == '1.1.0', 'il retry dopo il kill aggiorna a 1.1.0 (current=${s.current})');
  final vs = await _versions(inst);
  check(vs.join(',') == '1.0.0,1.1.0' && !await Directory(inst.downloadsDir).exists(), 'residui ripuliti: $vs');
}

Future<void> scCrash() async {
  final inst = await _install();
  await _serve('1.5.0-crash');
  final sw = Stopwatch()..start();
  final (code, out) = await _launch(inst, mode: 'update');
  timings['crash x2 -> rollback -> 1.0.0 di nuovo su'] = '${sw.elapsedMilliseconds} ms (update incluso)';
  check(code == 0, 'launcher esce con 0 (era $code)');
  check('tentativo'.allMatches(out).length == 2 && out.contains('ROLLBACK'), '2 tentativi poi rollback');
  check(RegExp(r'ROLLBACK[\s\S]*\[app 1\.0\.0\] healthy').hasMatch(out), 'dopo il rollback riparte 1.0.0');
  check(out.contains('[app 1.0.0] RESULT knownBad'), '1.0.0 non riscarica la 1.5.0 (in "bad")');
  final s = await inst.readState();
  check(s.current == '1.0.0' && s.pending == null && s.bad.contains('1.5.0'), 'stato: current=1.0.0, bad=${s.bad}');
  final (code2, out2) = await _launch(inst);
  check(code2 == 0 && out2.contains('[app 1.0.0] healthy') && !out2.contains('provo'), 'avvio successivo: 1.0.0 direttamente');
}

Future<void> scHang() async {
  final inst = await _install();
  await _serve('1.6.0-hang');
  final sw = Stopwatch()..start();
  final (code, out) = await _launch(inst, mode: 'update', env: {'MINESYNC_HEALTH_TIMEOUT_S': '3'});
  timings['hang (timeout 3 s nel test, 60 s di default) -> rollback'] = '${sw.elapsedMilliseconds} ms (update incluso)';
  check(code == 0 && out.contains('non ha confermato l\'avvio entro 3 s'), 'timeout del marker healthy rilevato');
  final s = await inst.readState();
  check(s.current == '1.0.0' && s.bad.contains('1.6.0'), 'rollback a 1.0.0, 1.6.0 in bad');
  check(out.contains('[app 1.0.0] healthy'), '1.0.0 parte dopo il rollback');
}

/// Il contatore dei tentativi è persistito prima dell'avvio: anche se il
/// launcher muore (blackout) durante la prova, al terzo avvio c'è il rollback.
Future<void> scLauncherKilled() async {
  final inst = await _install();
  await _serve('1.6.0-hang');
  for (var i = 1; i <= 2; i++) {
    final r = await _start(inst, mode: 'update');
    await r.waitLine(RegExp(r'\[app 1\.6\.0\] bloccata'));
    final pidLine = await r.waitLine(RegExp(r'\[app 1\.6\.0\] avviata pid=\d+'));
    Process.killPid(int.parse(pidLine.split('=').last), ProcessSignal.sigkill);
    r.proc.kill(ProcessSignal.sigkill);
    await r.proc.exitCode;
    final s = await inst.readState();
    check(s.pending == '1.6.0' && s.pendingAttempts == i, 'dopo kill $i: pending=1.6.0 tentativi=${s.pendingAttempts}');
  }
  final (code, out) = await _launch(inst);
  final s = await inst.readState();
  check(code == 0 && out.contains('ROLLBACK') && out.contains('[app 1.0.0] healthy'), 'terzo avvio: rollback senza riprovare');
  check(s.current == '1.0.0' && s.bad.contains('1.6.0'), 'stato: current=1.0.0, bad=${s.bad}');
}

/// AppImage (file singolo): sostituzione di $APPIMAGE con rename mentre la
/// vecchia è in esecuzione. La "AppImage" qui è uno script ELF-agnostico con
/// zavorra: ciò che si prova è la sostituzione, non il formato.
Future<void> scAppImage() async {
  final dir = p.join(work, 'installs', 'appimage');
  await _rm(dir);
  await Directory(dir).create(recursive: true);
  final img = p.join(dir, 'MineSync-x86_64.AppImage');
  final rnd = Random(7);
  String fake(String v) => '#!/bin/sh\necho "appimage $v"\n[ "\$1" = sleep ] && sleep 30\nexit 0\n'
      '# ${base64.encode(List.generate(3 << 20, (_) => rnd.nextInt(256)))}\n';
  await File(img).writeAsString(fake('1.0.0'));
  chmod(img);
  final v2 = p.join(work, 'bundles', 'appimage-1.1.0', 'MineSync-x86_64.AppImage');
  await Directory(p.dirname(v2)).create(recursive: true);
  await File(v2).writeAsString(fake('1.1.0'));
  chmod(v2);
  final plat = '$platform-appimage';
  await _sign(['pack-file', '--key', goodKey, '--version', '1.1.0', '--platform', plat, '--file', v2,
    '--hub', p.join(releases, 'appimage-1.1.0')]);
  await _sign(['pack-file', '--key', evilKey, '--version', '1.1.0', '--platform', plat, '--file', v2,
    '--hub', p.join(releases, 'appimage-evil')]);

  Future<Run> upd({Map<String, String> env = const {}}) async => Run(await Process.start(fakeApp, [], environment: {
        'MINESYNC_HUB': hubUrl,
        'MINESYNC_APP_MODE': 'appimage-update',
        'APPIMAGE': img,
        'APPIMAGE_CURRENT_VERSION': '1.0.0',
        ...env,
      }));
  final orig = sha256.convert(await File(img).readAsBytes());
  Future<bool> same() async => sha256.convert(await File(img).readAsBytes()) == orig;

  await _serve('appimage-evil');
  var r = await upd();
  await r.proc.exitCode;
  check(r.out.toString().contains('rejected-signature') && await same(), 'firma sbagliata: \$APPIMAGE intatta');

  await _serve('appimage-1.1.0');
  r = await upd(env: {'MINESYNC_TEST_HOOK': 'download'});
  final line = await r.waitLine(RegExp(r'HOOK \w+ pid=\d+'));
  r.proc.kill(ProcessSignal.sigkill);
  await r.proc.exitCode;
  check(line.isNotEmpty && await same(), 'kill a metà download: \$APPIMAGE intatta');
  check(await File('$img.part').exists(), 'kill a metà download: resta solo il .part');

  final running = await Process.start(img, ['sleep']);
  await Future<void>.delayed(const Duration(milliseconds: 200));
  r = await upd();
  final code = await r.proc.exitCode;
  check(code == 0 && r.out.toString().contains('RESULT staged'), 'aggiornamento accettato mentre la vecchia gira');
  check(!await File('$img.part').exists(), '.part ripulito');
  final now = await Process.run(img, []);
  check((now.stdout as String).trim() == 'appimage 1.1.0', 'nuovo avvio: ${(now.stdout as String).trim()}');
  final old = await Process.run('$img.old', []);
  check((old.stdout as String).trim() == 'appimage 1.0.0', '.old conservata per rollback manuale');
  var alive = true;
  unawaited(running.exitCode.then((_) => alive = false));
  await Future<void>.delayed(const Duration(milliseconds: 100));
  check(alive, 'il processo vecchio è ancora vivo dopo la sostituzione');
  running.kill(ProcessSignal.sigkill);
}

void chmod(String path) => Process.runSync('chmod', ['755', path]);
