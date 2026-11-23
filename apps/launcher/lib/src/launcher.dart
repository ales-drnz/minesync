// Launcher: l'unico eseguibile che l'utente avvia. Sceglie la versione,
// la avvia, ne sorveglia il primo avvio e fa rollback se non conferma.
//
// Regole:
//  - se c'è una "pending", la prova: prima di avviarla incrementa e PERSISTE
//    pendingAttempts (così conta anche un crash del launcher o un blackout);
//  - la pending è promossa a current quando scrive run/healthy-<v> col proprio
//    numero di versione (l'app lo fa dopo il primo frame disegnato);
//  - se esce prima del marker si riprova fino a maxTrialAttempts; se non
//    scrive il marker entro il timeout (60 s) la si uccide: in entrambi i casi
//    rollback = la si mette in "bad" e si avvia current;
//  - exit code 75 dall'app = "riavviami" (ha preparato un aggiornamento);
//  - dopo una promozione: pulizia (si tengono current + previous) ed
//    eventuale aggiornamento del launcher stesso;
//  - se un altro launcher sorveglia già l'app, questo avvia la versione
//    corrente senza toccare lo stato: è l'app a trovare l'istanza attiva, a
//    chiederle di mostrarsi e a uscire subito.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'fsutil.dart';
import 'install.dart';
import 'layout.dart';
import 'semver.dart';

const launcherBuild = int.fromEnvironment('LAUNCHER_BUILD', defaultValue: 1);
const launcherProtocol = 1;

/// Riga stampata da `--selftest`.
String get selftestLine => 'minesync-launcher build=$launcherBuild protocol=$launcherProtocol';

final class Launcher {
  Launcher(this.layout, {required this.healthTimeout, void Function(String)? log})
    : inst = Install(layout.root),
      _log = log;

  final LauncherLayout layout;
  final Install inst;
  final Duration healthTimeout;
  final void Function(String)? _log;
  IOSink? _logFile;

  String get selfPath => layout.selfPath;

  /// Se c'è uno stdout dove scrivere: il launcher Windows è un programma GUI
  /// (vedi pe.dart) e, avviato da un collegamento, non ne ha.
  static final bool _console = () {
    try {
      return !Platform.isWindows || stdioType(stdout) != StdioType.other;
    } on Object {
      return false;
    }
  }();

  void log(String s) {
    final line = '[launcher b$launcherBuild] $s';
    if (_log != null) return _log(line);
    if (_console) {
      try {
        stdout.writeln(line);
      } on Object {
        // stdout chiuso: resta il file
      }
    }
    _logFile?.writeln('${DateTime.now().toIso8601String()} $line');
  }

  Future<int> run(List<String> args) async {
    await Directory(inst.root).create(recursive: true);
    _openLogFile();
    try {
      return await _run(args);
    } finally {
      await _logFile?.flush();
      await _logFile?.close();
    }
  }

  void _openLogFile() {
    if (_log != null) return;
    final f = File(p.join(inst.root, 'launcher.log'));
    try {
      if (f.existsSync() && f.lengthSync() > 1 << 20) f.renameSync('${f.path}.1');
      _logFile = f.openWrite(mode: FileMode.append);
    } on FileSystemException {
      _logFile = null;
    }
  }

  Future<int> _run(List<String> args) async {
    // Una sola istanza che sorveglia: il lock dura quanto il processo.
    final instLock = await File(p.join(inst.root, 'launcher.lock')).open(mode: FileMode.append);
    try {
      await instLock.lock(FileLock.exclusive);
    } on FileSystemException {
      await instLock.close();
      return _runSecondary(args);
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

  /// Un altro launcher sorveglia già: si avvia la corrente senza prove né
  /// scritture; l'app passa la richiesta all'istanza attiva ed esce.
  Future<int> _runSecondary(List<String> args) async {
    final s = await inst.readState();
    for (final v in [s.current, s.previous].whereType<String>()) {
      if (!await Directory(inst.versionDir(v)).exists()) continue;
      log('già in esecuzione: avvio $v per passarle la richiesta');
      final proc = await _start(await inst.entrypoint(v), args, v, {
        ..._appEnv(v, args),
        'MINESYNC_SECONDARY': '1',
      });
      return proc.exitCode;
    }
    log('già in esecuzione e nessuna versione corrente');
    return 2;
  }

  /// Versione da avviare: (versione, èProva). Aggiorna lo stato sotto lock.
  Future<(String, bool)?> _pick() => inst.withState((s) async {
    if (await _adopt(s)) await inst.writeState(s);
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

  /// Installa la versione di partenza del pacchetto se è più nuova della
  /// corrente (pacchetto nuovo installato a mano), e riadotta le versioni
  /// presenti se lo stato non ne indica una valida (installer senza
  /// state.json, stato perso). Ritorna true se ha cambiato lo stato.
  Future<bool> _adopt(InstallState s) async {
    var changed = false;
    final boot = layout.bootstrapDir;
    final bm = boot == null ? null : await Install.readVersionManifest(boot);
    final bv = bm?['version'];
    if (bv is String && SemVer.tryParse(bv) != null && !s.bad.contains(bv)) {
      final cur = s.current;
      if (cur == null || isNewer(bv, cur) || !await Directory(inst.versionDir(cur)).exists()) {
        if (!await Directory(inst.versionDir(bv)).exists()) {
          log('installo la versione del pacchetto $bv');
          final partial = '${inst.versionDir(bv)}.partial';
          await rmrf(partial);
          await copyTree(boot!, partial);
          await renameRetry(partial, inst.versionDir(bv), dir: true);
          fsyncDir(inst.versionsDir);
        }
        if (cur != bv) {
          if (cur != null && await Directory(inst.versionDir(cur)).exists()) s.previous = cur;
          s.current = bv;
          changed = true;
        }
        final pend = s.pending;
        if (pend != null && !isNewer(pend, bv)) {
          s.pending = null;
          s.pendingAttempts = 0;
        }
      }
    }
    final cur = s.current;
    if (cur == null || !await Directory(inst.versionDir(cur)).exists()) {
      final ok = (await inst.installedVersions()).where(
        (v) => !s.bad.contains(v) && v != s.pending,
      );
      if (ok.isNotEmpty && ok.first != cur) {
        log('adotto la versione installata ${ok.first}');
        s.current = ok.first;
        if (s.previous == ok.first) s.previous = null;
        changed = true;
      }
    }
    return changed;
  }

  void _markBad(InstallState s, String v) {
    if (!s.bad.contains(v)) s.bad.add(v);
    s.pending = null;
    s.pendingAttempts = 0;
  }

  /// Ambiente per l'app: dove sta l'installazione, che versione è, quale
  /// comando registrare per l'avvio con il sistema (l'AppImage stessa, non il
  /// launcher montato al suo interno). Gli argomenti passano anche per
  /// l'ambiente: su macOS il runner Flutter non li inoltra a main().
  Map<String, String> _appEnv(String v, List<String> args) => {
    'MINESYNC_ROOT': inst.root,
    'MINESYNC_VERSION': v,
    'MINESYNC_LAUNCHER': Platform.environment['APPIMAGE'] ?? selfPath,
    if (args.contains('--autostart')) 'MINESYNC_AUTOSTART': '1',
  };

  Future<Process> _start(String exe, List<String> args, String v, Map<String, String> env) async {
    try {
      return await Process.start(
        exe,
        args,
        workingDirectory: inst.versionDir(v),
        mode: ProcessStartMode.inheritStdio,
        environment: env,
      );
    } on ProcessException catch (e) {
      // Windows con sottosistema GUI: niente console da ereditare.
      log('avvio con stdio ereditato non riuscito ($e): uso le pipe');
      final proc = await Process.start(
        exe,
        args,
        workingDirectory: inst.versionDir(v),
        environment: env,
      );
      unawaited(proc.stdout.drain<void>());
      unawaited(proc.stderr.drain<void>());
      return proc;
    }
  }

  /// Avvia [v]. Ritorna il codice d'uscita dell'app, o null se c'è stato un
  /// rollback e va scelto di nuovo cosa avviare.
  Future<int?> _runVersion(String v, bool trial, List<String> args) async {
    final health = inst.healthFile(v);
    await Directory(inst.runDir).create(recursive: true);
    await rmrf(health);
    final Process proc;
    try {
      proc = await _start(await inst.entrypoint(v), args, v, {
        ..._appEnv(v, args),
        'MINESYNC_HEALTH_FILE': health,
        'MINESYNC_TRIAL': trial ? '1' : '0',
      });
    } on Object catch (e) {
      // Eseguibile mancante o non avviabile: per una prova vale come crash
      // (il prossimo giro riprova o fa rollback), per la corrente si passa
      // alla precedente.
      log('$v non si avvia: $e');
      if (trial) return null;
      final moved = await inst.withState((s) async {
        if (s.current != v || s.previous == null) return false;
        s.current = s.previous;
        s.previous = null;
        if (!s.bad.contains(v)) s.bad.add(v);
        await inst.writeState(s);
        return true;
      });
      return moved ? null : 1;
    }
    final exitFuture = proc.exitCode;
    if (!trial) return exitFuture;

    int? exit;
    unawaited(exitFuture.then((c) => exit = c));
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
        await exitFuture;
        await inst.withState((s) async {
          _markBad(s, v);
          await inst.writeState(s);
        });
        return null;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await _promote(v);
    return exitFuture;
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
    if (!layout.selfUpdate) return;
    try {
      await _updateSelf(v);
    } on Object catch (e) {
      log('aggiornamento del launcher non riuscito (si riproverà): $e');
    }
  }

  /// Aggiorna il launcher con quello incluso nella versione [v], se diverso.
  /// Il file in esecuzione si può RINOMINARE (anche su Windows), non
  /// sovrascrivere: self -> self.old, nuovo -> self. Prima di scambiarli si
  /// verifica che il nuovo parta (--selftest), perché un launcher rotto
  /// renderebbe l'installazione inavviabile.
  Future<void> _updateSelf(String v) async {
    final m = await Install.readVersionManifest(inst.versionDir(v));
    final rel = m?['launcher'];
    if (rel is! String) return;
    final src = File(p.joinAll([inst.versionDir(v), ...rel.split('/')]));
    if (!await src.exists()) return;
    final a = sha256.convert(await src.readAsBytes());
    final b = sha256.convert(await File(selfPath).readAsBytes());
    if (a == b) return;
    final tmp = '$selfPath.new';
    await rmrf(tmp);
    await src.copy(tmp);
    chmodPosix(tmp, 493);
    final r = await Process.run(tmp, ['--selftest'], stdoutEncoding: utf8);
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
}
