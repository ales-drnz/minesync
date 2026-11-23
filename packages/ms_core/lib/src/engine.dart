// Motore di sincronizzazione di una cartella con uno spazio dell'hub.
//
// Pull = checkout della testa dell'hub, senza mai perdere lavoro locale: le
// modifiche mai caricate bloccano il pull (o, se l'utente sceglie di
// scartarle, vengono prima copiate in .minesync/backup).
// Push = begin → blob mancanti → commit, legato al lock e alla generazione da
// cui parte la copia locale (compare-and-swap sull'hub).
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ms_protocol/ms_protocol.dart';

import 'atomic.dart';
import 'disk.dart';
import 'hasher.dart';
import 'hub_client.dart';
import 'local_state.dart';
import 'lock_keeper.dart';
import 'posix.dart';
import 'scanner.dart';
import 'snapshot.dart';
import 'throttle.dart';
import 'sync_errors.dart';

/// Margine di spazio libero lasciato sul disco locale dopo un pull.
const int localDiskMargin = 256 << 20;

/// Avanzamento di un'operazione.
final class SyncProgress {
  const SyncProgress(
    this.phase, {
    this.done = 0,
    this.total = 0,
    this.files = 0,
    this.totalFiles = 0,
  });

  /// `scan`, `download`, `upload`, `commit`.
  final String phase;
  final int done;
  final int total;
  final int files;
  final int totalFiles;
}

final class PullResult {
  const PullResult({
    required this.n,
    required this.written,
    required this.deleted,
    required this.backup,
    required this.warnings,
  });

  /// Generazione ora presente in locale.
  final int n;
  final int written;
  final int deleted;

  /// Cartella con le copie delle modifiche locali sovrascritte, se ce ne sono.
  final String? backup;
  final List<String> warnings;
}

final class PushResult {
  const PushResult({required this.generation, required this.uploaded, required this.kept});

  /// Nuova generazione, o null se non c'era niente da caricare.
  final GenerationSummary? generation;
  final int uploaded;

  /// File saltati dalla scansione per cui resta la versione dell'hub.
  final List<String> kept;
}

final class SyncEngine {
  SyncEngine(
    this.client,
    this.space,
    this.root, {
    HashPool? pool,
    this.parallel = 6,
    this.onProgress,
    this.retries = 3,
    this.retryDelay = const Duration(milliseconds: 500),
    this.uploadLimit = 0,
  }) : _pool = pool ?? HashPool.shared,
       state = LocalState(root);

  final HubClient client;
  final String space;
  final String root;
  final HashPool _pool;
  final LocalState state;
  final int parallel;
  final int retries;
  final Duration retryDelay;

  /// Limite di banda dei caricamenti in background (istantanee), in byte al
  /// secondo; 0 = nessun limite. I push espliciti non sono limitati: c'è
  /// qualcuno che aspetta.
  int uploadLimit;
  final void Function(SyncProgress)? onProgress;

  final _tick = Stopwatch()..start();

  /// Avanzamento dei byte al più ogni 100 ms (i pezzi sono di pochi KB: un
  /// aggiornamento della UI per pezzo rallenterebbe il trasferimento) e
  /// sempre all'ultimo byte.
  void _byteProgress(SyncProgress p) {
    if (onProgress == null) return;
    if (p.done < p.total && _tick.elapsedMilliseconds < 100) return;
    _tick.reset();
    onProgress!(p);
  }

  String _os(String rel) =>
      Platform.isWindows ? '$root\\${rel.replaceAll('/', r'\')}' : '$root/$rel';

  Future<ScanResult> _scan(Exclusions ex) async {
    onProgress?.call(const SyncProgress('scan'));
    try {
      return await scanTree(root, ex, prior: state.loadCache(), pool: _pool);
    } on ScanException catch (e) {
      throw SyncException(SyncErrorKind.dirSymlink, path: e.path, message: 'directory symlink');
    }
  }

  // --- pull -------------------------------------------------------------------

  /// Porta la cartella alla testa dell'hub.
  Future<PullResult> pull({bool discardLocal = false, CancelToken? cancel}) async {
    final ct = cancel ?? CancelToken();
    final details = await _api(() => client.space(space));
    final headSummary = details.summary.head;
    final Manifest remote;
    final int remoteN;
    final String remoteDigest;
    if (headSummary == null) {
      remote = Manifest.empty;
      remoteN = 0;
      remoteDigest = emptyDigest;
    } else {
      final Generation g;
      try {
        g = await _retry(() => client.generation(space, n: headSummary.n));
      } on FormatException catch (e) {
        throw SyncException(SyncErrorKind.badManifest, message: '$e', cause: e);
      } on ManifestError catch (e) {
        throw SyncException(SyncErrorKind.badManifest, message: '$e', path: e.path, cause: e);
      }
      if (g.manifest.digest() != g.digest) {
        throw const SyncException(SyncErrorKind.badManifest, message: 'digest mismatch');
      }
      remote = g.manifest;
      remoteN = g.n;
      remoteDigest = g.digest;
    }
    ct.check();

    Directory(root).createSync(recursive: true);
    final ex = Exclusions(details.exclusions);
    final base = state.loadBase(space);
    final interrupted = state.loadPullTarget() != null;
    final scan = await _scan(ex);
    final local = scan.manifest;
    ct.check();

    // Lavoro a rischio: file locali diversi sia dalla base sia dall'hub.
    final atRisk = <String>[];
    for (final e in local.files.entries) {
      final r = remote[e.key];
      if (r != null && r.sameContent(e.value)) continue;
      final b = base?.manifest[e.key];
      if (b != null && b.sameContent(e.value)) continue;
      atRisk.add(e.key);
    }
    final removedLocally = [
      for (final p in base?.manifest.files.keys ?? const <String>[])
        if (local[p] == null && !scan.skipped.contains(p)) p,
    ];

    if (remoteN == 0 && !local.isEmpty) {
      if (discardLocal) {
        throw const SyncException(SyncErrorKind.emptyRemote, message: 'hub is empty, push instead');
      }
      throw SyncException(
        SyncErrorKind.dirtyLocal,
        changed: local.files.keys.toList(),
        base: base?.n,
        head: 0,
        message: 'local files, empty hub',
      );
    }

    String? backup;
    if (atRisk.isNotEmpty) {
      if (!discardLocal && !interrupted) {
        final diverged = base == null || base.n != remoteN || base.digest != remoteDigest;
        throw SyncException(
          SyncErrorKind.dirtyLocal,
          diverged: diverged,
          changed: atRisk,
          removed: removedLocally,
          base: base?.n,
          head: remoteN,
          message: 'unpushed local changes',
        );
      }
      backup = await _backup(atRisk);
    }

    // Piano: cancellazioni, scritture, solo permessi.
    final skipped = scan.skipped.toSet();
    final toDelete = [
      for (final p in local.files.keys)
        if (remote[p] == null) p,
    ];
    final toWrite = <String>[];
    final chmodOnly = <String>[];
    for (final e in remote.files.entries) {
      if (skipped.contains(e.key)) {
        // illeggibile o bloccato in locale: si prova comunque a scriverlo
        toWrite.add(e.key);
        continue;
      }
      final l = local[e.key];
      if (l == null) {
        toWrite.add(e.key);
      } else if (l.h != e.value.h || l.size != e.value.size) {
        toWrite.add(e.key);
      } else if (l.x != e.value.x) {
        chmodOnly.add(e.key);
      }
    }
    final need = toWrite.fold<int>(0, (a, p) => a + remote[p]!.size);
    if (need > 0) {
      final free = diskSpace(root).free;
      if (free < need + localDiskMargin) {
        throw SyncException(SyncErrorKind.localDiskFull, message: 'need $need bytes, free $free');
      }
    }

    await state.savePullTarget(PullTarget(remoteN, remoteDigest));

    // Prima le cancellazioni: libera i nomi (anche quelli che cambiano solo
    // per maiuscole su file system che non le distinguono).
    for (final p in toDelete) {
      try {
        File(_os(p)).deleteSync();
      } on FileSystemException {
        // già sparito
      }
    }

    final warnings = <String>[];
    var chmodWarned = false;
    void chmod(String p, bool x) {
      if (!setExecutable(_os(p), x) && !chmodWarned) {
        chmodWarned = true;
        warnings.add('chmod refused: $p');
      }
    }

    final sources = _localSources(local, scan);
    final total = need;
    var done = 0;
    var filesDone = 0;
    final cacheOut = Map<String, CacheEntry>.of(state.loadCache().entries)
      ..removeWhere((k, _) => remote[k] == null);
    await _forEachLimited(toWrite, parallel, (p) async {
      ct.check();
      final e = remote[p]!;
      await _writeFile(p, e, sources, ct, (n) {
        done += n;
        _byteProgress(
          SyncProgress(
            'download',
            done: done,
            total: total,
            files: filesDone,
            totalFiles: toWrite.length,
          ),
        );
      });
      if (e.x) chmod(p, true);
      final st = FileStat.statSync(_os(p));
      cacheOut[p] = CacheEntry(
        size: e.size,
        mtime: st.modified.microsecondsSinceEpoch,
        h: e.h,
        chunks: e.chunks,
        x: e.x,
      );
      filesDone++;
    });
    for (final p in chmodOnly) {
      chmod(p, remote[p]!.x);
      final c = cacheOut[p];
      if (c != null) {
        cacheOut[p] = CacheEntry(
          size: c.size,
          mtime: c.mtime,
          h: c.h,
          chunks: c.chunks,
          x: remote[p]!.x,
        );
      }
    }
    _pruneEmptyDirs(ex);

    await state.saveBase(Base(space, remoteN, remoteDigest, remote));
    await state.saveCache(HashCache(cacheOut));
    await state.clearPullTarget();
    return PullResult(
      n: remoteN,
      written: toWrite.length,
      deleted: toDelete.length,
      backup: backup,
      warnings: warnings,
    );
  }

  /// Copia i file a rischio in .minesync/backup/<data>/ prima di sovrascriverli.
  Future<String> _backup(List<String> paths) async {
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-').split('.').first;
    final dir = '${state.backupDir}${Platform.pathSeparator}$stamp';
    for (final p in paths) {
      final dst = File(Platform.isWindows ? '$dir\\${p.replaceAll('/', r'\')}' : '$dir/$p');
      dst.parent.createSync(recursive: true);
      await File(_os(p)).copy(dst.path);
    }
    return dir;
  }

  /// Dove trovare in locale i byte di un blob: chunk dei file grandi già
  /// presenti (un region file cambia di pochi chunk tra due generazioni) e
  /// file interi con lo stesso contenuto.
  Map<String, (String, int, int)> _localSources(Manifest local, ScanResult scan) {
    final out = <String, (String, int, int)>{};
    for (final e in local.files.entries) {
      final c = e.value.chunks;
      if (c == null) {
        out[e.value.h] = (_os(e.key), 0, e.value.size);
      } else {
        var off = 0;
        for (final k in c) {
          out[k.h] = (_os(e.key), off, k.size);
          off += k.size;
        }
      }
    }
    return out;
  }

  /// Ricostruisce un file in un temporaneo accanto alla destinazione,
  /// verificando ogni blob e l'hash dell'intero, poi lo rinomina.
  Future<void> _writeFile(
    String rel,
    FileEntry e,
    Map<String, (String, int, int)> sources,
    CancelToken ct,
    void Function(int) progress,
  ) async {
    final target = _os(rel);
    final parent = File(target).parent;
    if (FileSystemEntity.typeSync(parent.path) == FileSystemEntityType.file) {
      parent.deleteSync(); // un file locale al posto di una cartella dell'hub
    }
    parent.createSync(recursive: true);
    if (FileSystemEntity.typeSync(target, followLinks: false) == FileSystemEntityType.directory) {
      Directory(target).deleteSync(recursive: true);
    }
    final tmp = tempPathFor(target);
    final out = await File(tmp).open(mode: FileMode.writeOnly);
    final whole = backend.newCtx();
    try {
      final parts = e.chunks ?? [Chunk(e.h, e.size)];
      for (final part in parts) {
        ct.check();
        final bytes = await _fetchPart(part, sources, progress);
        whole.update(bytes);
        await out.writeFrom(bytes);
      }
      final got = hex(whole.finish());
      if (got != e.h) {
        throw SyncException(
          SyncErrorKind.corruptDownload,
          path: rel,
          message: 'file hash mismatch',
        );
      }
      await out.flush();
      await out.close();
      await commitTemp(tmp, target);
    } catch (_) {
      try {
        await out.close();
      } on Object {
        // già chiuso
      }
      try {
        File(tmp).deleteSync();
      } on FileSystemException {
        // non c'è
      }
      rethrow;
    } finally {
      whole.dispose();
    }
  }

  /// Byte di un blob: dalla copia locale se c'è ed è ancora valida,
  /// altrimenti dall'hub, verificati contro l'hash in ogni caso.
  Future<Uint8List> _fetchPart(
    Chunk part,
    Map<String, (String, int, int)> sources,
    void Function(int) progress,
  ) async {
    final src = sources[part.h];
    if (src != null && src.$3 == part.size) {
      try {
        final f = await File(src.$1).open();
        try {
          await f.setPosition(src.$2);
          final b = await f.read(part.size);
          if (b.length == part.size && sha256Hex(b) == part.h) {
            progress(b.length);
            return b;
          }
        } finally {
          await f.close();
        }
      } on FileSystemException {
        // sparito o cambiato: si scarica
      }
    }
    return _retry(() async {
      final buf = BytesBuilder(copy: false);
      var reported = 0;
      await client.downloadBlob(
        part.h,
        buf.add,
        onProgress: (n) {
          reported += n;
          progress(n);
        },
      );
      final b = buf.takeBytes();
      if (b.length != part.size || sha256Hex(b) != part.h) {
        progress(-reported);
        throw SyncException(SyncErrorKind.corruptDownload, message: 'blob ${part.h} mismatch');
      }
      return b;
    });
  }

  void _pruneEmptyDirs(Exclusions ex) {
    bool prune(Directory d, String rel) {
      var empty = true;
      for (final e in d.listSync(followLinks: false)) {
        final name = e.path.substring(e.path.lastIndexOf(Platform.pathSeparator) + 1);
        final childRel = rel.isEmpty ? name : '$rel/$name';
        if (e is Directory &&
            !(rel.isEmpty && name.startsWith(reservedPrefix)) &&
            !ex.excludesDir(childRel)) {
          if (!prune(e, childRel)) empty = false;
        } else {
          empty = false;
        }
      }
      if (empty && rel.isNotEmpty) {
        try {
          d.deleteSync();
        } on FileSystemException {
          return false;
        }
      }
      return empty;
    }

    prune(Directory(root), '');
  }

  // --- push -------------------------------------------------------------------

  /// Controlla che la copia locale parta dalla testa dell'hub e restituisce
  /// la base e le esclusioni effettive.
  Future<(Base, Exclusions)> _checkBase() async {
    final details = await _api(() => client.space(space));
    final headN = details.summary.headN;
    final headDigest = details.summary.headDigest;
    var base = state.loadBase(space);
    if (state.loadPullTarget() != null) {
      throw SyncException(
        SyncErrorKind.staleBase,
        base: base?.n,
        head: headN,
        message: 'pull interrupted',
      );
    }
    if (base == null) {
      if (headN != 0) {
        throw SyncException(SyncErrorKind.staleBase, head: headN, message: 'no local base');
      }
      base = Base(space, 0, emptyDigest, Manifest.empty);
    }
    if (base.n != headN || base.digest != headDigest) {
      throw SyncException(SyncErrorKind.staleBase, base: base.n, head: headN, message: 'hub moved');
    }
    _guard = details.settings?.protection ?? const ProtectionSettings();
    return (base, Exclusions(details.exclusions));
  }

  /// Soglia della guardia di cancellazione dello spazio (Admin ›
  /// Protezioni, con l'eventuale regola dello spazio): la stessa dell'hub,
  /// così ci si ferma prima di caricare niente e con l'elenco dei file.
  ProtectionSettings _guard = const ProtectionSettings();

  /// Manifest da caricare: quello della scansione, con la versione della
  /// base per i file saltati (un file bloccato non deve sparire per tutti).
  (Manifest, List<String>) _manifestFor(ScanResult scan, Base base, bool confirmMassDelete) {
    final files = Map<String, FileEntry>.of(scan.manifest.files);
    final kept = <String>[];
    for (final p in scan.skipped) {
      final b = base.manifest[p];
      if (b != null && !files.containsKey(p) && caseCollisions([...files.keys, p]).isEmpty) {
        files[p] = b;
        kept.add(p);
      }
    }
    final manifest = Manifest(files);
    if (manifest.isEmpty && !base.manifest.isEmpty && !confirmMassDelete) {
      throw SyncException(
        SyncErrorKind.massDelete,
        removed: base.manifest.files.keys.toList(),
        message: 'local folder is empty',
      );
    }
    final total = base.manifest.length;
    if (!confirmMassDelete && total > 0 && total >= _guard.massDeleteMinFiles) {
      final removed = [
        for (final p in base.manifest.files.keys)
          if (manifest[p] == null) p,
      ];
      if (removed.length > total * _guard.massDeleteRatio) {
        throw SyncException(
          SyncErrorKind.massDelete,
          removed: removed,
          message: 'the push removes ${removed.length} of $total files',
        );
      }
    }
    return (manifest, kept);
  }

  /// Carica lo stato locale come nuova generazione. Serve il lock [lock];
  /// con [keepAlive] il motore lo tiene vivo con heartbeat per tutto il push.
  Future<PushResult> push({
    required LockGrant lock,
    String message = '',
    GenerationKind kind = GenerationKind.push,
    bool confirmMassDelete = false,
    bool keepAlive = true,
    LockInfo Function()? lockInfo,
    CancelToken? cancel,
  }) async {
    final ct = cancel ?? CancelToken();
    final (base, ex) = await _checkBase();
    final scan = await _scan(ex);
    ct.check();
    final (manifest, kept) = _manifestFor(scan, base, confirmMassDelete);
    if (manifest.digest() == base.digest) {
      await state.saveCache(scan.cache);
      return PushResult(generation: null, uploaded: 0, kept: kept);
    }
    final sources = _localSources(scan.manifest, scan);
    final r = await _upload(
      base: base,
      manifest: manifest,
      lock: lock,
      message: message,
      kind: kind,
      confirmMassDelete: confirmMassDelete,
      keepAlive: keepAlive,
      lockInfo: lockInfo,
      ct: ct,
      open: (h, size) {
        final src = sources[h];
        if (src == null) {
          throw SyncException(SyncErrorKind.blobRejected, message: 'blob $h not available locally');
        }
        return File(src.$1).openRead(src.$2, src.$2 + src.$3);
      },
    );
    await state.saveCache(scan.cache);
    return PushResult(generation: r.$1, uploaded: r.$2, kept: kept);
  }

  /// begin → blob mancanti (letti con [open]) → commit, con il lock tenuto
  /// vivo se richiesto. Aggiorna la base.
  Future<(GenerationSummary, int)> _upload({
    required Base base,
    required Manifest manifest,
    required LockGrant lock,
    required String message,
    required GenerationKind kind,
    required bool confirmMassDelete,
    required bool keepAlive,
    required LockInfo Function()? lockInfo,
    required CancelToken ct,
    required Stream<List<int>> Function(String hash, int size) open,
    int limit = 0,
  }) async {
    LockKeeper? keeper;
    if (keepAlive) {
      keeper = LockKeeper(client, space, lock, cancel: ct, info: lockInfo)..start();
    }
    try {
      final started = await _api(
        () => client.beginPush(
          space,
          PushBegin(
            parent: base.n,
            parentDigest: base.digest,
            lockToken: lock.token,
            manifest: manifest,
            message: message,
            kind: kind,
            confirmMassDelete: confirmMassDelete,
          ),
        ),
      );
      ct.check();
      final sizes = <String, int>{};
      for (final e in manifest.files.values) {
        for (final c in e.chunks ?? [Chunk(e.h, e.size)]) {
          sizes[c.h] = c.size;
        }
      }
      final total = started.missing.fold<int>(0, (a, h) => a + (sizes[h] ?? 0));
      var done = 0;
      await _forEachLimited(started.missing, math.min(parallel, 4), (h) async {
        ct.check();
        final size = sizes[h]!;
        var sent = 0;
        await _api(() async {
          done -= sent;
          sent = 0;
          await client.uploadBlob(
            started.pushId,
            h,
            size,
            throttle(open(h, size), limit),
            abort: ct.whenCancelled,
            onProgress: (n) {
              sent += n;
              done += n;
              _byteProgress(SyncProgress('upload', done: done, total: total));
            },
          );
        }, retryOn: _transient);
      });
      ct.check();
      onProgress?.call(SyncProgress('commit', done: total, total: total));
      final gen = await _api(() => client.commitPush(started.pushId), retryOn: _transient);
      await state.saveBase(Base(space, gen.n, gen.digest, manifest));
      return (gen, started.missing.length);
    } on SyncException {
      rethrow;
    } catch (e) {
      // un errore di rete dopo un annullamento per lock perso: vale il motivo
      ct.check();
      rethrow;
    } finally {
      keeper?.stop();
    }
  }

  // --- istantanea e outbox ----------------------------------------------------

  /// Congela lo stato locale: copia nell'outbox i blob cambiati rispetto alla
  /// base e scrive `pending.json`. Va chiamata a server in pausa (save-off):
  /// dura quanto la copia dei pezzi cambiati, non quanto il caricamento.
  /// Restituisce null se non è cambiato niente.
  Future<Snapshot?> snapshot({bool confirmMassDelete = false}) async {
    final (base, ex) = await _checkBase();
    final scan = await _scan(ex);
    final (manifest, kept) = _manifestFor(scan, base, confirmMassDelete);
    if (manifest.digest() == base.digest) {
      await state.saveCache(scan.cache);
      return null;
    }
    final known = base.manifest.blobs;
    final sources = _localSources(scan.manifest, scan);
    final fresh = <String, (String, int, int)>{};
    for (final e in manifest.files.values) {
      for (final c in e.chunks ?? [Chunk(e.h, e.size)]) {
        if (!known.contains(c.h) && sources[c.h] != null) fresh[c.h] = sources[c.h]!;
      }
    }
    final need = fresh.values.fold<int>(0, (a, s) => a + s.$3);
    Directory(state.outboxDir).createSync(recursive: true);
    final free = diskSpace(state.outboxDir).free;
    if (free < need + localDiskMargin) {
      throw SyncException(SyncErrorKind.outboxNoSpace, message: 'need $need bytes, free $free');
    }
    final skipped = <String>[];
    for (final e in fresh.entries) {
      final dst = '${state.outboxDir}${Platform.pathSeparator}${e.key}';
      if (File(dst).existsSync()) continue;
      final b = await _readVerified(e.value, e.key);
      if (b == null) {
        // il file è cambiato dopo la scansione: resta fuori da questa istantanea
        skipped.add(e.key);
        continue;
      }
      await writeAtomic(dst, b);
    }
    if (skipped.isNotEmpty) {
      // senza quei pezzi l'istantanea non è coerente: si rifà la prossima volta
      throw const SyncException(
        SyncErrorKind.snapshotStale,
        message: 'files changed while copying',
      );
    }
    final snap = Snapshot(base.n, base.digest, manifest, DateTime.now().toUtc(), kept);
    await state.savePending(space, snap);
    await state.saveCache(scan.cache);
    return snap;
  }

  /// Carica l'istantanea in attesa, se c'è. I blob vengono dall'outbox; se
  /// l'hub ne chiede uno che si pensava avesse già (es. raccolto dalla GC),
  /// lo si prende dal file vivo solo se ha ancora lo stesso contenuto.
  Future<PushResult?> pushSnapshot({
    required LockGrant lock,
    String message = '',
    GenerationKind kind = GenerationKind.autosave,
    bool keepAlive = true,
    LockInfo Function()? lockInfo,
    CancelToken? cancel,
  }) async {
    final snap = state.loadPending(space);
    if (snap == null) return null;
    final ct = cancel ?? CancelToken();
    final Base base;
    try {
      (base, _) = await _checkBase();
    } on SyncException catch (e) {
      // l'hub è andato avanti: l'istantanea non serve più (i file locali, che
      // contengono le stesse modifiche, restano dove sono)
      if (e.kind == SyncErrorKind.staleBase) await clearOutbox();
      rethrow;
    }
    if (base.n != snap.baseN || base.digest != snap.baseDigest) {
      await clearOutbox();
      throw SyncException(SyncErrorKind.staleBase, base: snap.baseN, head: base.n);
    }
    // indice dei pezzi nei file vivi, per i blob non copiati
    final live = <String, (String, int, int)>{};
    for (final e in snap.manifest.files.entries) {
      var off = 0;
      for (final c in e.value.chunks ?? [Chunk(e.value.h, e.value.size)]) {
        live[c.h] = (_os(e.key), off, c.size);
        off += c.size;
      }
    }
    final r = await _upload(
      base: base,
      manifest: snap.manifest,
      lock: lock,
      message: message,
      kind: kind,
      confirmMassDelete: false,
      keepAlive: keepAlive,
      lockInfo: lockInfo,
      ct: ct,
      limit: uploadLimit,
      open: (h, size) {
        final f = File('${state.outboxDir}${Platform.pathSeparator}$h');
        if (f.existsSync()) return f.openRead();
        final src = live[h];
        if (src == null) {
          throw SyncException(SyncErrorKind.snapshotStale, message: 'blob $h not available');
        }
        return Stream.fromFuture(
          _readVerified(src, h).then(
            (b) =>
                b ?? (throw SyncException(SyncErrorKind.snapshotStale, message: 'blob $h changed')),
          ),
        );
      },
    );
    await clearOutbox();
    return PushResult(generation: r.$1, uploaded: r.$2, kept: snap.kept);
  }

  /// Svuota l'outbox e dimentica l'istantanea in attesa.
  Future<void> clearOutbox() async {
    await state.clearPending();
    final d = Directory(state.outboxDir);
    if (d.existsSync()) d.deleteSync(recursive: true);
  }

  /// Legge un pezzo di file e lo restituisce solo se ha ancora l'hash atteso.
  Future<Uint8List?> _readVerified((String, int, int) src, String h) async {
    try {
      final f = await File(src.$1).open();
      try {
        await f.setPosition(src.$2);
        final b = await f.read(src.$3);
        return b.length == src.$3 && sha256Hex(b) == h ? b : null;
      } finally {
        await f.close();
      }
    } on FileSystemException {
      return null;
    }
  }

  // --- utilità ----------------------------------------------------------------

  static bool _transient(Object e) =>
      e is HubUnreachable ||
      e is TransferStalled ||
      (e is ApiError && e.httpStatus >= 500 && e.code != ErrorCode.diskFull);

  /// Chiamata all'hub con riprova sugli errori transitori e traduzione degli
  /// errori dell'API in [SyncException].
  Future<T> _api<T>(Future<T> Function() f, {bool Function(Object)? retryOn}) async {
    try {
      return await _retry(f, retryOn: retryOn ?? _transient);
    } on ApiError catch (e) {
      throw _translate(e);
    }
  }

  Future<T> _retry<T>(Future<T> Function() f, {bool Function(Object)? retryOn}) async {
    final ok = retryOn ?? _transient;
    for (var attempt = 0; ; attempt++) {
      try {
        return await f();
      } catch (e) {
        if (attempt >= retries || !ok(e)) rethrow;
        await Future<void>.delayed(retryDelay * (1 << attempt));
      }
    }
  }

  static Object _translate(ApiError e) => switch (e.code) {
    ErrorCode.staleBase => SyncException(SyncErrorKind.staleBase, message: e.message, cause: e),
    ErrorCode.massDelete => SyncException(SyncErrorKind.massDelete, message: e.message, cause: e),
    ErrorCode.locked ||
    ErrorCode.lockLost => SyncException(SyncErrorKind.lockLost, message: e.message, cause: e),
    ErrorCode.spaceGone => SyncException(SyncErrorKind.spaceGone, message: e.message, cause: e),
    ErrorCode.diskFull => SyncException(SyncErrorKind.hubDiskFull, message: e.message, cause: e),
    ErrorCode.badHash => SyncException(SyncErrorKind.blobRejected, message: e.message, cause: e),
    _ => e,
  };
}

/// Esegue [f] su ogni elemento con al massimo [limit] in parallelo; al primo
/// errore smette di avviarne altri e lo rilancia dopo che quelli in corso
/// sono finiti.
Future<void> _forEachLimited<T>(List<T> items, int limit, Future<void> Function(T) f) async {
  var next = 0;
  Object? error;
  StackTrace? stack;
  Future<void> worker() async {
    while (error == null && next < items.length) {
      final item = items[next++];
      try {
        await f(item);
      } catch (e, s) {
        error ??= e;
        stack ??= s;
      }
    }
  }

  await Future.wait([for (var i = 0; i < math.max(1, limit); i++) worker()]);
  if (error != null) Error.throwWithStackTrace(error!, stack!);
}
