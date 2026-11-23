// HttpHubApi su un trasporto finto: URL, `X-MineSync` sulle richieste che
// cambiano stato, decodifica delle risposte, errori in ApiError, hub
// offline, eventi dal vivo con riconnessione e `after`.
import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_hub_web/src/api/hub_api.dart';
import 'package:minesync_hub_web/src/api/http_hub_api.dart';
import 'package:minesync_hub_web/src/api/transport.dart';
import 'package:ms_protocol/ms_protocol.dart';

import 'support/fixtures.dart';

/// Richiesta ricevuta dal trasporto finto.
typedef Sent = ({String method, Uri url, Map<String, String> headers, String? body});

final class FakeTransport implements HubTransport {
  /// Risposta per "METODO /percorso" (senza query).
  final routes = <String, TransportResponse Function(Sent r)>{};
  final sent = <Sent>[];
  bool down = false;

  final opened = <Uri>[];
  final listeners = <EventSourceListener>[];
  int closed = 0;

  @override
  Future<TransportResponse> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final r = (method: method, url: url, headers: headers, body: body);
    sent.add(r);
    if (down) throw const TransportFailure('connection refused');
    final h = routes['$method ${url.path}'];
    if (h == null) {
      return TransportResponse(
        404,
        jsonEncode(const ApiError(ErrorCode.notFound, 'no such endpoint').toJson()),
      );
    }
    return h(r);
  }

  @override
  EventSourceConnection openEvents(
    Uri url,
    EventSourceListener listener, {
    List<String> eventTypes = const [],
  }) {
    opened.add(url);
    listeners.add(listener);
    return _Conn(this);
  }
}

final class _Conn implements EventSourceConnection {
  _Conn(this.t);
  final FakeTransport t;
  @override
  void close() => t.closed++;
}

TransportResponse ok(Object? j, [int status = 200]) => TransportResponse(status, jsonEncode(j));

void main() {
  late FakeTransport tr;
  late HttpHubApi api;

  setUp(() {
    tr = FakeTransport();
    api = HttpHubApi(tr, Uri.parse('http://192.0.2.1:8084/server/survival?x=1'));
  });

  test('GET /hub: URL sotto /api/v1, niente X-MineSync, decodifica', () async {
    tr.routes['GET /api/v1/hub'] = (_) => ok(sampleHub().toJson());
    final h = await api.hub();
    expect(h.name, 'Homelab');
    expect(h.me.name, 'alice');
    expect(tr.sent.single.url.toString(), 'http://192.0.2.1:8084/api/v1/hub');
    expect(tr.sent.single.headers.containsKey('X-MineSync'), isFalse);
  });

  test('spazi e dettagli, id codificati nel percorso', () async {
    tr.routes['GET /api/v1/spaces'] = (_) => ok({
      'spaces': [for (final s in sampleSpaces()) s.toJson()],
    });
    tr.routes['GET /api/v1/spaces/a%20b'] = (_) => ok({
      ...sampleSpaces().first.toJson(),
      'exclusions': ['logs/'],
      'ownExclusions': <String>[],
    });
    final list = await api.spaces();
    expect(list.map((s) => s.id), ['survival', 'creativo', 'avventura']);
    expect(list.first.lock!.ip, '192.0.2.10');
    final d = await api.space('a b');
    expect(d.exclusions, ['logs/']);
  });

  test('le richieste che cambiano stato portano X-MineSync: 1 e il corpo JSON', () async {
    tr.routes['POST /api/v1/spaces'] = (r) => ok({
      ...SpaceSummary(
        id: 'nuovo',
        name: (jsonDecode(r.body!) as Map)['name'] as String,
        profile: Profile.minecraft,
        createdAt: 0,
        head: null,
        lock: null,
      ).toJson(),
      'exclusions': <String>[],
      'ownExclusions': <String>[],
    }, 201);
    tr.routes['DELETE /api/v1/spaces/survival/lock'] = (_) => ok({'released': true});
    tr.routes['PATCH /api/v1/settings/sessions'] = (_) => ok({'x': 1});
    final d = await api.createSpace('Nuovo', Profile.generic);
    expect(d.summary.name, 'Nuovo');
    final create = tr.sent.last;
    expect(create.headers['X-MineSync'], '1');
    expect(create.headers['Content-Type'], 'application/json');
    expect(jsonDecode(create.body!), {'name': 'Nuovo', 'profile': 'generic'});

    await api.forceReleaseLock('survival');
    expect(tr.sent.last.headers['X-MineSync'], '1');
    expect(jsonDecode(tr.sent.last.body!), {'force': true});

    // risposta non valida per il modello: FormatException, non un valore inventato
    await expectLater(api.patchSettings('sessions', {'autosaveMinutes': 5}), throwsFormatException);
    expect(jsonDecode(tr.sent.last.body!), {'autosaveMinutes': 5});
  });

  test('errori: codice e dettagli da {"error": ...}, stato HTTP', () async {
    tr.routes['DELETE /api/v1/spaces/survival'] = (_) => TransportResponse(
      409,
      jsonEncode(
        const ApiError(
          ErrorCode.locked,
          'locked',
          details: {
            'lock': {'name': 'bob'},
          },
        ).toJson(),
      ),
    );
    final e = await api
        .deleteSpace('survival')
        .then<ApiError?>((_) => null, onError: (Object e) => e as ApiError);
    expect(e!.code, ErrorCode.locked);
    expect(e.status, 409);
    expect((e.details['lock']! as Map)['name'], 'bob');
  });

  test('errori senza corpo JSON: codice dallo stato HTTP', () async {
    tr.routes['GET /api/v1/hub'] = (_) => const TransportResponse(401, '');
    tr.routes['GET /api/v1/usage'] = (_) =>
        const TransportResponse(502, '<html>Bad gateway</html>');
    await expectLater(
      api.hub(),
      throwsA(isA<ApiError>().having((e) => e.code, 'code', ErrorCode.unauthenticated)),
    );
    await expectLater(
      api.usage(),
      throwsA(isA<ApiError>().having((e) => e.code, 'code', ErrorCode.upstream)),
    );
  });

  test('hub irraggiungibile: HubOffline', () async {
    tr.down = true;
    await expectLater(api.spaces(), throwsA(isA<HubOffline>()));
  });

  test('eventi: after e before con filtri; pagina con more', () async {
    tr.routes['GET /api/v1/events'] = (r) => ok({
      'events': [for (final e in sampleEvents().reversed.take(2)) e.toJson()],
      'last': 8,
      'oldest': 1,
      'more': true,
    });
    final p = await api.events(before: 9, limit: 2, space: 'survival', types: ['push', 'lock']);
    expect(p.events.map((e) => e.seq), [8, 7]);
    expect(p.more, isTrue);
    expect(p.oldest, 1);
    expect(tr.sent.last.url.queryParameters, {
      'before': '9',
      'limit': '2',
      'space': 'survival',
      'types': 'push,lock',
    });
  });

  test('download: elenco e URL /dl/<file> fuori da /api/v1', () async {
    tr.routes['GET /api/v1/dl'] = (_) => ok(sampleDownloads().toJson());
    final l = await api.downloads();
    expect(l.files, hasLength(3));
    expect(l.signedSums, isTrue);
    expect(
      api.downloadUrl('MineSync-0.1.0.dmg').toString(),
      'http://192.0.2.1:8084/dl/MineSync-0.1.0.dmg',
    );
    expect(api.iconUrl('survival').toString(), 'http://192.0.2.1:8084/api/v1/spaces/survival/icon');
    expect(
      api.zipUrl('survival', n: 41).toString(),
      'http://192.0.2.1:8084/api/v1/spaces/survival/generations/41/zip',
    );
  });

  test('ogni endpoint di Admin, storia e mondo ha il suo percorso', () async {
    Future<void> hit(Future<Object?> Function() f, String method, String path) async {
      await f().then<void>((_) {}, onError: (Object _) {});
      expect('${tr.sent.last.method} ${tr.sent.last.url.path}', '$method /api/v1/$path');
      if (method != 'GET') expect(tr.sent.last.headers['X-MineSync'], '1');
    }

    await hit(() => api.world('s'), 'GET', 'spaces/s/world');
    await hit(() => api.players('s'), 'GET', 'spaces/s/players');
    await hit(() => api.mods('s'), 'GET', 'spaces/s/mods');
    await hit(() => api.stats('s'), 'GET', 'spaces/s/stats');
    await hit(() => api.diff('s', 3, limit: 120), 'GET', 'spaces/s/generations/3/diff');
    await hit(() => api.freed('s', 3), 'GET', 'spaces/s/generations/3/freed');
    await hit(() => api.deleteGeneration('s', 3), 'DELETE', 'spaces/s/generations/3');
    await hit(() => api.restore('s', 3), 'POST', 'spaces/s/restore');
    await hit(
      () => api.restoreFile('s', const RestoreFileRequest(path: 'world/region/r.0.0.mca')),
      'POST',
      'spaces/s/restore-file',
    );
    await hit(() => api.portCheck('s'), 'POST', 'spaces/s/lock/port-check');
    await hit(() => api.gcPreview(space: 's', keep: 5), 'POST', 'spaces/s/gc/preview');
    await hit(() => api.gc(space: 's'), 'POST', 'spaces/s/gc');
    await hit(() => api.gcPreview(), 'POST', 'gc/preview');
    await hit(() => api.gc(keep: 3), 'POST', 'gc');
    await hit(() => api.usage(), 'GET', 'usage');
    await hit(() => api.testExclusion(path: 'logs/'), 'POST', 'exclusions/test');
    await hit(() => api.members(), 'GET', 'members');
    await hit(() => api.setRole('b2', MemberRole.admin), 'PUT', 'members/b2/role');
    await hit(() => api.refreshMembers(), 'POST', 'members/refresh');
    await hit(() => api.system(), 'GET', 'system');
    await hit(() => api.settings(), 'GET', 'settings');
    await hit(() => api.telegram(), 'GET', 'telegram');
    await hit(() => api.patchTelegram(const TelegramPatch(enabled: false)), 'PATCH', 'telegram');
    await hit(() => api.testTelegram(spaceId: 's'), 'POST', 'telegram/test');
    await hit(() => api.findTelegramChats(), 'POST', 'telegram/find-chat');
    await hit(() => api.updateSpace('s', const SpacePatch(name: 'X')), 'PATCH', 'spaces/s');
    await hit(() => api.generations('s', before: 10), 'GET', 'spaces/s/generations');
    await hit(() => api.generation('s'), 'GET', 'spaces/s/generations/head');
  });

  group('eventi dal vivo', () {
    String frame(HubEvent e) => jsonEncode(e.toJson());

    test('decodifica, scarta i doppioni e gli eventi non validi', () async {
      final got = <HubEvent>[];
      final sub = api.eventStream(after: 5).listen(got.add);
      await Future<void>.delayed(Duration.zero);
      expect(tr.opened.single.queryParameters['after'], '5');
      final l = tr.listeners.single;
      l.onOpen();
      for (final e in sampleEvents()) {
        l.onMessage('${e.seq}', frame(e));
      }
      l.onMessage(null, '{non json');
      l.onMessage('99', jsonEncode({'type': 'push'}));
      await Future<void>.delayed(Duration.zero);
      expect(got.map((e) => e.seq), [6, 7, 8]);
      await sub.cancel();
      expect(tr.closed, 1);
    });

    test('il browser riprova da solo; se chiude si riapre con after', () {
      fakeAsync((async) {
        final errors = <Object>[];
        final sub = api.eventStream().listen((_) {}, onError: errors.add);
        async.flushMicrotasks();
        final l = tr.listeners.single;
        l.onMessage('7', frame(sampleEvents()[6]));
        // caduta con riconnessione automatica: errore segnalato, nessuna riapertura
        l.onError(closed: false);
        async.flushMicrotasks();
        expect(errors, hasLength(1));
        expect(tr.opened, hasLength(1));
        // chiusa: si riapre dopo 1 s riprendendo da dopo il 7
        l.onError(closed: true);
        async.elapse(const Duration(milliseconds: 999));
        expect(tr.opened, hasLength(1));
        async.elapse(const Duration(milliseconds: 1));
        expect(tr.opened, hasLength(2));
        expect(tr.opened.last.queryParameters['after'], '7');
        // seconda chiusura di fila: 2 s
        tr.listeners.last.onError(closed: true);
        async.elapse(const Duration(seconds: 1));
        expect(tr.opened, hasLength(2));
        async.elapse(const Duration(seconds: 1));
        expect(tr.opened, hasLength(3));
        unawaited(sub.cancel());
        async.elapse(const Duration(minutes: 1));
        expect(tr.opened, hasLength(3));
      });
    });
  });
}
