// Client di carico per lo spike (compilato AOT come lo server).
//
//   bench latency <base> <hash> <secondi>     GET piccola in loop: p50/p99/max
//   bench sse <base> <n> <secondi>            n client SSE: keepalive/eventi ricevuti
//   bench abort <base> <hash> <totale> <inviati>
//       PUT con Content-Length=<totale>, invia <inviati> byte e chiude il socket
//   bench range <base> <hash> <file locale>   verifica Range contro il file
//   bench commit <base> <hash...>             push begin -> commit (evento SSE)
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

Future<void> main(List<String> a) async {
  switch (a.first) {
    case 'latency':
      return _latency(Uri.parse(a[1]), a[2], int.parse(a[3]));
    case 'sse':
      return _sse(Uri.parse(a[1]), int.parse(a[2]), int.parse(a[3]));
    case 'abort':
      return _abort(Uri.parse(a[1]), a[2], int.parse(a[3]), int.parse(a[4]));
    case 'range':
      return _range(Uri.parse(a[1]), a[2], a[3]);
    case 'commit':
      return _commit(Uri.parse(a[1]), a.sublist(2));
  }
  stderr.writeln('comando sconosciuto');
  exit(2);
}

Future<void> _latency(Uri base, String hash, int secs) async {
  final c = HttpClient()..maxConnectionsPerHost = 1;
  final lat = <int>[];
  var errors = 0;
  final end = DateTime.now().add(Duration(seconds: secs));
  while (DateTime.now().isBefore(end)) {
    final sw = Stopwatch()..start();
    try {
      final r = await (await c.getUrl(base.resolve('/blobs/$hash'))).close();
      await r.drain<void>();
      if (r.statusCode != 200) errors++;
    } catch (_) {
      errors++;
    }
    lat.add(sw.elapsedMicroseconds);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  c.close();
  lat.sort();
  double p(double q) => lat[((lat.length - 1) * q).round()] / 1000;
  print(jsonEncode({
    'n': lat.length,
    'errors': errors,
    'p50ms': p(0.5),
    'p99ms': p(0.99),
    'maxms': lat.last / 1000,
  }));
}

Future<void> _sse(Uri base, int n, int secs) async {
  var ka = 0, events = 0, open = 0, failed = 0;
  final clients = <HttpClient>[];
  final subs = <StreamSubscription<String>>[];
  for (var i = 0; i < n; i++) {
    final c = HttpClient();
    clients.add(c);
    try {
      final r = await (await c.getUrl(base.resolve('/events'))).close();
      if (r.statusCode != 200) {
        failed++;
        continue;
      }
      open++;
      subs.add(r.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
        if (l.startsWith(': ka')) ka++;
        if (l.startsWith('event: ')) events++;
      }, onError: (_) {}));
    } catch (_) {
      failed++;
    }
  }
  stderr.writeln('sse: $open aperti, $failed falliti');
  await Future<void>.delayed(Duration(seconds: secs));
  print(jsonEncode({'open': open, 'failed': failed, 'keepalives': ka, 'events': events}));
  for (final s in subs) {
    await s.cancel();
  }
  for (final c in clients) {
    c.close(force: true);
  }
}

Future<void> _abort(Uri base, String hash, int total, int sent) async {
  final s = await Socket.connect(base.host, base.port);
  s.write('PUT /blobs/$hash HTTP/1.1\r\nHost: ${base.host}\r\n'
      'Content-Length: $total\r\nContent-Type: application/octet-stream\r\n\r\n');
  final buf = Uint8List(1 << 20);
  var left = sent;
  while (left > 0) {
    final n = left < buf.length ? left : buf.length;
    s.add(Uint8List.sublistView(buf, 0, n));
    await s.flush();
    left -= n;
  }
  await Future<void>.delayed(const Duration(milliseconds: 300));
  s.destroy(); // il client "cade" a metà upload
  print(jsonEncode({'sent': sent, 'total': total}));
}

Future<void> _range(Uri base, String hash, String path) async {
  final raf = await File(path).open();
  final len = await raf.length();
  final c = HttpClient();
  final cases = <String, (int, int)>{
    'bytes=0-0': (0, 0),
    'bytes=100-199': (100, 199),
    'bytes=${len - 10}-': (len - 10, len - 1),
    'bytes=-4096': (len - 4096, len - 1),
    'bytes=${len ~/ 2}-${len ~/ 2 + (1 << 20) - 1}': (len ~/ 2, len ~/ 2 + (1 << 20) - 1),
  };
  var ok = true;
  for (final e in cases.entries) {
    final rq = await c.getUrl(base.resolve('/blobs/$hash'));
    rq.headers.set('Range', e.key);
    final r = await rq.close();
    final b = BytesBuilder(copy: false);
    await for (final ch in r) {
      b.add(ch);
    }
    final got = b.takeBytes();
    await raf.setPosition(e.value.$1);
    final want = await raf.read(e.value.$2 - e.value.$1 + 1);
    final pass = r.statusCode == 206 &&
        r.headers.value('content-range') == 'bytes ${e.value.$1}-${e.value.$2}/$len' &&
        _eq(got, want);
    ok &= pass;
    print('range ${e.key}: ${r.statusCode} ${pass ? 'OK' : 'FAIL'}');
  }
  final rq = await c.getUrl(base.resolve('/blobs/$hash'));
  rq.headers.set('Range', 'bytes=$len-');
  final r = await rq.close();
  await r.drain<void>();
  final pass416 = r.statusCode == 416;
  ok &= pass416;
  print('range bytes=$len-: ${r.statusCode} ${pass416 ? 'OK' : 'FAIL'}');
  c.close();
  await raf.close();
  exit(ok ? 0 : 1);
}

bool _eq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Future<void> _commit(Uri base, List<String> hashes) async {
  final c = HttpClient();
  Future<Map<String, Object?>> post(String p, Object body) async {
    final rq = await c.postUrl(base.resolve(p));
    rq.write(jsonEncode(body));
    final r = await rq.close();
    final s = await utf8.decoder.bind(r).join();
    if (r.statusCode >= 300) throw StateError('$p: ${r.statusCode} $s');
    return jsonDecode(s) as Map<String, Object?>;
  }

  final b = await post('/push/begin', {'blobs': hashes});
  final c2 = await post('/push/${b['id']}/commit', {
    'files': {for (final h in hashes) 'f-${h.substring(0, 8)}': h},
  });
  c.close();
  print(jsonEncode({'begin': b, 'commit': c2}));
}
