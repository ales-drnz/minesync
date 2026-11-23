// App finta per gli scenari: stessa struttura a cartella di un bundle
// Flutter desktop (exe + lib/ + data/). Versione e comportamento si leggono da
// data/ accanto all'eseguibile, così un solo binario serve per tutte le
// versioni. Chiave pubblica incorporata in compilazione come nell'app vera:
//   dart compile exe -DMINESYNC_UPDATE_PUBKEY=<base64> test/support/fake_app.dart
//
// Dal launcher: MINESYNC_ROOT, MINESYNC_VERSION, MINESYNC_HEALTH_FILE,
// MINESYNC_SECONDARY. Dal test: MINESYNC_HUB (URL dell'hub),
// MINESYNC_APP_MODE = run | update, MINESYNC_TEST_HOOK = fase in cui fermarsi.
import 'dart:async';
import 'dart:io';

import 'package:minesync_launcher/update.dart';
import 'package:path/path.dart' as p;

const pubKey = String.fromEnvironment('MINESYNC_UPDATE_PUBKEY');

Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final mode = env['MINESYNC_APP_MODE'] ?? 'run';
  final hub = Uri.parse(env['MINESYNC_HUB'] ?? 'http://127.0.0.1:1/');

  final dir = p.dirname(Platform.resolvedExecutable);
  final version = (await File(p.join(dir, 'data', 'version.txt')).readAsString()).trim();
  final behavior = (await File(p.join(dir, 'data', 'behavior.txt')).readAsString()).trim();
  void log(String s) => stdout.writeln('[app $version] $s');
  log('avviata pid=$pid (behavior=$behavior, trial=${env['MINESYNC_TRIAL']})');

  if (env['MINESYNC_SECONDARY'] == '1') {
    // L'app vera qui chiede all'istanza attiva di mostrarsi ed esce.
    log('secondaria: esco');
    exit(0);
  }
  if (behavior == 'crash') {
    log('crash all\'avvio');
    exit(3);
  }
  if (behavior == 'hang') {
    log('bloccata prima di confermare l\'avvio');
    await Future<void>.delayed(const Duration(days: 1)); // un Timer tiene viva la VM
  }
  if (behavior == 'wait') {
    log('in attesa');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await File(env['MINESYNC_HEALTH_FILE']!).writeAsString(version);
    await Future<void>.delayed(const Duration(days: 1));
  }
  // Nell'app vera: dopo il primo frame disegnato.
  await Future<void>.delayed(const Duration(milliseconds: 150));
  final health = env['MINESYNC_HEALTH_FILE'];
  if (health != null) await File(health).writeAsString(version, flush: true);
  log('healthy');

  if (mode != 'update') exit(0);
  final root = env['MINESYNC_ROOT']!;
  final phase = env['MINESYNC_TEST_HOOK'];
  Future<void> hook(String at) async {
    if (at != phase) return;
    stdout.writeln('HOOK $at pid=$pid');
    await stdout.flush();
    await Future<void>.delayed(const Duration(days: 1)); // resta qui finché non viene ucciso
  }

  try {
    final (r, v) = await Stager(
      Install(root),
      version,
      pubKey,
      log: log,
      hook: hook,
    ).checkAndStage(hub.resolve('dl/'));
    log('RESULT ${r.name} $v');
    exit(r == UpdateOutcome.staged ? exitRestart : 0);
  } on SignatureException catch (e) {
    log('RESULT rejected-signature: $e');
  } on HashException catch (e) {
    log('RESULT rejected-hash: $e');
  } on UpdateException catch (e) {
    log('RESULT error: $e');
  }
  exit(0);
}
