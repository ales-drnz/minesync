// Trasporto HTTP con dart:io e cache su disco delle risposte di Modrinth.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../http.dart';
import '../modrinth.dart';

/// [HttpTransport] su [HttpClient]. Errori di rete e timeout diventano
/// [HttpUnavailable]; i redirect si seguono (i CDN li usano).
final class IoHttpTransport implements HttpTransport {
  IoHttpTransport({
    HttpClient? client,
    this.connectTimeout = const Duration(seconds: 15),
    this.idleTimeout = const Duration(seconds: 30),
  }) : _c = client ?? HttpClient() {
    _c.connectionTimeout = connectTimeout;
  }

  final HttpClient _c;
  final Duration connectTimeout;

  /// Attesa massima tra due pezzi della risposta.
  final Duration idleTimeout;

  @override
  Future<HttpRes> send(HttpReq req) async {
    try {
      final r = await _c.openUrl(req.method, req.url).timeout(connectTimeout);
      req.headers.forEach(r.headers.set);
      r.followRedirects = true;
      r.maxRedirects = 5;
      if (req.body != null) {
        r.contentLength = req.body!.length;
        r.add(req.body!);
      }
      final res = await r.close().timeout(idleTimeout);
      final headers = <String, String>{};
      res.headers.forEach((k, v) => headers[k] = v.join(', '));
      final body = res
          .timeout(idleTimeout, onTimeout: (s) => s.addError(HttpUnavailable(req.url, 'timeout')))
          .handleError(
            (Object e) => throw HttpUnavailable(req.url, e),
            test: (e) => e is! HttpUnavailable,
          );
      return HttpRes(
        res.statusCode,
        headers,
        body,
        contentLength: res.contentLength < 0 ? null : res.contentLength,
      );
    } on SocketException catch (e) {
      throw HttpUnavailable(req.url, e);
    } on TimeoutException catch (e) {
      throw HttpUnavailable(req.url, e);
    } on HandshakeException catch (e) {
      throw HttpUnavailable(req.url, e);
    } on HttpException catch (e) {
      throw HttpUnavailable(req.url, e);
    }
  }

  void close() => _c.close(force: true);
}

/// Cache delle risposte su disco: un file per chiave (SHA-256 della chiave),
/// al più [maxEntries] file (si tolgono i più vecchi). Un file illeggibile è
/// un mancato colpo.
final class FileResponseCache implements ResponseCache {
  FileResponseCache(this.dir, {this.maxEntries = 512});

  final String dir;
  final int maxEntries;
  int _puts = 0;

  File _file(String key) =>
      File('$dir/${crypto.sha256.convert(utf8.encode(key)).toString().substring(0, 40)}.json');

  @override
  Future<CachedBody?> get(String key) async {
    try {
      final j = jsonDecode(await _file(key).readAsString());
      if (j is! Map<String, Object?> || j['k'] != key) return null;
      final exp = j['e'], b = j['b'];
      if (exp is! int || b is! String) return null;
      return CachedBody(Uint8List.fromList(base64Decode(b)), exp);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> put(String key, CachedBody value) async {
    try {
      await Directory(dir).create(recursive: true);
      final f = _file(key);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({'k': key, 'e': value.expiresAtMs, 'b': base64Encode(value.body)}),
        flush: true,
      );
      await tmp.rename(f.path);
      if (++_puts % 32 == 0) await _prune();
    } on FileSystemException {
      // cache: un errore non è un problema
    }
  }

  Future<void> _prune() async {
    final files = <(File, DateTime)>[];
    await for (final e in Directory(dir).list()) {
      if (e is File && e.path.endsWith('.json')) files.add((e, (await e.stat()).modified));
    }
    if (files.length <= maxEntries) return;
    files.sort((a, b) => a.$2.compareTo(b.$2));
    for (final (f, _) in files.take(files.length - maxEntries)) {
      await f.delete().catchError((Object _) => f);
    }
  }
}
