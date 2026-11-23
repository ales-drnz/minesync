// Hub finto per i test: serve una cartella sotto /dl/ (solo GET) e ricorda
// le richieste. Nessuna dipendenza oltre dart:io.
import 'dart:io';

import 'package:path/path.dart' as p;

final class FakeHub {
  FakeHub._(this._server, this.root);

  final HttpServer _server;

  /// Cartella servita come /dl/.
  final String root;

  /// Richieste ricevute ("GET /dl/... -> 200").
  final requests = <String>[];

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}/');

  static Future<FakeHub> start(String root) async {
    await Directory(root).create(recursive: true);
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final hub = FakeHub._(s, p.canonicalize(root));
    s.listen(hub._handle);
    return hub;
  }

  bool requested(String part) => requests.any((r) => r.contains(part));

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final path = Uri.decodeComponent(req.uri.path);
      if (req.method != 'GET' || !path.startsWith('/dl/')) {
        res.statusCode = HttpStatus.notFound;
      } else {
        final f = File(p.normalize(p.join(root, path.substring('/dl/'.length))));
        if (!p.isWithin(root, f.path) || !await f.exists()) {
          res.statusCode = HttpStatus.notFound;
        } else {
          res.contentLength = await f.length();
          await res.addStream(f.openRead());
        }
      }
      requests.add('${req.method} $path -> ${res.statusCode}');
    } on Object {
      // client disconnesso a metà (il test uccide l'app durante il download)
    } finally {
      try {
        await res.close();
      } on Object {
        // idem
      }
    }
  }

  Future<void> close() => _server.close(force: true);
}
