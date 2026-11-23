// Supporto ai test dei percorsi fuori da /api/v1 (web UI e /dl): richieste
// senza decompressione automatica e richieste grezze sul socket, per mandare
// percorsi che Uri normalizzerebbe.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:minesync_hub/minesync_hub.dart';

import 'support.dart';

/// Hub di test con MINESYNC_WEB e/o MINESYNC_DL.
Future<TestHub> startHub({String? web, String? dl}) => TestHub.start(
  config: (data) => HubConfig(
    dataDir: data,
    address: InternetAddress.loopbackIPv4,
    port: 0,
    admins: const ['carol'],
    keepAlive: const Duration(milliseconds: 200),
    webDir: web,
    dlDir: dl,
  ),
);

/// GET (o [method]) di [path] dalla radice dell'hub, da [from] (127.0.0.1 =
/// alice; 127.0.0.9 non è un membro). Niente decompressione automatica.
Future<Res> fetch(
  TestHub t,
  String path, {
  String method = 'GET',
  String from = '127.0.0.1',
  Map<String, String> headers = const {},
}) async {
  final c = HttpClient()
    ..autoUncompress = false
    ..connectionFactory = (uri, _, _) => Socket.startConnect(
      InternetAddress.loopbackIPv4,
      uri.port,
      sourceAddress: InternetAddress(from),
    );
  try {
    final r = await c.openUrl(method, Uri.parse('http://127.0.0.1:${t.hub.port}$path'));
    // senza Accept-Encoding esplicito HttpClient chiederebbe gzip da solo
    r.headers.removeAll(HttpHeaders.acceptEncodingHeader);
    headers.forEach(r.headers.set);
    final res = await r.close();
    final b = BytesBuilder(copy: false);
    await for (final x in res) {
      b.add(x);
    }
    return Res(res.statusCode, res.headers, b.takeBytes());
  } finally {
    c.close(force: true);
  }
}

/// Stato HTTP e risposta intera di una richiesta scritta a mano: [path]
/// arriva al server così com'è (`..`, `%2F`, `%2e%2e`).
Future<(int, String)> rawGet(TestHub t, String path) async {
  final s = await Socket.connect(InternetAddress.loopbackIPv4, t.hub.port);
  s.write('GET $path HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n');
  await s.flush();
  final head = await utf8.decoder.bind(s).join();
  s.destroy();
  final m = RegExp(r'^HTTP/1\.1 (\d{3})').firstMatch(head);
  return (m == null ? -1 : int.parse(m[1]!), head);
}

/// Scrive [files] (percorso relativo → contenuto) sotto [dir].
Future<void> writeTree(Directory dir, Map<String, Object> files) async {
  for (final e in files.entries) {
    final f = File('${dir.path}/${e.key}');
    await f.parent.create(recursive: true);
    final v = e.value;
    await f.writeAsBytes(v is String ? utf8.encode(v) : v as List<int>);
  }
}
