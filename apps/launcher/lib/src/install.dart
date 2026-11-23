// Layout della cartella di installazione e stato persistente.
//
//   <root>/
//     state.json              stato (scritto solo con writeAtomic sotto state.lock)
//     state.lock              lock tra launcher e app per read-modify-write
//     launcher.lock           una sola istanza del launcher che sorveglia
//     launcher.log            diario del launcher (ruotato)
//     versions/<v>/           app completa + .manifest.json
//     versions/<v>.partial/   estrazione o copia in corso (mai avviata, ripulita)
//     downloads/              archivi in scaricamento (*.part)
//     run/healthy-<v>         marker scritto dall'app quando è partita bene
//
// Dove sta <root> dipende dal sistema: vedi layout.dart.
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:path/path.dart' as p;

import 'fsutil.dart';
import 'semver.dart';

/// Codice d'uscita con cui l'app chiede al launcher di riavviarla subito
/// (ha preparato un aggiornamento). EX_TEMPFAIL di sysexits.h.
const exitRestart = 75;

/// Tentativi di avvio concessi a una versione nuova prima del rollback.
const maxTrialAttempts = 2;

/// Nome del manifest copiato dentro ogni cartella di versione.
const versionManifestName = '.manifest.json';

/// Piattaforma nel formato del manifest: linux-x64, windows-x64, macos-arm64…
String currentPlatform() => Abi.current().toString().replaceAll('_', '-');

final class InstallState {
  InstallState({
    this.current,
    this.previous,
    this.pending,
    this.pendingAttempts = 0,
    List<String>? bad,
  }) : bad = bad ?? [];

  factory InstallState.fromJson(Map<String, Object?> j) => InstallState(
    current: j['current'] as String?,
    previous: j['previous'] as String?,
    pending: j['pending'] as String?,
    pendingAttempts: (j['pendingAttempts'] as int?) ?? 0,
    bad: [...(j['bad'] as List<Object?>? ?? const []).cast<String>()],
  );

  /// Ultima versione confermata sana.
  String? current;

  /// Quella prima, tenuta per il rollback.
  String? previous;

  /// Estratta e pronta, non ancora confermata.
  String? pending;

  /// Avvii tentati della pending (persistito PRIMA di avviarla).
  int pendingAttempts;

  /// Versioni che hanno fallito: mai più installate.
  List<String> bad;

  Map<String, Object?> toJson() => {
    'schema': 1,
    'current': current,
    'previous': previous,
    'pending': pending,
    'pendingAttempts': pendingAttempts,
    'bad': bad,
  };
}

final class Install {
  Install(this.root);

  final String root;

  String get statePath => p.join(root, 'state.json');
  String get versionsDir => p.join(root, 'versions');
  String get downloadsDir => p.join(root, 'downloads');
  String get runDir => p.join(root, 'run');
  String versionDir(String v) => p.join(versionsDir, v);
  String healthFile(String v) => p.join(runDir, 'healthy-$v');

  /// Stato su disco. Un file illeggibile (non dovrebbe succedere: si scrive
  /// in modo atomico) vale come stato vuoto: il launcher riadotta le versioni
  /// presenti invece di restare inavviabile.
  Future<InstallState> readState() async {
    final f = File(statePath);
    if (!await f.exists()) return InstallState();
    try {
      final j = jsonDecode(await f.readAsString());
      if (j is Map) return InstallState.fromJson(j.cast<String, Object?>());
    } on FormatException {
      // ricade sotto
    } on TypeError {
      // idem: campi del tipo sbagliato
    }
    return InstallState();
  }

  Future<void> writeState(InstallState s) =>
      writeAtomic(statePath, utf8.encode(const JsonEncoder.withIndent('  ').convert(s.toJson())));

  /// Read-modify-write dello stato sotto lock di file (esclusivo anche tra
  /// processi: fcntl su POSIX, LockFileEx su Windows).
  Future<T> withState<T>(Future<T> Function(InstallState s) fn) async {
    await Directory(root).create(recursive: true);
    final lock = await File(p.join(root, 'state.lock')).open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.blockingExclusive);
      return await fn(await readState());
    } finally {
      await lock.close(); // rilascia anche il lock
    }
  }

  /// Manifest copiato nella cartella di [dir] (una versione), o null.
  static Future<Map<String, Object?>?> readVersionManifest(String dir) async {
    try {
      final j = jsonDecode(await File(p.join(dir, versionManifestName)).readAsString());
      return j is Map ? j.cast<String, Object?>() : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Entrypoint della versione [v] letto dal manifest copiato nella cartella.
  Future<String> entrypoint(String v) async {
    final m = await readVersionManifest(versionDir(v));
    final e = m?['entrypoint'];
    if (e is! String) throw StateError('manifest della versione $v illeggibile');
    return p.joinAll([versionDir(v), ...e.split('/')]);
  }

  /// Versioni complete presenti in versions/ (con manifest e versione
  /// corrispondente al nome della cartella), dalla più nuova.
  Future<List<String>> installedVersions() async {
    final d = Directory(versionsDir);
    if (!await d.exists()) return const [];
    final out = <String>[];
    await for (final e in d.list(followLinks: false)) {
      if (e is! Directory) continue;
      final name = p.basename(e.path);
      if (SemVer.tryParse(name) == null) continue; // .partial e residui
      final m = await readVersionManifest(e.path);
      if (m?['version'] == name) out.add(name);
    }
    out.sort((a, b) => SemVer.tryParse(b)!.compareTo(SemVer.tryParse(a)!));
    return out;
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
        final name = p.basename(e.path);
        if (!name.startsWith('healthy-')) continue;
        if (!keep.contains(name.substring('healthy-'.length))) await rmrf(e.path);
      }
    }
    return removed;
  }
}
