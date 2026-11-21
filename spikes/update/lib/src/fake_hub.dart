// Hub finto: server HTTP statico su una cartella (GET soltanto), più
// /api/ping. Nessuna dipendenza oltre dart:io.
import 'dart:io';

import 'package:path/path.dart' as p;

Future<HttpServer> startFakeHub(String dir, {int port = 0, void Function(String)? log}) async {
  final root = p.canonicalize(dir);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  server.listen((req) async {
    final res = req.response;
    try {
      final path = Uri.decodeComponent(req.uri.path);
      if (req.method != 'GET') {
        res.statusCode = HttpStatus.methodNotAllowed;
      } else if (path == '/api/ping') {
        res.write('pong');
      } else {
        final f = File(p.normalize(p.join(root, path.replaceFirst(RegExp('^/+'), ''))));
        if (!p.isWithin(root, f.path) || !await f.exists()) {
          res.statusCode = HttpStatus.notFound;
        } else {
          res.contentLength = await f.length();
          await res.addStream(f.openRead());
        }
      }
      log?.call('${req.method} $path -> ${res.statusCode}');
    } catch (e) {
      // client disconnesso a metà (il test uccide l'app durante il download)
    } finally {
      try {
        await res.close();
      } catch (_) {}
    }
  });
  return server;
}
