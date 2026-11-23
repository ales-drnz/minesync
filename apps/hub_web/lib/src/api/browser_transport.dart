// Trasporto del browser: fetch (stessa origine, niente cache) con timeout
// e EventSource. Solo per il web: i test sulla VM usano un finto.
import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'transport.dart';

final class BrowserTransport implements HubTransport {
  BrowserTransport({this.timeout = const Duration(seconds: 20)});

  /// Oltre questo tempo senza risposta la richiesta si annulla.
  final Duration timeout;

  @override
  Future<TransportResponse> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final h = web.Headers();
    for (final e in headers.entries) {
      h.append(e.key, e.value);
    }
    final abort = web.AbortController();
    final timer = Timer(timeout, () => abort.abort());
    try {
      final res = await web.window
          .fetch(
            url.toString().toJS,
            web.RequestInit(
              method: method,
              headers: h,
              body: body?.toJS,
              credentials: 'same-origin',
              cache: 'no-store',
              redirect: 'error',
              signal: abort.signal,
            ),
          )
          .toDart;
      final text = (await res.text().toDart).toDart;
      final out = <String, String>{};
      final ct = res.headers.get('content-type');
      if (ct != null) out['content-type'] = ct;
      return TransportResponse(res.status, text, headers: out);
    } on Object catch (e) {
      // TypeError di fetch (rete) o AbortError (timeout)
      throw TransportFailure('$e');
    } finally {
      timer.cancel();
    }
  }

  @override
  EventSourceConnection openEvents(
    Uri url,
    EventSourceListener listener, {
    List<String> eventTypes = const [],
  }) {
    final es = web.EventSource(url.toString());
    void message(web.MessageEvent e) {
      final data = e.data;
      if (data == null || !data.isA<JSString>()) return;
      final id = e.lastEventId;
      listener.onMessage(id.isEmpty ? null : id, (data as JSString).toDart);
    }

    final onMessage = message.toJS;
    // l'hub manda `event: <tipo>`: onmessage da solo non li riceverebbe
    for (final t in ['message', ...eventTypes]) {
      es.addEventListener(t, onMessage);
    }
    es.onopen = ((web.Event _) => listener.onOpen()).toJS;
    es.onerror = ((web.Event _) {
      listener.onError(closed: es.readyState == web.EventSource.CLOSED);
    }).toJS;
    return _BrowserEvents(es);
  }
}

final class _BrowserEvents implements EventSourceConnection {
  _BrowserEvents(this.es);
  final web.EventSource es;

  @override
  void close() => es.close();
}
