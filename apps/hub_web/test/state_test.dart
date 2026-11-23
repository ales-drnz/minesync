// HubState: connessione (online, offline con nuovi tentativi, accesso
// negato), latenza, eventi recenti e dal vivo, pagine precedenti, lingua e
// tema salvati nel browser.
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_hub_web/src/api/hub_api.dart';
import 'package:minesync_hub_web/src/state/hub_state.dart';
import 'package:ms_l10n/ms_l10n.dart';
import 'package:ms_protocol/ms_protocol.dart';

import 'support/harness.dart';

HubState fresh(FakeHubApi api, {FakePlatform? platform}) => HubState(
  HubDeps(
    api: api,
    platform: platform ?? FakePlatform(),
    clock: () => testNow,
    pollEvery: const Duration(seconds: 15),
    retryEvery: const Duration(seconds: 5),
  ),
);

void main() {
  test('avvio: hub, server, attività recente e flusso dal vivo dopo l\'ultimo seq', () {
    fakeAsync((async) {
      final api = FakeHubApi();
      final s = fresh(api);
      expect(s.connection, HubConnection.connecting);
      s.start();
      async.flushMicrotasks();
      expect(s.connection, HubConnection.online);
      expect(s.hub!.name, 'Homelab');
      expect(s.spaces, hasLength(3));
      expect(s.events.map((e) => e.seq).first, 8);
      expect(api.calls, contains('events after=null before=9007199254740991'));
      expect(api.streamAfter, 8);
      expect(s.latencyMs, isNotNull);
      s.dispose();
    });
  });

  test('evento dal vivo: in cima al feed, server riletti, ruolo → GET /hub', () {
    fakeAsync((async) {
      final api = FakeHubApi();
      final s = fresh(api)..start();
      async.flushMicrotasks();
      api.calls.clear();
      api.live.add(
        HubEvent(
          seq: 9,
          ts: at(17, 59),
          type: EventType.memberRole,
          actor: 'alice',
          data: const {'member': 'bob', 'role': 'admin'},
        ),
      );
      async.flushMicrotasks();
      expect(s.events.first.seq, 9);
      expect(api.calls, contains('hub'));
      async.elapse(const Duration(milliseconds: 300));
      expect(api.calls, contains('spaces'));
      s.dispose();
    });
  });

  test('hub offline: banner, nuovo tentativo ogni 5 s, poi di nuovo online', () {
    fakeAsync((async) {
      final api = FakeHubApi()..failWith = const HubOffline('down');
      final s = fresh(api)..start();
      async.flushMicrotasks();
      expect(s.connection, HubConnection.offline);
      expect(s.offlineSince, testNow);
      api.calls.clear();
      async.elapse(const Duration(seconds: 5));
      expect(api.calls, ['hub']);
      api.failWith = null;
      async.elapse(const Duration(seconds: 5));
      expect(s.connection, HubConnection.online);
      expect(s.offlineSince, isNull);
      s.dispose();
    });
  });

  test('401: accesso negato, nessun nuovo tentativo da solo; Riprova', () {
    fakeAsync((async) {
      final api = FakeHubApi()..failWith = const ApiError(ErrorCode.unauthenticated, 'x');
      final s = fresh(api)..start();
      async.flushMicrotasks();
      expect(s.connection, HubConnection.denied);
      api.calls.clear();
      async.elapse(const Duration(minutes: 1));
      expect(api.calls, isEmpty);
      api.failWith = null;
      s.retry();
      async.flushMicrotasks();
      expect(s.connection, HubConnection.online);
      s.dispose();
    });
  });

  test('poll: GET /hub ogni 15 s mentre è online', () {
    fakeAsync((async) {
      final api = FakeHubApi();
      final s = fresh(api)..start();
      async.flushMicrotasks();
      api.calls.clear();
      async.elapse(const Duration(seconds: 15));
      expect(api.calls, ['hub']);
      s.dispose();
    });
  });

  test('pagine precedenti: before = seq più vecchio in memoria', () async {
    final older = [
      for (var i = 1; i <= 120; i++)
        HubEvent(seq: i, ts: at(10, 0) + i, type: EventType.push, data: {'n': i}),
    ];
    final api = FakeHubApi(events: older);
    final s = fresh(api);
    addTearDown(s.dispose);
    s.debugSet(events: older.sublist(70), eventsMore: true);
    expect(await s.loadOlderEvents(), eventPageSize);
    expect(api.calls.last, 'events after=null before=71');
    expect(s.events.last.seq, 21);
    expect(s.eventsMore, isTrue);
    await s.loadOlderEvents();
    expect(s.events.last.seq, 1);
    expect(s.eventsMore, isFalse);
  });

  group('lingua', () {
    HubState withLangs(List<String> langs, {String hubLang = 'auto', Map<String, String>? prefs}) {
      final s = fresh(
        FakeHubApi(),
        platform: FakePlatform(languages: langs, prefs: prefs),
      );
      addTearDown(s.dispose);
      s.debugSet(hub: sampleHub(language: hubLang));
      return s;
    }

    test('dal browser se l\'hub è su auto, inglese se sconosciuta', () {
      expect(withLangs(['it-IT', 'en']).lang, Lang.it);
      expect(withLangs(['en-GB']).lang, Lang.en);
      expect(withLangs(['de-DE', 'fr']).lang, Lang.en);
      expect(withLangs(['de-DE', 'it']).lang, Lang.it);
    });

    test('la lingua dell\'hub vince sul browser, la scelta salvata su tutto', () {
      expect(withLangs(['en-US'], hubLang: 'it').lang, Lang.it);
      final s = withLangs(['en-US'], hubLang: 'it', prefs: {PrefKeys.lang: 'en'});
      expect(s.lang, Lang.en);
      s.setLang(null);
      expect(s.lang, Lang.it);
      expect(fakePlatform(s).prefs.containsKey(PrefKeys.lang), isFalse);
    });

    test('setLang salva nel browser', () {
      final s = withLangs(['it']);
      s.setLang(Lang.en);
      expect(fakePlatform(s).prefs[PrefKeys.lang], 'en');
    });
  });

  group('tema', () {
    test('sistema di default, scelta salvata e riletta', () {
      final p = FakePlatform();
      final s = fresh(FakeHubApi(), platform: p);
      addTearDown(s.dispose);
      expect(s.themeChoice, ThemeChoice.system);
      expect(s.brightnessFor(Brightness.dark), Brightness.dark);
      s.setTheme(ThemeChoice.light);
      expect(p.prefs[PrefKeys.theme], 'light');
      expect(s.brightnessFor(Brightness.dark), Brightness.light);
      final again = fresh(FakeHubApi(), platform: p);
      addTearDown(again.dispose);
      expect(again.themeChoice, ThemeChoice.light);
      again.setTheme(ThemeChoice.system);
      expect(p.prefs.containsKey(PrefKeys.theme), isFalse);
    });

    test('storage bloccato: niente errori, la scelta vale per la visita', () {
      final s = fresh(FakeHubApi(), platform: FakePlatform(storageBroken: true));
      addTearDown(s.dispose);
      s.setTheme(ThemeChoice.dark);
      expect(s.themeChoice, ThemeChoice.dark);
      s.setLang(Lang.it);
      expect(s.lang, Lang.it);
    });
  });
}
