// App finta con la stessa struttura a cartella di un bundle Flutter desktop
// (exe + lib/*.so + data/flutter_assets/...). Versione e comportamento sono
// letti da data/ accanto all'eseguibile, così un solo binario compilato serve
// per tutte le versioni del test. Chiave pubblica incorporata in compilazione:
//   dart compile exe -DMINESYNC_PUBKEY=<base64> bin/fake_app.dart
//
// Variabili d'ambiente (dal launcher): MINESYNC_ROOT, MINESYNC_HEALTH_FILE.
// Dal test: MINESYNC_HUB (URL), MINESYNC_APP_MODE = run | update | appimage-update.
import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:spike_update/src/fsutil.dart';
import 'package:spike_update/src/install.dart';
import 'package:spike_update/src/manifest.dart';
import 'package:spike_update/src/updater.dart';

const pubKey = String.fromEnvironment('MINESYNC_PUBKEY');

Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final mode = env['MINESYNC_APP_MODE'] ?? 'run';
  final hub = env['MINESYNC_HUB'] ?? 'http://127.0.0.1:1';

  if (mode == 'appimage-update') {
    // Qui il processo fa la parte della AppImage in esecuzione.
    final img = env['APPIMAGE']!;
    final cur = env['APPIMAGE_CURRENT_VERSION']!;
    try {
      final r = await AppImageUpdater(img, cur, pubKey, log: (s) => stdout.writeln('[appimage] $s'))
          .checkAndReplace(hub);
      stdout.writeln('RESULT ${r.name}');
      exit(0);
    } on SignatureException catch (e) {
      stdout.writeln('RESULT rejected-signature: $e');
      exit(10);
    } on HashException catch (e) {
      stdout.writeln('RESULT rejected-hash: $e');
      exit(11);
    }
  }

  final dir = p.dirname(Platform.resolvedExecutable);
  final version = (await File(p.join(dir, 'data', 'version.txt')).readAsString()).trim();
  final behavior = (await File(p.join(dir, 'data', 'behavior.txt')).readAsString()).trim();
  void log(String s) => stdout.writeln('[app $version] $s');
  log('avviata pid=$pid (behavior=$behavior, trial=${env['MINESYNC_TRIAL']})');

  if (behavior == 'crash') {
    log('crash all\'avvio');
    exit(3);
  }
  if (behavior == 'hang') {
    log('bloccata prima di confermare l\'avvio');
    await Future<void>.delayed(const Duration(days: 1)); // un Timer tiene viva la VM
  }
  // Nell'app vera: dopo il primo frame e l'inizializzazione del motore.
  await Future<void>.delayed(const Duration(milliseconds: 150));
  final health = env['MINESYNC_HEALTH_FILE'];
  if (health != null) await writeAtomic(health, version.codeUnits);
  log('healthy');

  if (mode != 'update') exit(0);
  final root = env['MINESYNC_ROOT']!;
  try {
    final r = await Updater(Install(root), version, pubKey, log: log).checkAndStage(hub);
    log('RESULT ${r.name}');
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
