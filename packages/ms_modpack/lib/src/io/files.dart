// File della cartella del server: hash dei jar, lettura e scrittura di
// minesync-pack.json, download verificati per hash e applicazione di un
// piano di installazione (prima si scarica e si verifica tutto in una
// cartella temporanea esclusa dalla sincronizzazione, poi si sposta).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:ms_protocol/ms_protocol.dart' show checkPath;
import 'package:path/path.dart' as p;

import '../http.dart';
import '../install_plan.dart';
import '../mrpack.dart';
import '../pack.dart';
import 'transport.dart';

/// Cartella temporanea dei download dentro la radice del server: inizia con
/// `.minesync`, quindi le esclusioni di sistema non la sincronizzano mai.
const String modpackTmpDir = '.minesync-modpack.tmp';

/// Percorso assoluto del file relativo [rel] (con "/") dentro [root];
/// [ArgumentError] se [rel] non è un percorso valido per ms_protocol.
String insideRoot(String root, String rel) {
  final bad = checkPath(rel);
  if (bad != null && !(bad.name == 'reservedPrefix' && rel.startsWith('$modpackTmpDir/'))) {
    throw ArgumentError.value(rel, 'rel', 'percorso non valido (${bad.name})');
  }
  final out = p.normalize(p.join(root, p.joinAll(rel.split('/'))));
  if (!p.isWithin(p.normalize(root), out)) {
    throw ArgumentError.value(rel, 'rel', 'fuori dalla radice');
  }
  return out;
}

/// SHA-1, SHA-512 e dimensione di un file, in streaming.
Future<LocalFile> hashFile(String path, {required String relPath}) async {
  final s1 = _Sink(), s512 = _Sink();
  final c1 = crypto.sha1.startChunkedConversion(s1);
  final c512 = crypto.sha512.startChunkedConversion(s512);
  var size = 0;
  await for (final chunk in File(path).openRead()) {
    c1.add(chunk);
    c512.add(chunk);
    size += chunk.length;
  }
  c1.close();
  c512.close();
  return LocalFile(path: relPath, size: size, sha1: '${s1.value}', sha512: '${s512.value}');
}

final class _Sink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest d) => value = d;
  @override
  void close() {}
}

/// I jar che il pack dovrebbe conoscere ([isModLocation]): `mods/*.jar` e
/// `client-overrides/mods/*.jar`, anche spenti, con i loro hash.
Future<List<LocalFile>> scanModFiles(String root) async {
  final out = <LocalFile>[];
  for (final dir in const ['mods', '$clientOverridesDir/mods']) {
    final d = Directory(p.joinAll([root, ...dir.split('/')]));
    if (!await d.exists()) continue;
    await for (final e in d.list(followLinks: false)) {
      if (e is! File) continue;
      final rel = '$dir/${p.basename(e.path)}';
      if (!isModLocation(rel)) continue;
      out.add(await hashFile(e.path, relPath: rel));
    }
  }
  out.sort((a, b) => a.path.compareTo(b.path));
  return out;
}

/// [scanModFiles] in un isolate a parte: centinaia di MB di jar da leggere e
/// hashare non contendono il thread della UI.
Future<List<LocalFile>> scanModFilesIsolated(String root) =>
    Isolate.run(() => scanModFiles(root), debugName: 'scan mods');

/// Il pack della cartella [root]; null se non c'è il file.
/// [FormatException] se c'è ma non è valido.
Future<Pack?> readPackFile(String root) async {
  final f = File(p.join(root, packFileName));
  try {
    return Pack.decode(await f.readAsString());
  } on PathNotFoundException {
    return null;
  }
}

/// Scrive [pack] in [root] in modo atomico (file temporaneo e rinomina).
Future<void> writePackFile(String root, Pack pack) =>
    writeFileAtomic(p.join(root, packFileName), pack.encodeBytes());

/// Scrittura atomica di un file.
Future<void> writeFileAtomic(String path, List<int> bytes) async {
  await Directory(p.dirname(path)).create(recursive: true);
  final tmp = File('$path.minesyncpart');
  await tmp.writeAsBytes(bytes, flush: true);
  await tmp.rename(path);
}

/// I byte scaricati non sono quelli attesi.
final class HashMismatch implements Exception {
  const HashMismatch(this.url, this.expected, this.actual);
  final String url;
  final String expected;
  final String actual;
  @override
  String toString() => 'HashMismatch($url: atteso $expected, ricevuto $actual)';
}

/// Download fallito (HTTP non 2xx o rete), con l'ultimo errore.
final class DownloadFailed implements Exception {
  const DownloadFailed(this.urls, this.cause);
  final List<String> urls;
  final Object cause;
  @override
  String toString() => 'DownloadFailed(${urls.join(', ')}): $cause';
}

/// Ingresso dell'isolate di [Downloader.isolated]: scarica con un trasporto
/// proprio e risponde con avanzamento `(ricevuti, totale)`, `('ok', file)`
/// o `('err', errore, stack)`.
Future<void> _isolateDownload(
  (SendPort, List<String>, String, String?, String?, String?, int?, String, int) a,
) async {
  final (send, urls, dest, sha1, sha512, sha256, size, ua, max) = a;
  final d = Downloader(IoHttpTransport(), userAgent: ua, maxBytes: max);
  try {
    final f = await d.download(
      urls,
      dest,
      sha1: sha1,
      sha512: sha512,
      sha256: sha256,
      size: size,
      onProgress: (r, t) => send.send((r, t)),
    );
    send.send(('ok', f));
  } on HashMismatch catch (e, st) {
    send.send(('err', e, '$st'));
  } on Object catch (e, st) {
    // la causa può non essere inviabile fra isolate: passa come testo
    final cause = e is DownloadFailed ? e.cause : e;
    send.send(('err', DownloadFailed(urls, '$cause'), '$st'));
  }
}

/// Scarica file verificandoli: gli hash dati devono combaciare, altrimenti il
/// file non resta.
final class Downloader {
  Downloader(this.transport, {required this.userAgent, this.maxBytes = 2 << 30}) : isolated = false;

  /// Ogni download gira in un isolate a parte con un [IoHttpTransport]
  /// proprio: rete, hash e disco non contendono il thread della UI (che con
  /// animazioni e ricostruzioni lascerebbe al download pochi KB per frame).
  Downloader.isolated({required this.userAgent, this.maxBytes = 2 << 30})
    : transport = IoHttpTransport(),
      isolated = true;

  final HttpTransport transport;
  final String userAgent;

  /// Vero se i download girano in un isolate a parte.
  final bool isolated;

  /// Tetto a un singolo file.
  final int maxBytes;

  /// Scarica da [urls] (in ordine, il primo che riesce) in [dest].
  /// Verifica [size], [sha1], [sha512] e [sha256] quando dati.
  /// Restituisce gli hash calcolati. Lancia [HashMismatch] (il file
  /// sbagliato viene tolto) o [DownloadFailed].
  Future<LocalFile> download(
    List<String> urls,
    String dest, {
    String? sha1,
    String? sha512,
    String? sha256,
    int? size,
    void Function(int received, int? total)? onProgress,
  }) async {
    if (isolated) return _inIsolate(urls, dest, sha1, sha512, sha256, size, onProgress);
    Object? last;
    for (final u in urls) {
      try {
        return await _one(Uri.parse(u), dest, sha1, sha512, sha256, size, onProgress);
      } on HashMismatch {
        rethrow;
      } on Object catch (e) {
        last = e;
      }
    }
    throw DownloadFailed(urls, last ?? 'nessun URL');
  }

  Future<LocalFile> _inIsolate(
    List<String> urls,
    String dest,
    String? sha1,
    String? sha512,
    String? sha256,
    int? size,
    void Function(int, int?)? onProgress,
  ) async {
    final port = ReceivePort();
    final out = Completer<LocalFile>();
    port.listen((m) {
      switch (m) {
        case (final int r, final int? t):
          onProgress?.call(r, t);
        case ('ok', final LocalFile f):
          if (!out.isCompleted) out.complete(f);
        case ('err', final Object e, final String st):
          if (!out.isCompleted) out.completeError(e, StackTrace.fromString(st));
        case [final Object? e, final Object? st]:
          // errore non gestito dell'isolate (onError)
          if (!out.isCompleted) out.completeError(DownloadFailed(urls, '$e\n$st'));
        case null:
          // l'isolate è uscito (onExit) senza rispondere
          if (!out.isCompleted) out.completeError(DownloadFailed(urls, 'isolate exited'));
      }
    });
    try {
      await Isolate.spawn(
        _isolateDownload,
        (port.sendPort, urls, dest, sha1, sha512, sha256, size, userAgent, maxBytes),
        onError: port.sendPort,
        onExit: port.sendPort,
        debugName: 'download',
      );
      return await out.future;
    } finally {
      port.close();
    }
  }

  Future<LocalFile> _one(
    Uri url,
    String dest,
    String? sha1,
    String? sha512,
    String? sha256,
    int? size,
    void Function(int, int?)? onProgress,
  ) async {
    final res = await transport.send(HttpReq('GET', url, headers: {'User-Agent': userAgent}));
    if (!res.ok) {
      await res.drain();
      throw DownloadFailed([url.toString()], 'HTTP ${res.status}');
    }
    await Directory(p.dirname(dest)).create(recursive: true);
    final part = File('$dest.minesyncpart');
    final sink = part.openWrite();
    final s1 = _Sink(), s512 = _Sink(), s256 = _Sink();
    final c1 = crypto.sha1.startChunkedConversion(s1);
    final c512 = crypto.sha512.startChunkedConversion(s512);
    final c256 = crypto.sha256.startChunkedConversion(s256);
    var n = 0;
    final total = size ?? res.contentLength;
    // avanzamento al più ogni 100 ms: i pezzi sono di pochi KB e un
    // aggiornamento della UI per ciascuno rallenta il download di 100 volte
    final tick = Stopwatch()..start();
    try {
      await for (final chunk in res.body) {
        n += chunk.length;
        if (n > maxBytes || (size != null && n > size)) {
          throw HashMismatch(url.toString(), 'size ${size ?? maxBytes}', 'more bytes');
        }
        c1.add(chunk);
        c512.add(chunk);
        c256.add(chunk);
        sink.add(chunk);
        if (onProgress != null && tick.elapsedMilliseconds >= 100) {
          tick.reset();
          onProgress(n, total);
        }
      }
      onProgress?.call(n, total);
      await sink.flush();
      await sink.close();
    } catch (_) {
      await sink.close().catchError((Object _) {});
      await part.delete().catchError((Object _) => part);
      rethrow;
    }
    c1.close();
    c512.close();
    c256.close();
    final got1 = '${s1.value}', got512 = '${s512.value}', got256 = '${s256.value}';
    String? bad;
    if (size != null && n != size) bad = 'size $size≠$n';
    if (sha1 != null && sha1.toLowerCase() != got1) bad = 'sha1 $sha1≠$got1';
    if (sha512 != null && sha512.toLowerCase() != got512) bad = 'sha512';
    if (sha256 != null && sha256.toLowerCase() != got256) bad = 'sha256 $sha256≠$got256';
    if (bad != null) {
      await part.delete().catchError((Object _) => part);
      throw HashMismatch(url.toString(), bad, got1);
    }
    await part.rename(dest);
    return LocalFile(path: dest, size: n, sha1: got1, sha512: got512);
  }

  /// Corpo di [url] in memoria (metadati piccoli: manifest di Mojang,
  /// elenchi dei loader). [sha1] se la sorgente lo dà.
  Future<Uint8List> fetch(String url, {String? sha1, int max = 16 << 20}) async {
    final u = Uri.parse(url);
    final HttpRes res;
    try {
      res = await transport.send(HttpReq('GET', u, headers: {'User-Agent': userAgent}));
    } on HttpUnavailable catch (e) {
      throw DownloadFailed([url], e);
    }
    if (!res.ok) {
      await res.drain();
      throw DownloadFailed([url], 'HTTP ${res.status}');
    }
    final b = await res.readAll(max: max);
    if (sha1 != null) {
      final got = crypto.sha1.convert(b).toString();
      if (got != sha1.toLowerCase()) throw HashMismatch(url, sha1, got);
    }
    return b;
  }

  /// JSON di [url].
  Future<Object?> fetchJson(String url, {String? sha1}) async {
    final b = await fetch(url, sha1: sha1);
    try {
      return jsonDecode(utf8.decode(b));
    } on FormatException catch (e) {
      throw DownloadFailed([url], 'invalid JSON: ${e.message}');
    }
  }
}

/// Esito dell'applicazione di un piano.
final class ApplyResult {
  const ApplyResult({
    required this.downloaded,
    required this.moved,
    required this.deleted,
    required this.bytes,
  });
  final int downloaded;
  final int moved;
  final int deleted;
  final int bytes;
}

/// Applica [plan] nella cartella [root]: scarica e verifica tutto in
/// [modpackTmpDir]; se un download fallisce non tocca niente della cartella
/// (lancia l'errore). Poi cancella, sposta, mette i file nuovi e scrive
/// minesync-pack.json ([writePack]). Le mod in [InstallPlan.unavailable] non
/// si possono installare: chi chiama le mostra prima.
Future<ApplyResult> applyInstallPlan(
  String root,
  InstallPlan plan,
  Downloader dl, {
  bool writePack = true,
  void Function(InstallDownload d, int received, int? total)? onProgress,
}) async {
  final tmp = Directory(p.join(root, modpackTmpDir));
  await tmp.create(recursive: true);
  final ready = <(File, String)>[];
  var bytes = 0;
  try {
    for (final (i, d) in plan.downloads.indexed) {
      final dest = p.join(tmp.path, '$i-${d.mod.file}');
      final f = await dl.download(
        d.mod.downloads,
        dest,
        sha1: d.mod.sha1,
        sha512: d.mod.sha512,
        size: d.mod.size,
        onProgress: onProgress == null ? null : (r, t) => onProgress(d, r, t),
      );
      bytes += f.size;
      ready.add((File(dest), d.location));
    }
    for (final rel in plan.deletes) {
      final f = File(insideRoot(root, rel));
      if (await f.exists()) await f.delete();
    }
    for (final m in plan.moves) {
      final to = insideRoot(root, m.to);
      await Directory(p.dirname(to)).create(recursive: true);
      await File(insideRoot(root, m.from)).rename(to);
    }
    for (final (f, rel) in ready) {
      final to = insideRoot(root, rel);
      await Directory(p.dirname(to)).create(recursive: true);
      await f.rename(to);
    }
    if (writePack) await writePackFile(root, plan.pack);
  } finally {
    await tmp.delete(recursive: true).catchError((Object _) => tmp);
  }
  return ApplyResult(
    downloaded: ready.length,
    moved: plan.moves.length,
    deleted: plan.deletes.length,
    bytes: bytes,
  );
}

/// Scrive gli override di un `.mrpack` importato in [root] (percorsi già
/// validati dall'import; si ricontrollano qui).
Future<void> writeImportFiles(String root, MrpackImport imp) async {
  for (final f in imp.files) {
    await writeFileAtomic(insideRoot(root, f.path), f.bytes);
  }
}

/// Legge un `.mrpack` da disco (vedi [readMrpack]).
Future<MrpackImport> readMrpackFile(String path, {int maxBytes = 1 << 30, String? name}) async {
  final f = File(path);
  if (await f.length() > maxBytes) throw const MrpackError('tooLarge');
  return readMrpack(await f.readAsBytes(), maxBytes: maxBytes, name: name);
}

/// Tutti i file di [root] (percorsi relativi con "/"), saltando le cartelle
/// di stato di MineSync: servono a [planClientPack].
Future<List<String>> listServerFiles(String root) async {
  final out = <String>[];
  final base = p.normalize(root);
  await for (final e in Directory(base).list(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final rel = p.split(p.relative(e.path, from: base)).join('/');
    if (rel.startsWith('.minesync')) continue;
    out.add(rel);
  }
  out.sort();
  return out;
}

/// Esporta il pacchetto per i giocatori di [root] in [outPath] (`.mrpack`).
/// [chosenOptional]: le facoltative scelte su questo PC (vedi
/// [planClientPack]).
Future<ClientPackPlan> exportClientMrpack(
  String root,
  Pack pack,
  String outPath, {
  required String versionId,
  String? name,
  Set<String>? chosenOptional,
}) async {
  final plan = planClientPack(
    pack,
    await listServerFiles(root),
    versionId: versionId,
    name: name,
    chosenOptional: chosenOptional,
  );
  final bytes = <String, Uint8List>{};
  for (final e in plan.overrides) {
    bytes[e.serverPath] = await File(insideRoot(root, e.serverPath)).readAsBytes();
  }
  await writeFileAtomic(outPath, writeMrpack(plan, (s) => bytes[s]));
  return plan;
}
