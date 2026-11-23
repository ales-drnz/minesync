// Stato locale di una cartella collegata, in <cartella>/.minesync/:
// la generazione da cui parte la copia locale (base), la cache degli hash e
// i backup delle modifiche locali sovrascritte.
import 'dart:convert';
import 'dart:io';

import 'package:ms_protocol/ms_protocol.dart';

import 'atomic.dart';
import 'scanner.dart';
import 'snapshot.dart';

/// Generazione da cui parte la copia locale.
final class Base {
  const Base(this.space, this.n, this.digest, this.manifest);

  final String space;
  final int n;
  final String digest;
  final Manifest manifest;

  Map<String, Object?> toJson() => {
    'v': 1,
    'space': space,
    'n': n,
    'digest': digest,
    'manifest': manifest.toJson(),
  };
}

/// Pull iniziato e non concluso: verso quale generazione.
final class PullTarget {
  const PullTarget(this.n, this.digest);
  final int n;
  final String digest;
}

/// Accesso alla cartella `.minesync` di una copia locale.
final class LocalState {
  LocalState(this.root) : dir = '$root${Platform.pathSeparator}.minesync';

  final String root;
  final String dir;

  String get _basePath => '$dir${Platform.pathSeparator}base.json';
  String get _pullPath => '$dir${Platform.pathSeparator}pull.json';
  String get cachePath => '$dir${Platform.pathSeparator}cache.json';
  String get backupDir => '$dir${Platform.pathSeparator}backup';
  String get outboxDir => '$dir${Platform.pathSeparator}outbox';
  String get _pendingPath => '$outboxDir${Platform.pathSeparator}pending.json';

  void _ensureDir() => Directory(dir).createSync(recursive: true);

  /// Base salvata, o null se la cartella non è mai stata sincronizzata (o lo
  /// stato è illeggibile: allora si riparte come da zero, mai con dati
  /// inventati). Una base di un altro spazio non vale.
  Base? loadBase(String space) {
    try {
      final j = jsonDecode(File(_basePath).readAsStringSync()) as Map<String, Object?>;
      if (j['space'] != space) return null;
      final m = Manifest.fromJson(j['manifest']);
      final digest = j['digest'] as String;
      if (m.digest() != digest) return null; // stato manomesso o troncato
      return Base(space, j['n'] as int, digest, m);
    } on Object {
      return null;
    }
  }

  Future<void> saveBase(Base b) async {
    _ensureDir();
    await writeAtomic(_basePath, utf8.encode(jsonEncode(b.toJson())));
  }

  PullTarget? loadPullTarget() {
    try {
      final j = jsonDecode(File(_pullPath).readAsStringSync()) as Map<String, Object?>;
      return PullTarget(j['n'] as int, j['digest'] as String);
    } on Object {
      return null;
    }
  }

  Future<void> savePullTarget(PullTarget t) async {
    _ensureDir();
    await writeAtomic(_pullPath, utf8.encode(jsonEncode({'n': t.n, 'digest': t.digest})));
  }

  Future<void> clearPullTarget() async {
    try {
      await File(_pullPath).delete();
    } on FileSystemException {
      // non c'era
    }
  }

  /// Istantanea in attesa di caricamento, o null.
  Snapshot? loadPending(String space) {
    try {
      final j = jsonDecode(File(_pendingPath).readAsStringSync()) as Map<String, Object?>;
      return Snapshot.fromJson(j, space);
    } on Object {
      return null;
    }
  }

  Future<void> savePending(String space, Snapshot s) async {
    Directory(outboxDir).createSync(recursive: true);
    await writeAtomic(_pendingPath, utf8.encode(jsonEncode(s.toJson(space))));
  }

  Future<void> clearPending() async {
    try {
      await File(_pendingPath).delete();
    } on FileSystemException {
      // non c'era
    }
  }

  HashCache loadCache() => HashCache.load(cachePath);

  Future<void> saveCache(HashCache c) async {
    _ensureDir();
    await c.save(cachePath);
  }
}
