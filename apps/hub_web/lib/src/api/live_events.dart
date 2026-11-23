// Eventi dal vivo via SSE con riconnessione. Il browser riprova da solo
// (con Last-Event-ID, perché l'hub manda `id:`) finché la connessione è solo
// caduta; se invece la chiude (risposta di errore, hub riavviato in modo
// brusco) si riapre da qui con `?after=<ultimo seq>`, aspettando sempre di
// più (1 s, 2 s, 4 s… fino a 30 s). Gli eventi già visti si scartano.
import 'dart:async';
import 'dart:convert';

import 'package:ms_protocol/ms_protocol.dart';

import 'hub_api.dart';
import 'transport.dart';

/// Attese tra un tentativo e l'altro, poi resta sull'ultima.
const liveRetryDelays = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 15),
  Duration(seconds: 30),
];

/// Stream di [HubEvent] su [transport]: `<base>events/stream`.
Stream<HubEvent> liveEvents(
  HubTransport transport,
  Uri streamUrl, {
  int? after,
  List<Duration> retryDelays = liveRetryDelays,
}) {
  late final _Live live;
  final out = StreamController<HubEvent>(onListen: () => live.open(), onCancel: () => live.stop());
  live = _Live(transport, streamUrl, out, after, retryDelays);
  return out.stream;
}

final class _Live implements EventSourceListener {
  _Live(this.transport, this.url, this.out, this.lastSeq, this.delays);

  final HubTransport transport;
  final Uri url;
  final StreamController<HubEvent> out;
  final List<Duration> delays;

  int? lastSeq;
  EventSourceConnection? _conn;
  Timer? _retry;
  int _failures = 0;
  bool _stopped = false;

  void open() {
    if (_stopped) return;
    final q = {...url.queryParameters, 'after': ?lastSeq?.toString()};
    _conn = transport.openEvents(
      url.replace(queryParameters: q.isEmpty ? null : q),
      this,
      eventTypes: EventType.all,
    );
  }

  void stop() {
    _stopped = true;
    _retry?.cancel();
    _conn?.close();
    _conn = null;
  }

  @override
  void onOpen() => _failures = 0;

  @override
  void onMessage(String? id, String data) {
    if (_stopped) return;
    final HubEvent e;
    try {
      e = HubEvent.fromJson(jsonDecode(data));
    } on FormatException {
      return; // evento non riconosciuto: si salta
    }
    if (lastSeq != null && e.seq <= lastSeq!) return;
    lastSeq = e.seq;
    out.add(e);
  }

  @override
  void onError({required bool closed}) {
    if (_stopped) return;
    out.addError(const HubOffline('events stream interrupted'));
    if (!closed) return; // il browser riprova da solo
    _conn?.close();
    _conn = null;
    final d = delays[_failures.clamp(0, delays.length - 1)];
    _failures++;
    _retry?.cancel();
    _retry = Timer(d, open);
  }
}
