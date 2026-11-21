// Launcher: l'unico eseguibile che l'utente avvia. Sceglie la versione,
// la avvia, ne sorveglia il primo avvio e fa rollback se non conferma.
//
// Regole:
//  - se c'è una "pending", la prova: prima di avviarla incrementa e PERSISTE
//    pendingAttempts (così conta anche un crash del launcher o un blackout);
//  - la pending è promossa a current quando scrive run/healthy-<v> col proprio
//    numero di versione;
//  - se esce prima del marker, si riprova fino a maxTrialAttempts; se non
//    scrive il marker entro il timeout (60 s) la si uccide: in entrambi i casi
//    rollback = la si mette in "bad" e si avvia current;
//  - exit code 75 dall'app = "riavviami" (ha preparato un aggiornamento);
//  - dopo una promozione: pulizia (si tengono current + previous) ed
//    eventuale aggiornamento del launcher stesso.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'fsutil.dart';
import 'install.dart';

const launcherBuild = int.fromEnvironment('LAUNCHER_BUILD', defaultValue: 1);
const launcherProtocol = 1;

class Launcher {
  final Install inst;
  final String selfPath;
  final Duration healthTimeout;
  final void Function(String) log;

  Launcher(this.inst, this.selfPath, {required this.healthTimeout, void Function(String)? log})
      : log = log ?? ((s) => stdout.writeln('[launcher b$launcherBuild] $s'));

  Future<int> run(List<String> args) async {
    // Una sola istanza: il lock dura quanto il processo.
    final instLock = await File(p.join(inst.root, 'launcher.lock')).open(mode: FileMode.append);
    try {
      await instLock.lock(FileLock.exclusive);
    } on FileSystemException {
      log('già in esecuzione'); // nel prodotto: porta in primo piano l'istanza attiva
      return 2;
    }
    // Residui di un aggiornamento del launcher (su Windows il vecchio exe
    // non si cancella finché gira: lo si fa al giro dopo).
    await rmrf('$selfPath.old');

    while (true) {
      final pick = await _pick();
      if (pick == null) {
        log('nessuna versione avviabile: installazione da riparare');
        return 1;
      }
      final (v, trial) = pick;
      final code = await _runVersion(v, trial, args);
      if (code == null) continue; // rollback fatto: si riparte con current
      if (code == exitRestart) {
        log('l\'app chiede il riavvio');
        continue;
      }
      return code;
    }
  }

  /// Versione da avviare: (versione, èProva). Aggiorna lo stato sotto lock.
  Future<(String, bool)?> _pick() => inst.withState((s) async {
        final pend = s.pending;
        if (pend != null) {
          if (!await Directory(inst.versionDir(pend)).exists()) {
            log('pending $pend sparita: la scarto');
            s.pending = null;
          } else if (s.pendingAttempts >= maxTrialAttempts) {
            log('ROLLBACK: $pend ha esaurito i tentativi (${s.pendingAttempts})');
            _markBad(s, pend);
          } else {
            s.pendingAttempts++;
            await inst.writeState(s);
            log('provo $pend (tentativo ${s.pendingAttempts}/$maxTrialAttempts)');
            return (pend, true);
          }
          await inst.writeState(s);
        }
        for (final v in [s.current, s.previous].whereType<String>()) {
          if (await Directory(inst.versionDir(v)).exists()) return (v, false);
          log('versione $v mancante');
        }
        return null;
      });

  void _markBad(InstallState s, String v) {
    if (!s.bad.contains(v)) s.bad.add(v);
    s.pending = null;
    s.pendingAttempts = 0;
  }

  /// Avvia [v]. Ritorna il codice d'uscita dell'app, o null se c'è stato un
  /// rollback e va scelto di nuovo cosa avviare.
  Future<int?> _runVersion(String v, bool trial, List<String> args) async {
    final health = inst.healthFile(v);
    await Directory(inst.runDir).create(recursive: true);
    await rmrf(health);
    final exe = await inst.entrypoint(v);
    final proc = await Process.start(exe, args,
        workingDirectory: inst.versionDir(v),
        mode: ProcessStartMode.inheritStdio,
        environment: {
          'MINESYNC_ROOT': inst.root,
          'MINESYNC_VERSION': v,
          'MINESYNC_HEALTH_FILE': health,
          'MINESYNC_TRIAL': trial ? '1' : '0',
        });
    int? exit;
    unawaited(proc.exitCode.then((c) => exit = c));
    if (!trial) return await proc.exitCode;

    final deadline = DateTime.now().add(healthTimeout);
    while (true) {
      if (await _healthy(health, v)) break;
      if (exit != null) {
        // Morta prima di confermare: il prossimo _pick riprova o fa rollback.
        log('$v è uscita con codice $exit prima di confermare l\'avvio');
        return null;
      }
      if (DateTime.now().isAfter(deadline)) {
        log('ROLLBACK: $v non ha confermato l\'avvio entro ${healthTimeout.inSeconds} s');
        proc.kill(ProcessSignal.sigkill);
        await proc.exitCode;
        await inst.withState((s) async {
          _markBad(s, v);
          await inst.writeState(s);
        });
        return null;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await _promote(v);
    return await proc.exitCode;
  }

  Future<bool> _healthy(String path, String v) async {
    try {
      return (await File(path).readAsString()).trim() == v;
    } on FileSystemException {
      return false;
    }
  }

  Future<void> _promote(String v) async {
    final s = await inst.withState((s) async {
      if (s.pending != v) return s;
      if (s.current != v) s.previous = s.current;
      s.current = v;
      s.pending = null;
      s.pendingAttempts = 0;
      await inst.writeState(s);
      return s;
    });
    log('PROMOSSA $v (previous=${s.previous})');
    final removed = await inst.cleanup(s);
    if (removed.isNotEmpty) log('rimosse: ${removed.join(', ')}');
    try {
      await _updateSelf(v);
    } catch (e) {
      log('aggiornamento del launcher non riuscito (si riproverà): $e');
    }
  }

  /// Aggiorna il launcher con quello incluso nella versione [v], se diverso.
  /// Il file in esecuzione si può RINOMINARE (anche su Windows), non
  /// sovrascrivere: self -> self.old, nuovo -> self. Prima di scambiarli si
  /// verifica che il nuovo parta (--selftest), perché un launcher rotto
  /// renderebbe l'installazione inavviabile.
  Future<void> _updateSelf(String v) async {
    final rel = await _manifestLauncher(v);
    if (rel == null) return;
    final src = File(p.join(inst.versionDir(v), rel));
    if (!await src.exists()) return;
    final a = sha256.convert(await src.readAsBytes());
    final b = sha256.convert(await File(selfPath).readAsBytes());
    if (a == b) return;
    final tmp = '$selfPath.new';
    await rmrf(tmp);
    await src.copy(tmp);
    chmodPosix(tmp, 493);
    final r = await Process.run(tmp, ['--selftest']);
    if (r.exitCode != 0 || !(r.stdout as String).contains('protocol=$launcherProtocol')) {
      await rmrf(tmp);
      throw StateError('il nuovo launcher non supera --selftest');
    }
    var old = '$selfPath.old';
    if (!await rmrf(old)) old = '$selfPath.old-${DateTime.now().millisecondsSinceEpoch}';
    await renameRetry(selfPath, old);
    await renameRetry(tmp, selfPath);
    fsyncDir(p.dirname(selfPath));
    log('launcher aggiornato: ${(r.stdout as String).trim()}');
  }

  Future<String?> _manifestLauncher(String v) async {
    final f = File(p.join(inst.versionDir(v), '.manifest.json'));
    final m = jsonDecode(await f.readAsString()) as Map;
    return m['launcher'] as String?;
  }
}
