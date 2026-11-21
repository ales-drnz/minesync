// API HTTP minima dell'hub su dart:io (niente shelf, vedi README):
//   POST /push/begin            {"blobs":[hash...]} -> {"id":..,"missing":[..]}
//   PUT  /blobs/<sha256>        corpo in streaming, hash riverificato
//   GET  /blobs/<sha256>        streaming, Range: bytes=a-b | a- | -n
//   POST /push/<id>/commit      {"files":{...}} -> manifest atomico + evento SSE
//   GET  /events                SSE, keepalive ogni HUB_KEEPALIVE_S (25 s)
//   GET  /healthz               "ok"
//   GET  /debug/stats           RSS, client SSE, upload attivi
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'store.dart';

class Hub {
  Hub(this.store,
      {this.keepalive = const Duration(seconds: 25),
      this.rcvBufBytes = 1 << 20,
      this.maxUploads = 4});

  /// upload che leggono il corpo in parallelo; gli altri attendono SENZA
  /// leggere dal socket (il TCP del client si ferma da solo): così i pezzi
  /// vivi nell'heap sono al massimo ~maxUploads x 2 x 6 MiB
  final int maxUploads;
  int _uploadSlots = 0;
  final _uploadWaiters = <Completer<void>>[];
  final BlobStore store;
  final Duration keepalive;

  /// SO_RCVBUF per connessione (0 = autotuning del kernel). Vedi _TunedServerSocket.
  final int rcvBufBytes;
  final _sse = <HttpResponse>{};
  final _pushes = <String, List<String>>{};
  final _rnd = Random.secure();
  int _eventId = 0;
  int activeUploads = 0;
  int errors = 0;
  Timer? _ka;
  HttpServer? _server;

  Future<int> serve(InternetAddress addr, int port) async {
    final ss = await ServerSocket.bind(addr, port, backlog: 1024);
    final s = HttpServer.listenOn(
        rcvBufBytes > 0 ? _TunedServerSocket(ss, rcvBufBytes) : ss);
    _server = s;
    s.idleTimeout = const Duration(seconds: 120);
    // un solo timer per tutti i client SSE (non uno per connessione)
    _ka = Timer.periodic(keepalive, (_) => _broadcastRaw(': ka\n\n'));
    s.listen((req) => _handle(req).catchError((Object e) {
          errors++;
          stderr.writeln('hub: ${req.method} ${req.uri.path}: $e');
          // errori dopo l'invio delle intestazioni: si chiude e basta
          try {
            req.response.close();
          } catch (_) {}
        }));
    return s.port;
  }

  Future<void> close() async {
    _ka?.cancel();
    await _server?.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    final seg = req.uri.pathSegments;
    final res = req.response;
    if (seg.length == 2 && seg[0] == 'blobs') {
      final h = seg[1];
      if (!validHash(h)) return _err(res, 400, 'hash non valido');
      if (req.method == 'PUT') return _putBlob(req, h);
      if (req.method == 'GET' || req.method == 'HEAD') return _getBlob(req, h);
    } else if (req.method == 'GET' && req.uri.path == '/events') {
      return _events(req);
    } else if (req.method == 'GET' && req.uri.path == '/healthz') {
      res.write('ok');
      return res.close();
    } else if (req.method == 'GET' && req.uri.path == '/debug/stats') {
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(stats()));
      return res.close();
    } else if (req.method == 'POST' && req.uri.path == '/push/begin') {
      return _pushBegin(req);
    } else if (req.method == 'POST' &&
        seg.length == 3 &&
        seg[0] == 'push' &&
        seg[2] == 'commit') {
      return _pushCommit(req, seg[1]);
    }
    return _err(res, 404, 'non trovato');
  }

  Map<String, Object> stats() {
    final st = File('/proc/self/status').readAsLinesSync();
    int kb(String k) => int.parse(
        st.firstWhere((l) => l.startsWith(k)).split(RegExp(r'\s+'))[1]);
    return {
      'rssKb': kb('VmRSS:'),
      'hwmKb': kb('VmHWM:'),
      'sseClients': _sse.length,
      'activeUploads': activeUploads,
      'errors': errors,
    };
  }

  Future<void> _err(HttpResponse res, int code, String msg) async {
    res.statusCode = code;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode({'error': msg}));
    await res.close();
  }

  Future<void> _putBlob(HttpRequest req, String h) async {
    activeUploads++;
    if (_uploadSlots >= maxUploads) {
      final c = Completer<void>();
      _uploadWaiters.add(c);
      await c.future;
    } else {
      _uploadSlots++;
    }
    try {
      final n = await store.putBlob(h, req);
      req.response.statusCode = n < 0 ? 200 : 201;
      req.response.write(jsonEncode({'hash': h, 'written': max(n, 0)}));
      await req.response.close();
    } on HashMismatch catch (e) {
      await _err(req.response, 422, 'hash diverso: ${e.got}');
    } on HttpException {
      // client caduto a metà: lo store ha già tolto il temporaneo
    } finally {
      activeUploads--;
      // passa il posto al primo in coda (il contatore resta invariato)
      if (_uploadWaiters.isNotEmpty) {
        _uploadWaiters.removeAt(0).complete();
      } else {
        _uploadSlots--;
      }
    }
  }

  Future<void> _getBlob(HttpRequest req, String h) async {
    final res = req.response;
    final f = File(store.blobPath(h));
    final int len;
    try {
      len = await f.length();
    } on FileSystemException {
      return _err(res, 404, 'blob assente');
    }
    var start = 0, end = len - 1; // inclusivi
    final range = req.headers.value(HttpHeaders.rangeHeader);
    res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    res.headers.contentType = ContentType.binary;
    if (range != null) {
      final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range.trim());
      if (m == null || (m[1]!.isEmpty && m[2]!.isEmpty)) {
        return _rangeErr(res, len);
      }
      if (m[1]!.isEmpty) {
        start = max(0, len - int.parse(m[2]!)); // suffisso: ultimi n byte
      } else {
        start = int.parse(m[1]!);
        if (m[2]!.isNotEmpty) end = min(int.parse(m[2]!), len - 1);
      }
      if (start >= len || start > end) return _rangeErr(res, len);
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$len');
    }
    res.contentLength = end - start + 1;
    if (req.method == 'HEAD' || len == 0) return res.close();
    // openRead legge a blocchi da 64 KiB; addStream rispetta la backpressure
    // del socket, quindi la memoria non cresce con la dimensione del blob
    await res.addStream(f.openRead(start, end + 1));
    await res.close();
  }

  Future<void> _rangeErr(HttpResponse res, int len) async {
    res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
    res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$len');
    await res.close();
  }

  Future<void> _events(HttpRequest req) async {
    final res = req.response;
    res.bufferOutput = false;
    res.headers
      ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
      ..set(HttpHeaders.cacheControlHeader, 'no-cache')
      ..set('X-Accel-Buffering', 'no');
    res.write(': hello\n\n');
    await res.flush();
    _sse.add(res);
    // la connessione chiusa dal client chiude response.done
    res.done.whenComplete(() => _sse.remove(res)).ignore();
    req.drain<void>().whenComplete(() {}).ignore();
  }

  void _broadcastRaw(String s) {
    for (final r in _sse.toList()) {
      try {
        r.write(s);
      } catch (_) {
        _sse.remove(r);
      }
    }
  }

  void publish(String type, Object data) =>
      _broadcastRaw('id: ${++_eventId}\nevent: $type\ndata: ${jsonEncode(data)}\n\n');

  Future<Object?> _json(HttpRequest req) async =>
      jsonDecode(await utf8.decoder.bind(req).join());

  Future<void> _pushBegin(HttpRequest req) async {
    final body = await _json(req) as Map<String, Object?>;
    final blobs = (body['blobs'] as List).cast<String>();
    if (!blobs.every(validHash)) return _err(req.response, 400, 'hash non valido');
    final id = List.generate(8, (_) => _rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    _pushes[id] = blobs;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode({
      'id': id,
      'missing': [for (final b in blobs) if (!store.has(b)) b],
    }));
    await req.response.close();
  }

  Future<void> _pushCommit(HttpRequest req, String id) async {
    final blobs = _pushes[id];
    if (blobs == null) return _err(req.response, 404, 'push sconosciuto');
    final missing = [for (final b in blobs) if (!store.has(b)) b];
    if (missing.isNotEmpty) {
      return _err(req.response, 409, 'blob mancanti: ${missing.length}');
    }
    final body = await utf8.decoder.bind(req).join();
    await store.writeFileAtomic('${store.root}/manifests/$id.json', utf8.encode(body));
    _pushes.remove(id);
    publish('commit', {'push': id, 'blobs': blobs.length});
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode({'committed': id}));
    await req.response.close();
  }
}

/// ServerSocket che imposta SO_RCVBUF su ogni connessione accettata.
///
/// Misurato (README): dart:io legge dal socket TUTTI i byte disponibili in un
/// colpo solo (RawSocket.read() senza lunghezza). Con l'autotuning di Linux
/// (tcp_rmem max 32 MiB) una singola lettura arriva a decine di MiB: un pezzo
/// enorme, esterno all'heap Dart, vivo finché l'upload non l'ha copiato tutto.
/// Limitando il buffer di ricezione il pezzo massimo è ~2x[rcvBuf] e la
/// backpressure torna a funzionare a grana fine.
class _TunedServerSocket extends StreamView<Socket> implements ServerSocket {
  _TunedServerSocket(this._ss, int bytes)
      : super(_ss.map((s) {
          // SOL_SOCKET=1, SO_RCVBUF=8 su Linux (x86_64 e arm64: asm-generic)
          if (Platform.isLinux) {
            final v = ByteData(4)..setInt32(0, bytes, Endian.host);
            s.setRawOption(RawSocketOption(1, 8, v.buffer.asUint8List()));
          }
          return s;
        }));
  final ServerSocket _ss;
  @override
  InternetAddress get address => _ss.address;
  @override
  int get port => _ss.port;
  @override
  Future<ServerSocket> close() => _ss.close();
}
