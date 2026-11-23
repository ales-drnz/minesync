// HubTransport sopra dart:io, solo per il test di contratto: richieste HTTP
// vere verso un hub in-process e un lettore SSE minimo (righe `id:` e
// `data:`, eventi separati da una riga vuota). Ogni client si collega da un
// indirizzo di loopback scelto, così l'hub lo riconosce come un membro.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:minesync_hub_web/src/api/transport.dart';

final class IoTransport implements HubTransport {
  IoTransport(String sourceIp) : _client = _clientFrom(sourceIp);

  static HttpClient _clientFrom(String ip) {
    final c = HttpClient();
    c.connectionFactory = (uri, proxyHost, proxyPort) => Socket.startConnect(
      InternetAddress.loopbackIPv4,
      uri.port,
      sourceAddress: InternetAddress(ip),
    );
    return c;
  }

  final HttpClient _client;
  final _open = <_IoEvents>[];

  @override
  Future<TransportResponse> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    try {
      final req = await _client.openUrl(method, url);
      headers.forEach(req.headers.set);
      if (body != null) {
        final b = utf8.encode(body);
        req.contentLength = b.length;
        req.add(b);
      }
      final res = await req.close();
      final bytes = <int>[];
      await for (final c in res) {
        bytes.addAll(c);
      }
      // lo ZIP non è testo: basta che non rompa la decodifica
      final text = utf8.decode(bytes, allowMalformed: true);
      final h = <String, String>{};
      res.headers.forEach((k, v) => h[k.toLowerCase()] = v.join(','));
      return TransportResponse(res.statusCode, text, headers: h);
    } on SocketException catch (e) {
      throw TransportFailure('$e');
    } on HttpException catch (e) {
      throw TransportFailure('$e');
    }
  }

  @override
  EventSourceConnection openEvents(
    Uri url,
    EventSourceListener listener, {
    List<String> eventTypes = const [],
  }) {
    final c = _IoEvents(this, listener);
    _open.add(c);
    unawaited(c.start(url));
    return c;
  }

  /// Chiude le connessioni SSE rimaste e il client.
  Future<void> close() async {
    for (final c in _open.toList()) {
      c.close();
    }
    _client.close(force: true);
  }
}

final class _IoEvents implements EventSourceConnection {
  _IoEvents(this.t, this.listener);

  final IoTransport t;
  final EventSourceListener listener;
  StreamSubscription<String>? _sub;
  HttpClientResponse? _res;
  bool _closed = false;

  Future<void> start(Uri url) async {
    try {
      final req = await t._client.getUrl(url);
      req.headers.set('Accept', 'text/event-stream');
      final res = _res = await req.close();
      if (_closed) {
        await res.detachSocket().then((s) => s.destroy());
        return;
      }
      if (res.statusCode != 200) {
        await res.drain<void>();
        listener.onError(closed: true);
        return;
      }
      listener.onOpen();
      String? id;
      final data = <String>[];
      _sub = res
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              if (line.isEmpty) {
                if (data.isNotEmpty) listener.onMessage(id, data.join('\n'));
                data.clear();
                return;
              }
              if (line.startsWith(':')) return;
              final i = line.indexOf(':');
              final field = i < 0 ? line : line.substring(0, i);
              var value = i < 0 ? '' : line.substring(i + 1);
              if (value.startsWith(' ')) value = value.substring(1);
              if (field == 'id') id = value;
              if (field == 'data') data.add(value);
            },
            onError: (Object _) {
              if (!_closed) listener.onError(closed: true);
            },
            onDone: () {
              if (!_closed) listener.onError(closed: true);
            },
          );
    } on Object {
      if (!_closed) listener.onError(closed: true);
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    t._open.remove(this);
    unawaited(_sub?.cancel());
    final r = _res;
    if (r != null && _sub == null) unawaited(r.drain<void>().catchError((Object _) {}));
  }
}
