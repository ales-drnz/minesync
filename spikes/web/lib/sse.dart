// Feed eventi via Server-Sent Events con l'EventSource del browser
// (package:web). Riconnessione automatica gestita dal browser.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

class HubEvent {
  HubEvent(this.id, this.kind, this.who, this.what, this.at);
  final int id;
  final String kind;
  final String who;
  final String what;
  final DateTime at;

  factory HubEvent.fromJson(Map<String, dynamic> j) => HubEvent(
      j['id'] as int,
      j['kind'] as String,
      j['who'] as String,
      j['what'] as String,
      DateTime.parse(j['at'] as String).toLocal());
}

Stream<HubEvent> hubEvents(String url) {
  late web.EventSource es;
  late StreamController<HubEvent> ctl;
  ctl = StreamController<HubEvent>(
    onListen: () {
      es = web.EventSource(url);
      es.onmessage = ((web.MessageEvent e) {
        final data = (e.data as JSString).toDart;
        ctl.add(HubEvent.fromJson(jsonDecode(data) as Map<String, dynamic>));
      }).toJS;
    },
    onCancel: () => es.close(),
  );
  return ctl.stream;
}
