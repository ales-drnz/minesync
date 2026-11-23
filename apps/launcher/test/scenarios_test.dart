// Scenari end-to-end dell'aggiornamento con processi veri: launcher e app
// finta compilati AOT, hub finto in-process, kill a metà, crash, blocchi.
// Scenari di aggiornamento (interrotti, alterati, da annullare) su Linux,
// Windows e macOS.
@Tags(['scenario'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:minesync_launcher/update.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_hub.dart';
import 'support/harness.dart';

late Harness h;
late FakeHub hub;

Future<Run> start(Install inst, {String mode = 'run', Map<String, String> env = const {}}) async =>
    Run(
      await Process.start(
        p.join(inst.root, launcherName),
        [],
        environment: {'MINESYNC_HUB': '${hub.url}', 'MINESYNC_APP_MODE': mode, ...env},
      ),
    );

Future<(int, String)> launch(
  Install inst, {
  String mode = 'run',
  Map<String, String> env = const {},
}) async {
  final r = await start(inst, mode: mode, env: env);
  final code = await r.proc.exitCode.timeout(const Duration(seconds: 120));
  await Future<void>.delayed(const Duration(milliseconds: 50)); // svuota le pipe
  return (code, r.out.toString());
}

/// Nessun effetto: stato, cartelle e albero di 1.0.0 come prima.
Future<void> expectUntouched(Install inst, String before, String why) async {
  final s = await inst.readState();
  expect(s.current, '1.0.0', reason: why);
  expect(s.pending, isNull, reason: why);
  expect(await versionsOf(inst), ['1.0.0'], reason: why);
  expect(await treeHash(inst.versionDir('1.0.0')), before, reason: '$why: albero di 1.0.0');
  expect(await Directory(inst.downloadsDir).exists(), isFalse, reason: '$why: download residui');
}

void main() {
  setUpAll(() async {
    h = await Harness.build();
    hub = await FakeHub.start(p.join(h.work, 'hub'));
  });
  tearDownAll(() async {
    await hub.close();
    await h.dispose();
  });

  test('update_ok: 1.0.0 -> 1.1.0 -> 1.2.0, launcher aggiornato, pulizia', () async {
    final inst = await h.install('update_ok');
    await h.serve(hub, '1.1.0');
    var (code, out) = await launch(inst, mode: 'update');
    expect(code, 0, reason: out);
    expect(out, contains('[app 1.0.0] RESULT staged 1.1.0'));
    expect(out, contains('[app 1.1.0] healthy'));
    expect(out, contains('PROMOSSA 1.1.0'));
    expect(hub.requested('/dl/update/$platform/manifest.json.sig'), isTrue);
    var s = await inst.readState();
    expect((s.current, s.previous, s.pending), ('1.1.0', '1.0.0', null));
    final st = await Process.run(p.join(inst.root, launcherName), ['--selftest']);
    expect(st.stdout as String, contains('build=2'));
    expect(await Directory('${inst.versionDir('1.1.0')}.partial').exists(), isFalse);

    await h.serve(hub, '1.2.0');
    (code, out) = await launch(inst, mode: 'update');
    s = await inst.readState();
    expect((code, s.current, s.previous), (0, '1.2.0', '1.1.0'), reason: out);
    expect(await versionsOf(inst), ['1.1.0', '1.2.0'], reason: 'tenuta una sola precedente');
    expect(await File(p.join(inst.root, '$launcherName.old')).exists(), isFalse);
    (code, out) = await launch(inst);
    expect(code, 0);
    expect(out, contains('[app 1.2.0] healthy'));
    expect(out, isNot(contains('provo')));
  });

  test('bad_signature: altra chiave, manifest modificato, firma illeggibile', () async {
    final inst = await h.install('bad_signature');
    final before = await treeHash(inst.versionDir('1.0.0'));
    for (final rel in ['1.1.0-evil', '1.1.0-tampered', '1.1.0-garbagesig']) {
      await h.serve(hub, rel);
      final (code, out) = await launch(inst, mode: 'update');
      expect(code, 0, reason: rel);
      expect(out, contains('RESULT rejected-signature'), reason: rel);
      expect(hub.requested('.tar.gz'), isFalse, reason: '$rel: archivio mai scaricato');
      await expectUntouched(inst, before, rel);
    }
  });

  test('bad_hash: archivio alterato o troncato, hash di un file errato', () async {
    final inst = await h.install('bad_hash');
    final before = await treeHash(inst.versionDir('1.0.0'));
    for (final rel in ['1.1.0-flipped', '1.1.0-truncated', '1.1.0-filehash']) {
      await h.serve(hub, rel);
      final (code, out) = await launch(inst, mode: 'update');
      expect(code, 0, reason: rel);
      expect(out, contains('RESULT rejected-hash'), reason: '$rel\n$out');
      expect(await Directory('${inst.versionDir('1.1.0')}.partial').exists(), isFalse);
      await expectUntouched(inst, before, rel);
    }
  });

  test('older_version: 0.9.0 o la stessa 1.0.0 vengono ignorate', () async {
    final inst = await h.install('older');
    final before = await treeHash(inst.versionDir('1.0.0'));
    for (final rel in ['0.9.0', '1.0.0']) {
      await h.serve(hub, rel);
      final (code, out) = await launch(inst, mode: 'update');
      expect(code, 0);
      expect(out, contains('RESULT notNewer'), reason: rel);
      expect(hub.requested('.tar.gz'), isFalse, reason: rel);
      await expectUntouched(inst, before, rel);
    }
  });

  for (final phase in ['download', 'extract', 'commit']) {
    test('kill_$phase: blackout a metà, la corrente parte, il retry riesce', () async {
      final inst = await h.install('kill_$phase');
      final before = await treeHash(inst.versionDir('1.0.0'));
      await h.serve(hub, '1.1.0');
      final r = await start(inst, mode: 'update', env: {'MINESYNC_TEST_HOOK': phase});
      final line = await r.waitLine(RegExp(r'HOOK \w+ pid=\d+'));
      // Equivalente a un blackout: SIGKILL sia all'app che al launcher.
      Process.killPid(int.parse(line.split('=').last), ProcessSignal.sigkill);
      r.proc.kill(ProcessSignal.sigkill);
      await r.proc.exitCode;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final s0 = await inst.readState();
      final vs0 = await versionsOf(inst);
      expect((s0.current, s0.pending), ('1.0.0', null));
      final residue = switch (phase) {
        'download' => await Directory(inst.downloadsDir).exists(),
        'extract' => vs0.contains('1.1.0.partial'),
        _ => vs0.contains('1.1.0'),
      };
      expect(residue, isTrue, reason: 'il kill è avvenuto davvero a metà: $vs0');
      expect(await treeHash(inst.versionDir('1.0.0')), before);

      var (code, out) = await launch(inst);
      expect(code, 0);
      expect(out, contains('[app 1.0.0] healthy'));
      expect(out, isNot(contains('provo')));

      (code, out) = await launch(inst, mode: 'update');
      final s = await inst.readState();
      expect((code, s.current), (0, '1.1.0'), reason: out);
      expect(await versionsOf(inst), ['1.0.0', '1.1.0']);
      expect(await Directory(inst.downloadsDir).exists(), isFalse);
    });
  }

  test('crash_rollback: la nuova esce con 3 due volte, si torna a 1.0.0', () async {
    final inst = await h.install('crash');
    await h.serve(hub, '1.5.0-crash');
    final (code, out) = await launch(inst, mode: 'update');
    expect(code, 0, reason: out);
    expect('tentativo'.allMatches(out).length, 2);
    expect(out, contains('ROLLBACK'));
    expect(RegExp(r'ROLLBACK[\s\S]*\[app 1\.0\.0\] healthy').hasMatch(out), isTrue);
    expect(out, contains('[app 1.0.0] RESULT knownBad'), reason: 'la 1.5.0 non si riscarica');
    final s = await inst.readState();
    expect((s.current, s.pending), ('1.0.0', null));
    expect(s.bad, ['1.5.0']);
    final (code2, out2) = await launch(inst);
    expect(code2, 0);
    expect(out2, contains('[app 1.0.0] healthy'));
    expect(out2, isNot(contains('provo')));
  });

  test('hang_rollback: niente marker healthy entro il timeout', () async {
    final inst = await h.install('hang');
    await h.serve(hub, '1.6.0-hang');
    final (code, out) = await launch(inst, mode: 'update', env: {'MINESYNC_HEALTH_TIMEOUT_S': '3'});
    expect(code, 0, reason: out);
    expect(out, contains('non ha confermato l\'avvio entro 3 s'));
    expect(out, contains('[app 1.0.0] healthy'));
    final s = await inst.readState();
    expect(s.current, '1.0.0');
    expect(s.bad, ['1.6.0']);
  });

  test('launcher_killed_during_trial: il contatore persiste, al terzo avvio rollback', () async {
    final inst = await h.install('launcher_killed');
    await h.serve(hub, '1.6.0-hang');
    for (var i = 1; i <= 2; i++) {
      final r = await start(inst, mode: 'update');
      await r.waitLine(RegExp(r'\[app 1\.6\.0\] bloccata'));
      final pidLine = await r.waitLine(RegExp(r'\[app 1\.6\.0\] avviata pid=\d+'));
      Process.killPid(int.parse(pidLine.split('=').last), ProcessSignal.sigkill);
      r.proc.kill(ProcessSignal.sigkill);
      await r.proc.exitCode;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final s = await inst.readState();
      expect((s.pending, s.pendingAttempts), ('1.6.0', i));
    }
    final (code, out) = await launch(inst);
    final s = await inst.readState();
    expect(code, 0, reason: out);
    expect(out, contains('ROLLBACK'));
    expect(out, contains('[app 1.0.0] healthy'));
    expect(s.current, '1.0.0');
    expect(s.bad, ['1.6.0']);
  });

  test('bootstrap: la versione del pacchetto più nuova viene installata', () async {
    final inst = await h.install('bootstrap', state: false);
    final boot = p.join(h.work, 'boot-1.2.0');
    await rmDir(boot);
    await copyDir(await h.bundle('1.2.0', 'ok'), boot);
    await File(p.join(h.rel('1.2.0'), 'manifest.json')).copy(p.join(boot, versionManifestName));
    // senza state.json e senza bootstrap: si adotta la 1.0.0 presente
    var (code, out) = await launch(inst);
    expect(code, 0, reason: out);
    expect(out, contains('adotto la versione installata 1.0.0'));
    expect((await inst.readState()).current, '1.0.0');
    // pacchetto nuovo con dentro la 1.2.0
    (code, out) = await launch(inst, env: {'MINESYNC_BOOTSTRAP_OVERRIDE': boot});
    expect(code, 0, reason: out);
    expect(out, contains('installo la versione del pacchetto 1.2.0'));
    expect(out, contains('[app 1.2.0] healthy'));
    final s = await inst.readState();
    expect((s.current, s.previous), ('1.2.0', '1.0.0'));
    expect(await treeHash(inst.versionDir('1.2.0')), await treeHash(boot));
  });

  test('second_launcher: avvia l\'app in modo secondario, stato invariato', () async {
    final inst = await h.install('second');
    await h.serve(hub, null);
    // la prima resta su finché il test non la ferma
    final dir = await h.bundle('1.0.0', 'wait', launcher: h.launcherB1);
    await rmDir(inst.versionDir('1.0.0'));
    await copyDir(dir, inst.versionDir('1.0.0'));
    await File(
      p.join(h.rel('1.0.0'), 'manifest.json'),
    ).copy(p.join(inst.versionDir('1.0.0'), versionManifestName));
    final first = await start(inst);
    await first.waitLine(RegExp(r'\[app 1\.0\.0\] in attesa'));
    final before = jsonEncode((await inst.readState()).toJson());
    final (code, out) = await launch(inst);
    expect(code, 0, reason: out);
    expect(out, contains('già in esecuzione'));
    expect(out, contains('[app 1.0.0] secondaria: esco'));
    expect(jsonEncode((await inst.readState()).toJson()), before);
    first.proc.kill(ProcessSignal.sigkill);
    await first.proc.exitCode;
    // il processo dell'app della prima istanza (figlio) va fermato a mano
    final pid = RegExp(r'avviata pid=(\d+)').firstMatch(first.out.toString())![1]!;
    Process.killPid(int.parse(pid), ProcessSignal.sigkill);
  });
}
