// Layout della cartella di installazione e stato persistente.
//
//   <root>/
//     minesync[.exe]          launcher (l'unico eseguibile che l'utente avvia)
//     state.json              stato (scritto solo con writeAtomic sotto state.lock)
//     state.lock              lock tra launcher e app per read-modify-write
//     launcher.lock           una sola istanza del launcher
//     versions/<v>/           app completa (exe + lib/dll + data/) + .manifest.json
//     versions/<v>.partial/   estrazione in corso (mai avviata, ripulita)
//     downloads/              archivi in scaricamento (*.part)
//     run/healthy-<v>         marker scritto dall'app quando è partita bene
//
// Windows: <root> = %LOCALAPPDATA%\MineSync (per utente, niente admin).
// Linux portabile: la cartella dove sta il launcher. macOS: vedi README.
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:path/path.dart' as p;

import 'fsutil.dart';

/// Codice d'uscita con cui l'app chiede al launcher di riavviarla subito
/// (ha appena preparato un aggiornamento). EX_TEMPFAIL di sysexits.h.
const exitRestart = 75;

/// Tentativi di avvio concessi a una versione nuova prima del rollback.
const maxTrialAttempts = 2;

/// Piattaforma nel formato del manifest: linux-x64, windows-x64, macos-arm64…
String currentPlatform() {
  final abi = Abi.current().toString(); // es. "linux_x64"
  return abi.replaceAll('_', '-');
}

class InstallState {
  String? current; // ultima versione confermata sana
  String? previous; // quella prima, tenuta per rollback manuale/automatico
  String? pending; // estratta e pronta, non ancora confermata
  int pendingAttempts; // avvii tentati della pending (persistito PRIMA di avviare)
  List<String> bad; // versioni che hanno fallito: mai più installate

  InstallState({this.current, this.previous, this.pending, this.pendingAttempts = 0, List<String>? bad})
      : bad = bad ?? [];

  Map<String, Object?> toJson() => {
        'schema': 1,
        'current': current,
        'previous': previous,
        'pending': pending,
        'pendingAttempts': pendingAttempts,
        'bad': bad,
      };

  factory InstallState.fromJson(Map<String, Object?> j) => InstallState(
        current: j['current'] as String?,
        previous: j['previous'] as String?,
        pending: j['pending'] as String?,
        pendingAttempts: (j['pendingAttempts'] as int?) ?? 0,
        bad: [...(j['bad'] as List? ?? const []).cast<String>()],
      );
}

class Install {
  final String root;
  Install(this.root);

  String get statePath => p.join(root, 'state.json');
  String get versionsDir => p.join(root, 'versions');
  String get downloadsDir => p.join(root, 'downloads');
  String get runDir => p.join(root, 'run');
  String versionDir(String v) => p.join(versionsDir, v);
  String healthFile(String v) => p.join(runDir, 'healthy-$v');

  Future<InstallState> readState() async {
    final f = File(statePath);
    if (!await f.exists()) return InstallState();
    return InstallState.fromJson((jsonDecode(await f.readAsString()) as Map).cast());
  }

  Future<void> writeState(InstallState s) async =>
      writeAtomic(statePath, utf8.encode(const JsonEncoder.withIndent('  ').convert(s.toJson())));

  /// Read-modify-write dello stato sotto lock di file (esclusivo anche tra
  /// processi: fcntl su POSIX, LockFileEx su Windows).
  Future<T> withState<T>(Future<T> Function(InstallState s) fn) async {
    await Directory(root).create(recursive: true);
    final lock = await File(p.join(root, 'state.lock')).open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.blockingExclusive);
      final s = await readState();
      final r = await fn(s);
      return r;
    } finally {
      await lock.close(); // rilascia anche il lock
    }
  }

  /// Entrypoint della versione [v] letto dal manifest copiato nella cartella.
  Future<String> entrypoint(String v) async {
    final j = jsonDecode(await File(p.join(versionDir(v), '.manifest.json')).readAsString()) as Map;
    return p.join(versionDir(v), j['entrypoint'] as String);
  }

  /// Toglie le versioni non più referenziate (tiene current, previous,
  /// pending), le estrazioni .partial e i download rimasti. Best effort: su
  /// Windows una cartella con un exe in esecuzione non si cancella e si
  /// riprova al prossimo giro.
  ///
  /// Gira sotto update.lock (non bloccante): se l'app sta scaricando o
  /// estraendo un aggiornamento proprio ora, la pulizia si salta.
  Future<List<String>> cleanup(InstallState s) async {
    final lock = await tryUpdateLock();
    if (lock == null) return const [];
    try {
      return await _cleanupLocked(s);
    } finally {
      await lock.close();
    }
  }

  /// Lock esclusivo non bloccante sull'area di aggiornamento (downloads/,
  /// versions/*.partial). null se lo tiene già qualcun altro.
  Future<RandomAccessFile?> tryUpdateLock() async {
    await Directory(root).create(recursive: true);
    final raf = await File(p.join(root, 'update.lock')).open(mode: FileMode.append);
    try {
      await raf.lock(FileLock.exclusive);
      return raf;
    } on FileSystemException {
      await raf.close();
      return null;
    }
  }

  Future<List<String>> _cleanupLocked(InstallState s) async {
    final keep = {s.current, s.previous, s.pending}.whereType<String>().toSet();
    final removed = <String>[];
    final vd = Directory(versionsDir);
    if (await vd.exists()) {
      await for (final e in vd.list(followLinks: false)) {
        final name = p.basename(e.path);
        if (keep.contains(name)) continue;
        if (await rmrf(e.path)) removed.add(name);
      }
    }
    await rmrf(downloadsDir);
    final rd = Directory(runDir);
    if (await rd.exists()) {
      await for (final e in rd.list()) {
        final v = p.basename(e.path).replaceFirst('healthy-', '');
        if (!keep.contains(v)) await rmrf(e.path);
      }
    }
    return removed;
  }
}
