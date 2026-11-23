// Lo stream SSE dell'hub letto dal client di ms_core (usato dall'app).
import 'dart:async';

import 'package:ms_core/ms_core.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('HubClient.eventStream riceve gli eventi e riprende da Last-Event-ID', () async {
    final h = await TestHub.start();
    addTearDown(h.close);
    final c = HubClient(Uri.parse('http://127.0.0.1:${h.hub.port}/'), http: h.client('carol'));
    final got = <HubEvent>[];
    final first = Completer<void>();
    final sub = c.eventStream().listen((e) {
      got.add(e);
      if (!first.isCompleted) first.complete();
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await c.createSpace('Survival', Profile.minecraft);
    await first.future.timeout(const Duration(seconds: 5));
    await sub.cancel();
    expect(got.first.type, 'space.create');
    expect(got.first.space, 'survival');

    // ripresa: solo gli eventi dopo l'ultimo visto
    await c.createSpace('Creativo', Profile.generic);
    final resumed = await c
        .eventStream(after: got.first.seq)
        .first
        .timeout(const Duration(seconds: 5));
    expect(resumed.space, 'creativo');
  });
}
