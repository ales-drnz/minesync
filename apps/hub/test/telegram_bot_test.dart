// Comportamento del bot Telegram (B-TG-01…22) contro un Telegram finto.
import 'dart:async';

import 'package:minesync_hub/src/telegram/messages.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:test/test.dart';

import 'telegram_support.dart';

const minute = Duration(minutes: 1);

void main() {
  group('apertura e chiusura', () {
    late BotRig r;
    setUp(() => r = BotRig());
    tearDown(() => r.close());

    test('B-TG-01 un lock di gioco annuncia l\'apertura, il rilascio la chiusura', () async {
      r.world.play('survival', 'alice');
      var t = await r.texts();
      expect(t, hasLength(1));
      expect(t[0], contains('<b>Survival</b> è aperto'));
      expect(t[0], contains('hosta <b>alice</b>'));
      expect(t[0], contains('zerotier.survival.mc.test'));
      expect(t[0], contains('192.0.2.10'));
      for (var i = 0; i < 13; i++) {
        r.world.emit(EventType.push, space: 'survival'); // salva ogni 5 minuti
        await r.after(const Duration(minutes: 5));
      }
      r.world.release('survival');
      t = await r.texts();
      expect(t, hasLength(2));
      expect(t[1], contains('<b>Survival</b> è chiuso'));
      expect(t[1], contains('sessione di 1h 5m'));
    });

    test('B-TG-02 un lock scaduto dà una sola chiusura «non risponde»', () async {
      r.world.play('survival', 'alice');
      r.world.setStale('survival', true);
      await r.after(const Duration(seconds: 30));
      await r.after(const Duration(seconds: 30));
      await r.after(const Duration(minutes: 5));
      final t = await r.texts();
      expect(t, hasLength(2));
      expect(t[1], contains('è chiuso'));
      expect(t[1], contains('il client di alice non risponde più'));
    });

    test('B-TG-04 ogni riga con emoji, mai il LAN, porta solo se non predefinita', () async {
      r.world.play('survival', 'alice', port: 25565);
      r.world.play('creativo', 'bob', port: 25570);
      r.world.play('avventura', 'carol', ip: null);
      final t = await r.texts();
      for (final m in t) {
        expect(m, isNot(contains('198.51.100.77')));
        for (final l in m.split('\n')) {
          expect(l.runes.first, greaterThan(0x2000), reason: 'riga senza emoji: $l');
        }
      }
      expect(t[0], contains('<code>192.0.2.10</code>'));
      expect(t[1], contains('<code>192.0.2.10:25570</code>'));
      expect(t[2].split('\n'), hasLength(3)); // niente riga dell'indirizzo
    });

    test('B-TG-04 IPv6 con porta tra parentesi quadre', () {
      expect(hostAddress('2001:db8::1', 25570), '[2001:db8::1]:25570');
      expect(hostAddress('2001:db8::1', null), '2001:db8::1');
    });

    test('B-TG-09 un lock di push non è mai un server aperto', () async {
      r.world.play('survival', 'alice', action: 'push');
      await r.after(minute);
      r.world.release('survival');
      await r.after(minute);
      expect(await r.texts(), isEmpty);
      expect(r.bot.statusText(), contains('<b>Survival</b> — chiuso'));
    });

    test('B-TG-13 sessioni di uno spazio cancellato si dimenticano in silenzio', () async {
      r.world.play('survival', 'alice');
      r.world.play('creativo', 'bob');
      await r.bot.idle();
      r.world.delete('survival'); // con l'evento
      r.world.delete('creativo', event: false); // trovato dalla sorveglianza
      await r.after(minute);
      await r.after(minute);
      expect(await r.texts(), hasLength(2)); // solo le due aperture
      expect(r.bot.tracked, isEmpty);
    });

    test('B-TG-14 un evento disk diventa un avviso con spazio libero e soglia', () async {
      r.world.emit(
        EventType.disk,
        data: {'free': 512 << 20, 'total': 100 << 30, 'minFree': 1 << 30, 'level': 'warn'},
      );
      r.world.emit(
        EventType.disk,
        data: {'free': 100 << 20, 'total': 100 << 30, 'minFree': 1 << 30, 'level': 'full'},
      );
      final s = await r.sent();
      expect(s[0].text, contains('liberi 512 MB, soglia 1,0 GB'));
      expect(s[0].thread, isNull);
      expect(s[1].text, contains('pieno'));
    });
  });

  test(
    'B-TG-03 al riavvio i lock tenuti si adottano in silenzio, la chiusura si annuncia',
    () async {
      final r = BotRig(before: [(w) => w.play('survival', 'alice', event: false)]);
      addTearDown(r.close);
      await r.after(minute);
      expect(await r.texts(), isEmpty);
      expect(r.bot.tracked, {'survival'});
      r.world.release('survival');
      final t = await r.texts();
      expect(t.single, contains('è chiuso'));
      expect(t.single, contains('sessione di 1m'));
    },
  );

  test('B-TG-05 /status: aperti con host, giocatori e nome DNS, chiusi come chiusi', () async {
    final r = BotRig();
    addTearDown(r.close);
    r.world.play('survival', 'alice', players: ['bob', 'carol']);
    r.clock.advance(const Duration(minutes: 90));
    final s = r.bot.statusText();
    expect(s, contains('Stato dei server'));
    expect(s, contains('<b>Survival</b> — hosta alice da 1h 30m, in gioco: bob, carol'));
    expect(s, contains('zerotier.survival.mc.test'));
    expect(s, contains('<b>Creativo</b> — chiuso'));
    expect(s, contains('<b>Avventura</b> — chiuso'));
  });

  group('watchdog dei salvataggi', () {
    test('B-TG-06 un avviso dopo 30 minuti senza push, il push successivo lo riarma', () async {
      final r = BotRig();
      addTearDown(r.close);
      r.world.play('survival', 'alice');
      await r.after(const Duration(minutes: 29));
      expect(await r.texts(), hasLength(1));
      await r.after(minute);
      var t = await r.texts();
      expect(t, hasLength(2));
      expect(t[1], contains('non salva sull\'hub da 30m'));
      await r.after(const Duration(minutes: 30));
      expect(await r.texts(), hasLength(2)); // una volta sola
      r.world.emit(EventType.push, space: 'survival');
      await r.after(const Duration(minutes: 30));
      t = await r.texts();
      expect(t, hasLength(3));
    });

    test('B-TG-06 ad avvisi spenti niente e la sessione non si marca', () async {
      final r = BotRig(config: tgConfig(notify: const TelegramNotify(alerts: false)));
      addTearDown(r.close);
      r.world.play('survival', 'alice');
      await r.after(const Duration(minutes: 40));
      expect(await r.texts(), hasLength(1));
      r.bot.apply(tgConfig());
      await r.after(minute);
      final t = await r.texts();
      expect(t, hasLength(2));
      expect(t[1], contains('non salva'));
    });
  });

  test('B-TG-07 il bot è attivo solo con enabled, token e chat', () async {
    for (final c in [tgConfig(enabled: false), tgConfig(token: null), tgConfig(chat: null)]) {
      final r = BotRig(config: c);
      r.world.play('survival', 'alice');
      expect(await r.texts(), isEmpty);
      expect(r.bot.status().state, c.enabled ? TelegramState.incomplete : TelegramState.disabled);
      await r.close();
    }
    final r = BotRig();
    addTearDown(r.close);
    expect(r.bot.status().state, TelegramState.active);
  });

  test('B-TG-08 durate: vuoto sotto il minuto, 5m, 1h 30m, 3h 0m', () {
    expect(dur(const Duration(seconds: 59)), '');
    expect(dur(const Duration(minutes: 5)), '5m');
    expect(dur(const Duration(minutes: 90)), '1h 30m');
    expect(dur(const Duration(hours: 3)), '3h 0m');
  });

  group('invii', () {
    test('B-TG-10 su 429 aspetta retry_after invece del backoff', () async {
      final r = BotRig();
      addTearDown(r.close);
      r.tg.plan.add(FakeTelegram.fail(429, 'Too Many Requests: retry after 7', retryAfter: 7));
      r.world.play('survival', 'alice');
      expect(await r.texts(), hasLength(1));
      expect(r.waits, [const Duration(seconds: 7)]);
      expect(r.bot.status().lastError, isNull);
    });

    test('B-TG-10 retry_after oltre il budget: un solo tentativo e l\'errore resta', () async {
      final r = BotRig();
      addTearDown(r.close);
      r.tg.plan.add(FakeTelegram.fail(429, 'Too Many Requests: retry after 600', retryAfter: 600));
      r.world.play('survival', 'alice');
      expect(await r.texts(), isEmpty);
      expect(r.waits, isEmpty);
      expect(r.tg.calls.where((c) => c == 'sendMessage'), hasLength(1));
      final st = r.bot.status();
      expect(st.state, TelegramState.error);
      expect(st.lastError, contains('Too Many Requests'));
      expect(r.published.single.$1, EventType.telegramError);
    });

    test('B-TG-10 errori 5xx: backoff crescente, al più 3 tentativi', () async {
      final r = BotRig();
      addTearDown(r.close);
      r.tg.plan
        ..add(FakeTelegram.fail(502, 'Bad Gateway'))
        ..add(FakeTelegram.fail(502, 'Bad Gateway'))
        ..add(FakeTelegram.fail(502, 'Bad Gateway'));
      r.world.play('survival', 'alice');
      expect(await r.texts(), isEmpty);
      expect(r.waits, [const Duration(seconds: 2), const Duration(seconds: 4)]);
    });
  });

  group('coalescenza', () {
    late BotRig r;
    setUp(() => r = BotRig(config: tgConfig(coalesce: 1)));
    tearDown(() => r.close());

    test('B-TG-11 chiuso e riaperto dallo stesso host: silenzio, durata vera', () async {
      r.world.play('survival', 'alice');
      await r.after(const Duration(minutes: 10));
      r.world.release('survival');
      await r.after(const Duration(seconds: 30));
      r.world.play('survival', 'alice');
      await r.after(minute);
      expect(await r.texts(), hasLength(1));
      await r.after(const Duration(minutes: 10));
      r.world.release('survival');
      await r.after(const Duration(seconds: 30));
      expect(await r.texts(), hasLength(1)); // ancora nella finestra
      await r.after(const Duration(seconds: 30));
      final t = await r.texts();
      expect(t, hasLength(2));
      expect(t[1], contains('sessione di 21m'));
    });

    test('B-TG-11 riaperto da un altro: la chiusura parte subito, prima dell\'apertura', () async {
      r.world.play('survival', 'alice');
      await r.after(const Duration(minutes: 5));
      r.world.release('survival');
      r.world.play('survival', 'bob');
      final t = await r.texts();
      expect(t, hasLength(3));
      expect(t[1], contains('è chiuso'));
      expect(t[2], contains('hosta <b>bob</b>'));
    });

    test('B-TG-12 scaduto, annunciato chiuso, poi tornato vivo: riaperto e chiuso', () async {
      r.world.play('survival', 'alice');
      r.world.setStale('survival', true);
      await r.after(const Duration(seconds: 10));
      await r.after(minute);
      expect(await r.texts(), hasLength(2));
      r.world.setStale('survival', false); // heartbeat dopo una lunga pausa
      await r.after(const Duration(seconds: 10));
      await r.after(const Duration(seconds: 10));
      var t = await r.texts();
      expect(t, hasLength(3));
      expect(t[2], contains('è aperto'));
      r.world.release('survival');
      await r.after(minute);
      t = await r.texts();
      expect(t, hasLength(4));
      expect(t[3], contains('è chiuso'));
    });

    test('B-TG-12 tornato vivo dentro la finestra: nessun messaggio, resta seguito', () async {
      r.world.play('survival', 'alice');
      r.world.setStale('survival', true);
      await r.after(const Duration(seconds: 10));
      r.world.setStale('survival', false);
      await r.after(const Duration(seconds: 10));
      await r.after(const Duration(minutes: 2));
      expect(await r.texts(), hasLength(1));
      expect(r.bot.tracked, {'survival'});
    });
  });

  group('riconfigurazione', () {
    test('B-TG-15 seguito a bot spento; riacceso su un\'altra chat la chiusura va lì', () async {
      final r = BotRig(config: tgConfig(enabled: false));
      addTearDown(r.close);
      r.world.play('survival', 'alice');
      await r.after(const Duration(minutes: 20));
      r.bot.apply(tgConfig(chat: tgChat2));
      r.world.release('survival');
      final s = await r.sent();
      expect(s.single.chat, tgChat2);
      expect(s.single.text, contains('sessione di 20m'));
    });

    test('B-TG-15 i flag di apertura e chiusura tolgono i rispettivi messaggi', () async {
      final r = BotRig(config: tgConfig(notify: const TelegramNotify(open: false)));
      addTearDown(r.close);
      r.world.play('survival', 'alice');
      r.world.release('survival');
      expect((await r.texts()).single, contains('chiuso'));
      r.bot.apply(tgConfig(notify: const TelegramNotify(close: false)));
      r.world.play('survival', 'alice');
      r.world.release('survival');
      final t = await r.texts();
      expect(t, hasLength(2));
      expect(t[1], contains('aperto'));
    });

    test('B-TG-17 messaggi in coda prima dello spegnimento si scartano', () async {
      final r = BotRig();
      addTearDown(r.close);
      r.tg.gate = Completer<void>();
      r.world.play('survival', 'alice'); // in invio, fermo al cancello
      r.world.play('creativo', 'bob'); // in coda
      r.world.play('avventura', 'carol'); // in coda
      await Future<void>.delayed(Duration.zero);
      r.bot.apply(tgConfig(enabled: false));
      r.world.release('survival'); // a bot spento: niente in coda
      r.tg.gate!.complete();
      final s = await r.sent();
      expect(s.length, lessThanOrEqualTo(1));
      expect(s.where((m) => m.text.contains('Creativo') || m.text.contains('Avventura')), isEmpty);
      r.bot.apply(tgConfig());
      await r.bot.idle();
      expect(r.tg.sent.length, s.length);
    });

    test('B-TG-16 senza /status nessun polling; acceso risponde solo nella chat giusta', () async {
      final r = BotRig(config: tgConfig(notify: const TelegramNotify(status: false)));
      addTearDown(r.close);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(r.tg.getUpdatesCalls, 0);
      expect(r.bot.polling, isFalse);

      r.bot.apply(tgConfig());
      expect(r.bot.polling, isTrue);
      await until(() => r.tg.calls.contains('getMe'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      r.tg.say('/status');
      r.tg.say('/status@msbot');
      r.tg.say('/status@altrobot');
      r.tg.say('/status', chat: tgChat2);
      r.tg.say('ciao');
      await until(() => r.tg.sent.length >= 2);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await r.bot.idle();
      expect(r.tg.sent, hasLength(2));
      expect(
        r.tg.sent.every((s) => s.chat == tgChat && s.text.contains('Stato dei server')),
        isTrue,
      );

      r.bot.apply(tgConfig(notify: const TelegramNotify(status: false)));
      expect(r.bot.polling, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final n = r.tg.getUpdatesCalls;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(r.tg.getUpdatesCalls, n);
    });
  });

  group('messaggio di prova', () {
    test('B-TG-18 errore di Telegram testuale con l\'ora; un successo lo cancella', () async {
      final r = BotRig();
      addTearDown(r.close);
      r.tg.plan.add(FakeTelegram.fail(400, 'Bad Request: chat not found'));
      await expectLater(
        r.bot.sendTest(token: tgToken, chat: tgChat),
        throwsA(isA<Object>().having((e) => '$e', 'testo', 'Bad Request: chat not found')),
      );
      var st = r.bot.status();
      expect(st.lastError, 'Bad Request: chat not found');
      expect(st.lastErrorAt, r.clock.wallMs());
      r.clock.advance(minute);
      final at = await r.bot.sendTest(token: tgToken, chat: tgChat);
      st = r.bot.status();
      expect(st.lastError, isNull);
      expect(st.lastSentAt, at);
      expect(st.lastSent, startsWith('✅ MineSync'));
    });

    test('B-TG-18 un errore di rete non contiene mai il token', () async {
      final r = BotRig();
      addTearDown(r.close);
      r.tg.networkDown = true;
      Object? err;
      try {
        await r.bot.sendTest(token: tgToken, chat: tgChat);
      } catch (e) {
        err = e;
      }
      expect('$err', isNot(contains(tgToken)));
      expect('$err', isNot(contains('AAAAAAAAAA')));
      expect(r.bot.status().lastError, isNot(contains(tgToken)));
      r.world.play('survival', 'alice');
      await r.bot.idle();
      expect(r.bot.status().lastError, isNot(contains(tgToken)));
      expect(r.published.toString(), isNot(contains(tgToken)));
    });
  });

  group('topic per server', () {
    test('B-TG-19 spazio con topic nel suo thread, gli altri nella chat principale', () async {
      final r = BotRig(config: tgConfig(topics: {'survival': 42}));
      addTearDown(r.close);
      r.world.play('survival', 'alice');
      r.world.play('creativo', 'bob');
      final s = await r.sent();
      expect(s[0].thread, 42);
      expect(s[1].thread, isNull);
    });

    test('B-TG-19 un thread ≤ 1 non si manda mai', () async {
      final r = BotRig(config: tgConfig(topics: {'survival': 1}));
      addTearDown(r.close);
      r.world.play('survival', 'alice');
      expect((await r.sent()).single.thread, isNull);
    });

    test('B-TG-20 /status nel topic di uno spazio risponde solo per quello', () async {
      final r = BotRig(config: tgConfig(topics: {'survival': 42, 'creativo': 43}));
      addTearDown(r.close);
      await until(() => r.tg.calls.contains('getMe'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      r.tg.say('/status', thread: 42);
      await until(() => r.tg.sent.isNotEmpty);
      r.tg.say('/status');
      await until(() => r.tg.sent.length >= 2);
      r.tg.say('/status', thread: 99);
      await until(() => r.tg.sent.length >= 3);
      await r.bot.idle();
      final s = r.tg.sent;
      expect(s[0].thread, 42);
      expect(s[0].text, contains('Survival'));
      expect(s[0].text, isNot(contains('Creativo')));
      expect(s[1].thread, isNull);
      expect(s[1].text, allOf(contains('Survival'), contains('Creativo'), contains('Avventura')));
      expect(s[2].thread, 99);
      expect(s[2].text, allOf(contains('Survival'), contains('Creativo')));
    });

    test('B-TG-21 topic eliminato: una volta nella chat principale, lo stato lo nomina', () async {
      final r = BotRig(config: tgConfig(topics: {'survival': 42}));
      addTearDown(r.close);
      r.tg.deletedThreads.add(42);
      r.world.play('survival', 'alice');
      final s = await r.sent();
      expect(s.single.thread, isNull);
      expect(s.single.text, contains('è aperto'));
      var st = r.bot.status();
      expect(st.missingTopics, ['survival']);
      expect(st.lastError, contains('Survival'));
      // la mappa cambia: il topic mancante sparisce
      r.bot.apply(tgConfig(topics: {'survival': 50}));
      st = r.bot.status();
      expect(st.missingTopics, isEmpty);
    });

    test('B-TG-21 una prova verso un topic eliminato: errore chiaro, stato pulito', () async {
      final r = BotRig();
      addTearDown(r.close);
      r.tg.deletedThreads.add(42);
      Object? err;
      try {
        await r.bot.sendTest(token: tgToken, chat: tgChat, thread: 42, spaceName: 'Survival');
      } catch (e) {
        err = e;
      }
      expect('$err', contains('Survival'));
      expect(r.bot.status().lastError, isNull);
      expect(r.bot.status().missingTopics, isEmpty);
    });
  });

  test('B-TG-22 i messaggi seguono la lingua configurata', () async {
    final r = BotRig(config: tgConfig(language: 'en'));
    addTearDown(r.close);
    r.world.play('survival', 'alice', players: ['bob']);
    r.world.release('survival');
    final t = await r.texts();
    expect(t[0], contains('is open'));
    expect(t[0], contains('hosted by'));
    expect(t[1], contains('is closed'));
    r.world.play('survival', 'alice');
    expect(r.bot.statusText(), contains('Server status'));
    expect(r.bot.statusText(), contains('<b>Creativo</b> — closed'));
    // `hub` segue la lingua dell'hub
    r.bot.apply(tgConfig(language: 'hub'));
    r.hubLang = 'en';
    expect(r.bot.statusText(), contains('Server status'));
    r.hubLang = 'it';
    expect(r.bot.statusText(), contains('Stato dei server'));
  });
}
