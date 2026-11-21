// Lato app: controlla l'hub, scarica, verifica, estrae e mette in "pending".
// Non tocca mai la versione in esecuzione né quella corrente: il passaggio
// avviene al riavvio, fatto dal launcher.
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
  final String msg;
  UpdateException(this.msg);
  @override
  String toString() => msg;
}

class HashException extends UpdateException {
  HashException(super.msg);
}

enum UpdateOutcome { staged, notNewer, knownBad, alreadyStaged, busy }

/// Punto di aggancio SOLO per i test: con MINESYNC_TEST_HOOK=<fase> il
/// processo si ferma a quella fase (per essere ucciso con SIGKILL dal test).
/// In un prodotto vero questo sarebbe dietro un flag di compilazione.
Future<void> _hook(String phase) async {
  if (Platform.environment['MINESYNC_TEST_HOOK'] != phase) return;
  stdout.writeln('HOOK $phase pid=$pid');
  await stdout.flush();
  await Future<void>.delayed(const Duration(days: 1)); // un Timer tiene viva la VM // resta qui finché non viene ucciso
}

class HubClient {
  final Uri base;
  final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  HubClient(String url) : base = Uri.parse(url.endsWith('/') ? url : '$url/');

  Future<HttpClientResponse> get(String path) async {
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
    final res = await get(path);
    final b = BytesBuilder(copy: false);
    await for (final c in res.timeout(const Duration(seconds: 30))) {
      b.add(c);
      if (b.length > limit) throw UpdateException('hub: $path troppo grande');
    }
    return b.takeBytes();
  }

  /// Manifest verificato per [platform].
  Future<Manifest> manifest(String platform, String pubKey) async {
    final bytes = await fetch('update/$platform/manifest.json', maxManifestSize);
    final sig = utf8.decode(await fetch('update/$platform/manifest.json.sig', 4096));
    final m = await verifyManifest(bytes, sig, pubKey);
    if (m.platform != platform) throw SignatureException('piattaforma ${m.platform} != $platform');
    return m;
  }

  /// Scarica in [dest] verificando dimensione e SHA-256 in streaming.
  Future<void> download(Manifest m, String dest) async {
    if (m.archiveSize <= 0 || m.archiveSize > maxArchiveSize) throw UpdateException('dimensione archivio');
    final res = await get('update/${m.platform}/${m.archiveName}');
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
        if (!hooked && n > m.archiveSize ~/ 2) {
          hooked = true;
          await out.flush();
          await _hook('download'); // a metà download
        }
      }
      hasher.close();
      if (n != m.archiveSize) throw HashException('archivio troncato ($n/${m.archiveSize})');
      if (sink.value.toString() != m.archiveSha256) throw HashException('SHA-256 dell\'archivio non corrisponde');
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
  if (parts.isEmpty || parts.contains('..')) throw UpdateException('percorso non ammesso: "$name"');
  return parts.join('/');
}

class Updater {
  final Install inst;
  final String currentVersion;
  final String pubKey;
  final String platform;
  final void Function(String) log;

  Updater(this.inst, this.currentVersion, this.pubKey,
      {String? platform, this.log = print})
      : platform = platform ?? currentPlatform();

  /// Controlla l'hub e, se c'è una versione più nuova valida, la prepara come
  /// "pending". Lancia SignatureException / HashException / UpdateException.
  Future<UpdateOutcome> checkAndStage(String hubUrl) async {
    final hub = HubClient(hubUrl);
    try {
      // La firma si verifica prima di scaricare qualsiasi altra cosa.
      final m = await hub.manifest(platform, pubKey);
      if (m.kind != PackageKind.archive) throw UpdateException('pacchetto ${m.kind.name} in installazione a cartella');
      if (!isNewer(m.version, currentVersion)) {
        log('hub offre ${m.version}, ho $currentVersion: ignoro');
        return UpdateOutcome.notNewer;
      }
      final st = await inst.withState((s) async => s);
      if (st.bad.contains(m.version)) {
        log('${m.version} è già fallita in passato: ignoro');
        return UpdateOutcome.knownBad;
      }
      if (st.pending == m.version) return UpdateOutcome.alreadyStaged;

      final lock = await inst.tryUpdateLock();
      if (lock == null) return UpdateOutcome.busy;
      try {
        return await _stage(hub, m);
      } finally {
        await lock.close();
      }
    } finally {
      hub.close();
    }
  }

  Future<UpdateOutcome> _stage(HubClient hub, Manifest m) async {
    final v = m.version;
    if (SemVer.tryParse(v) == null) throw UpdateException('versione non semver');
    // Residui di tentativi interrotti (kill, blackout): si riparte da zero.
    await rmrf(inst.downloadsDir);
    await Directory(inst.downloadsDir).create(recursive: true);
    final partial = '${inst.versionDir(v)}.partial';
    await rmrf(partial);

    final dl = p.join(inst.downloadsDir, '${m.archiveName}.part');
    log('scarico ${m.archiveName} (${m.archiveSize} byte)');
    try {
      await hub.download(m, dl);
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
    await writeAtomic(p.join(partial, '.manifest.json'), m.encode());
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
    await _hook('commit');
    await inst.withState((s) async {
      s.pending = v;
      s.pendingAttempts = 0;
      await inst.writeState(s); // commit 2: il launcher la proverà al riavvio
    });
    await rmrf(inst.downloadsDir);
    log('$v pronta, partirà al riavvio');
    return UpdateOutcome.staged;
  }

  Future<void> _extract(Manifest m, String archive, String dest) async {
    final want = <String, ManifestFile>{};
    final lower = <String>{};
    for (final f in m.files) {
      final rel = safeRelPath(f.path);
      // Su Windows/macOS il filesystem di solito ignora maiuscole/minuscole:
      // due voci che differiscono solo per quello si sovrascriverebbero.
      if (!lower.add(rel.toLowerCase())) throw UpdateException('voce duplicata: $rel');
      if (f.isLink && Platform.isWindows) throw UpdateException('symlink non supportati su Windows');
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
          if (!mf.isLink || h.linkTarget != mf.link) throw UpdateException('symlink diverso dal manifest: $rel');
          final t = h.linkTarget!;
          final resolved = p.posix.normalize(p.posix.join(p.posix.dirname(rel), t));
          if (t.startsWith('/') || resolved == '..' || resolved.startsWith('../')) {
            throw UpdateException('symlink fuori dall\'albero: $rel -> $t');
          }
          await Link(out).create(t);
          links.add(rel);
        } else {
          if (mf.isLink || h.size != mf.size) throw UpdateException('dimensione diversa dal manifest: $rel');
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
          if (sink.value.toString() != mf.sha256) throw HashException('SHA-256 diverso dal manifest: $rel');
          chmodPosix(out, mf.mode & 0x1ff);
        }
        if (++count == (want.length ~/ 2).clamp(1, 1 << 30)) await _hook('extract');
      }
    } finally {
      await reader.cancel();
    }
    final missing = want.keys.where((k) => !seen.contains(k)).toList();
    if (missing.isNotEmpty) throw UpdateException('mancano nel pacchetto: ${missing.take(5).join(', ')}');
  }
}

/// Modalità AppImage: un solo file. Si scarica accanto a $APPIMAGE, si
/// verifica, e lo si mette al posto dell'originale con un rename atomico. Il
/// processo in esecuzione continua sul vecchio inode (la sua squashfs resta
/// montata); il prossimo avvio usa il nuovo. Il vecchio resta come .old.
class AppImageUpdater {
  final String appImage;
  final String currentVersion;
  final String pubKey;
  final String platform;
  final void Function(String) log;
  AppImageUpdater(this.appImage, this.currentVersion, this.pubKey,
      {String? platform, this.log = print})
      : platform = platform ?? '${currentPlatform()}-appimage';

  Future<UpdateOutcome> checkAndReplace(String hubUrl) async {
    final hub = HubClient(hubUrl);
    final part = '$appImage.part';
    try {
      final m = await hub.manifest(platform, pubKey);
      if (m.kind != PackageKind.file) throw UpdateException('atteso pacchetto a file singolo');
      if (!isNewer(m.version, currentVersion)) return UpdateOutcome.notNewer;
      await rmrf(part);
      try {
        await hub.download(m, part); // contiene _hook('download')
      } catch (_) {
        await rmrf(part);
        rethrow;
      }
      final mode = (await File(appImage).stat()).mode & 0x1ff;
      chmodPosix(part, mode | 0x49); // +x
      // Il vecchio resta come .old (hardlink: $APPIMAGE non sparisce mai).
      final old = '$appImage.old';
      await rmrf(old);
      if (!hardLink(appImage, old)) log('hardlink .old non riuscito');
      await File(part).rename(appImage); // rename(2): atomico sullo stesso fs
      fsyncDir(p.dirname(appImage));
      log('AppImage sostituita con ${m.version}');
      return UpdateOutcome.staged;
    } finally {
      hub.close();
    }
  }
}
