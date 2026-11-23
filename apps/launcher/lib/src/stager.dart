// Lato app dell'aggiornamento: controlla l'hub, scarica, verifica, estrae e
// mette la versione nuova in "pending". Non tocca mai la versione in
// esecuzione né quella corrente: il passaggio avviene al riavvio, fatto dal
// launcher.
//
// Sull'hub, sotto la base (di solito <hub>/dl/):
//   update/<platform>/manifest.json      JSON (byte esatti firmati)
//   update/<platform>/manifest.json.sig  firma ed25519 in base64 dei byte sopra
//   update/<platform>/<archive.name>     tar.gz dell'app
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'fsutil.dart';
import 'install.dart';
import 'manifest.dart';
import 'semver.dart';
import 'tar.dart';

const maxManifestSize = 1 << 20;
const maxArchiveSize = 1 << 30;

class UpdateException implements Exception {
  UpdateException(this.msg);
  final String msg;
  @override
  String toString() => msg;
}

class HashException extends UpdateException {
  HashException(super.msg);
}

enum UpdateOutcome { staged, notNewer, knownBad, alreadyStaged, busy }

/// Fase raggiunta, per i test che uccidono il processo a metà: download (a
/// metà archivio), extract (a metà file), commit (tra rename della cartella
/// e scrittura dello stato). Nel prodotto non c'è.
typedef StageHook = Future<void> Function(String phase);

final class UpdateHub {
  UpdateHub(Uri base, {HttpClient? http})
    : base = base.path.endsWith('/') ? base : base.replace(path: '${base.path}/'),
      _http = http ?? (HttpClient()..connectionTimeout = const Duration(seconds: 10));

  final Uri base;
  final HttpClient _http;

  Future<HttpClientResponse> _get(String path) async {
    final req = await _http.getUrl(base.resolve(path));
    final res = await req.close();
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw UpdateException('hub: GET $path -> HTTP ${res.statusCode}');
    }
    return res;
  }

  /// Corpo intero con tetto alla dimensione.
  Future<Uint8List> fetch(String path, int limit) async {
    final res = await _get(path);
    final b = BytesBuilder(copy: false);
    await for (final c in res.timeout(const Duration(seconds: 30))) {
      b.add(c);
      if (b.length > limit) throw UpdateException('hub: $path troppo grande');
    }
    return b.takeBytes();
  }

  /// Manifest verificato per [platform]: la firma si controlla sui byte
  /// ricevuti prima di qualsiasi parse.
  Future<Manifest> manifest(String platform, String pubKey) async {
    final bytes = await fetch('update/$platform/manifest.json', maxManifestSize);
    final sig = utf8.decode(
      await fetch('update/$platform/manifest.json.sig', 4096),
      allowMalformed: true,
    );
    final m = await verifyManifest(bytes, sig, pubKey);
    if (m.platform != platform) throw SignatureException('piattaforma ${m.platform} != $platform');
    return m;
  }

  /// Scarica in [dest] verificando dimensione e SHA-256 in streaming.
  Future<void> download(Manifest m, String dest, {StageHook? hook}) async {
    if (m.archiveSize <= 0 || m.archiveSize > maxArchiveSize) {
      throw UpdateException('dimensione archivio');
    }
    final res = await _get('update/${m.platform}/${Uri.encodeComponent(m.archiveName)}');
    final out = await File(dest).open(mode: FileMode.writeOnly);
    final sink = _DigestSink();
    final hasher = sha256.startChunkedConversion(sink);
    var n = 0;
    var hooked = false;
    try {
      await for (final c in res.timeout(const Duration(seconds: 30))) {
        n += c.length;
        if (n > m.archiveSize) throw HashException('archivio più grande del dichiarato');
        hasher.add(c);
        await out.writeFrom(c);
        if (hook != null && !hooked && n > m.archiveSize ~/ 2) {
          hooked = true;
          await out.flush();
          await hook('download');
        }
      }
      hasher.close();
      if (n != m.archiveSize) throw HashException('archivio troncato ($n/${m.archiveSize})');
      if (sink.value.toString() != m.archiveSha256) {
        throw HashException('SHA-256 dell\'archivio non corrisponde');
      }
      await out.flush();
    } finally {
      await out.close();
    }
  }

  void close() => _http.close(force: true);
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest d) => value = d;
  @override
  void close() {}
}

/// Normalizza un percorso d'archivio e rifiuta tutto ciò che potrebbe uscire
/// dalla cartella di destinazione (path traversal, assoluti, drive Windows).
String safeRelPath(String name) {
  if (name.isEmpty ||
      name.startsWith('/') ||
      name.contains('\\') ||
      name.contains(':') ||
      name.contains('\x00')) {
    throw UpdateException('percorso non ammesso: "$name"');
  }
  final parts = name.split('/').where((s) => s.isNotEmpty && s != '.').toList();
  if (parts.isEmpty || parts.contains('..')) {
    throw UpdateException('percorso non ammesso: "$name"');
  }
  return parts.join('/');
}

/// Prepara gli aggiornamenti di un'installazione gestita dal launcher.
final class Stager {
  Stager(
    this.inst,
    this.currentVersion,
    this.pubKey, {
    String? platform,
    this.log = _noLog,
    this.hook,
  }) : platform = platform ?? currentPlatform();

  final Install inst;
  final String currentVersion;
  final String pubKey;
  final String platform;
  final void Function(String) log;
  final StageHook? hook;

  static void _noLog(String _) {}

  /// Controlla l'hub sotto [base] e, se c'è una versione più nuova valida, la
  /// prepara come "pending". Lancia SignatureException / HashException /
  /// UpdateException.
  Future<(UpdateOutcome, String)> checkAndStage(Uri base) async {
    final hub = UpdateHub(base);
    try {
      // La firma si verifica prima di scaricare qualsiasi altra cosa.
      final m = await hub.manifest(platform, pubKey);
      final v = m.version;
      if (m.kind != PackageKind.archive) {
        throw UpdateException('pacchetto ${m.kind.name} in installazione a cartella');
      }
      if (!isNewer(v, currentVersion)) {
        log('hub offre $v, ho $currentVersion: ignoro');
        return (UpdateOutcome.notNewer, v);
      }
      final st = await inst.withState((s) async => s);
      if (st.bad.contains(v)) {
        log('$v è già fallita in passato: ignoro');
        return (UpdateOutcome.knownBad, v);
      }
      if (st.pending == v) return (UpdateOutcome.alreadyStaged, v);

      final lock = await inst.tryUpdateLock();
      if (lock == null) return (UpdateOutcome.busy, v);
      try {
        await _stage(hub, m);
        return (UpdateOutcome.staged, v);
      } finally {
        await lock.close();
      }
    } finally {
      hub.close();
    }
  }

  Future<void> _stage(UpdateHub hub, Manifest m) async {
    final v = m.version;
    if (SemVer.tryParse(v) == null) throw UpdateException('versione non semver');
    // Residui di tentativi interrotti (kill, blackout): si riparte da zero.
    await rmrf(inst.downloadsDir);
    await Directory(inst.downloadsDir).create(recursive: true);
    final partial = '${inst.versionDir(v)}.partial';
    await rmrf(partial);

    final dl = p.join(inst.downloadsDir, 'update.tar.gz.part');
    log('scarico ${m.archiveName} (${m.archiveSize} byte)');
    try {
      await hub.download(m, dl, hook: hook);
    } catch (_) {
      await rmrf(inst.downloadsDir);
      rethrow;
    }

    log('estraggo in ${p.basename(partial)}');
    try {
      await _extract(m, dl, partial);
    } catch (_) {
      await rmrf(partial);
      await rmrf(inst.downloadsDir);
      rethrow;
    }
    // Copia del manifest nella versione: il launcher ci legge l'entrypoint.
    await writeAtomic(p.join(partial, versionManifestName), m.encode());
    fsyncDir(partial);

    // Una cartella finale non referenziata dallo stato è un residuo (kill tra
    // rename e commit dello stato): la rifacciamo.
    final finalDir = inst.versionDir(v);
    await inst.withState((s) async {
      if (s.current == v || s.previous == v) throw UpdateException('$v è già installata');
    });
    await rmrf(finalDir);
    await renameRetry(partial, finalDir, dir: true); // commit 1: cartella completa
    fsyncDir(inst.versionsDir);
    await hook?.call('commit');
    await inst.withState((s) async {
      s.pending = v;
      s.pendingAttempts = 0;
      await inst.writeState(s); // commit 2: il launcher la proverà al riavvio
    });
    await rmrf(inst.downloadsDir);
    log('$v pronta, partirà al riavvio');
  }

  Future<void> _extract(Manifest m, String archive, String dest) async {
    final want = <String, ManifestFile>{};
    final lower = <String>{};
    for (final f in m.files) {
      final rel = safeRelPath(f.path);
      // Su Windows/macOS il filesystem di solito ignora maiuscole/minuscole:
      // due voci che differiscono solo per quello si sovrascriverebbero.
      if (!lower.add(rel.toLowerCase())) throw UpdateException('voce duplicata: $rel');
      if (rel == versionManifestName) throw UpdateException('voce riservata: $rel');
      if (f.isLink && Platform.isWindows) {
        throw UpdateException('symlink non supportati su Windows');
      }
      want[rel] = f;
    }
    final links = <String>{};
    final seen = <String>{};
    await Directory(dest).create(recursive: true);
    final reader = TarReader(File(archive).openRead().transform(gzip.decoder));
    try {
      var count = 0;
      while (true) {
        final h = await reader.next();
        if (h == null) break;
        if (h.type == TarType.dir) continue; // le cartelle si creano da sole
        final rel = safeRelPath(h.path);
        final mf = want[rel];
        if (mf == null) throw UpdateException('voce non nel manifest: $rel');
        if (!seen.add(rel)) throw UpdateException('voce ripetuta: $rel');
        // Niente scritture "attraverso" un symlink estratto prima.
        for (final l in links) {
          if (rel.startsWith('$l/')) throw UpdateException('voce sotto un symlink: $rel');
        }
        final out = p.joinAll([dest, ...rel.split('/')]);
        await Directory(p.dirname(out)).create(recursive: true);
        if (h.type == TarType.symlink) {
          if (!mf.isLink || h.linkTarget != mf.link) {
            throw UpdateException('symlink diverso dal manifest: $rel');
          }
          final t = h.linkTarget!;
          final resolved = p.posix.normalize(p.posix.join(p.posix.dirname(rel), t));
          if (t.startsWith('/') || resolved == '..' || resolved.startsWith('../')) {
            throw UpdateException('symlink fuori dall\'albero: $rel -> $t');
          }
          await Link(out).create(t);
          links.add(rel);
        } else {
          if (mf.isLink || h.size != mf.size) {
            throw UpdateException('dimensione diversa dal manifest: $rel');
          }
          final raf = await File(out).open(mode: FileMode.writeOnly);
          final sink = _DigestSink();
          final hasher = sha256.startChunkedConversion(sink);
          try {
            await reader.readData(h, (c) async {
              hasher.add(c);
              await raf.writeFrom(c);
            });
            hasher.close();
            await raf.flush();
          } finally {
            await raf.close();
          }
          if (sink.value.toString() != mf.sha256) {
            throw HashException('SHA-256 diverso dal manifest: $rel');
          }
          chmodPosix(out, mf.mode & 0x1ff);
        }
        if (++count == (want.length ~/ 2).clamp(1, 1 << 30)) await hook?.call('extract');
      }
    } on TarFormatException catch (e) {
      // gzip valido (l'hash dell'archivio è già stato verificato) ma tar rotto
      throw UpdateException('$e');
    } finally {
      await reader.cancel();
    }
    final missing = want.keys.where((k) => !seen.contains(k)).toList();
    if (missing.isNotEmpty) {
      throw UpdateException('mancano nel pacchetto: ${missing.take(5).join(', ')}');
    }
  }
}
