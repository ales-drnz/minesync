// Endpoint /telegram sull'hub vero (B-TG-28…30, B-EVENTS-04), con il
// Telegram finto al posto della rete.
import 'dart:convert';
import 'dart:io';

import 'package:minesync_hub/minesync_hub.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:test/test.dart';

import 'support.dart';
import 'telegram_support.dart';

void main() {
  late TestHub t;
  late FakeTelegram tg;
  late TelegramBot bot;
  late TelegramConfigFile file;
  late String survival;

  setUp(() async {
    t = await TestHub.start();
    tg = FakeTelegram();
    file = TelegramConfigFile('${t.data}/telegram.json');
    bot = TelegramBot(
      transport: tg,
      clock: t.clock,
      spaces: t.store.listSpaces,
      events: t.hub.events.live,
      publish: t.hub.events.publish,
      config: await file.load(),
    )..start(timers: false);
    final routes = TelegramRoutes(
      bot: bot,
      file: file,
      clock: t.clock,
      spaceNames: () => {for (final s in t.store.listSpaces()) s.id: s.name},
      publish: t.hub.events.publish,
    );
    t.hub.apiRoutes.add(routes.handle);
    survival = await t.createSpace('Survival');
  });
  tearDown(() async {
    await bot.stop();
    await t.close();
  });

  Future<Res> patch(Map<String, Object?> b) => t.req('PATCH', '/telegram', as: 'carol', body: b);
  Future<Res> testMsg([Map<String, Object?> b = const {}]) =>
      t.req('POST', '/telegram/test', as: 'carol', body: b);

  test('B-TG-28 GET senza token, solo tokenSet e tokenHint; PATCH parziale', () async {
    expect((await t.get('/telegram')).status, 403); // alice non è admin
    var r = await t.get('/telegram', as: 'carol');
    expect(r.status, 200);
    var st = TelegramStatus.fromJson(r.json);
    expect(st.state, TelegramState.disabled);
    expect(st.settings.tokenSet, isFalse);

    r = await patch({'enabled': true});
    expect(r.status, 400);
    expect(r.code, 'bad_request');

    r = await patch({'enabled': true, 'token': tgToken, 'chat': tgChat});
    expect(r.status, 200);
    expect(utf8.decode(r.bytes), isNot(contains(tgToken)));
    st = TelegramStatus.fromJson(r.json);
    expect(st.state, TelegramState.active);
    expect(st.settings.tokenSet, isTrue);
    expect(st.settings.tokenHint, tgToken.substring(tgToken.length - 4));

    // token vuoto = invariato, chiavi assenti tenute
    r = await patch({'token': '', 'language': 'en'});
    st = TelegramStatus.fromJson(r.json);
    expect(st.settings.tokenSet, isTrue);
    expect(st.settings.chat, tgChat);
    expect(st.settings.language, 'en');

    // togliere il token a bot acceso no, insieme allo spegnimento sì
    r = await patch({'removeToken': true});
    expect(r.status, 400);
    r = await patch({'removeToken': true, 'enabled': false});
    expect(r.status, 200);
    expect(TelegramStatus.fromJson(r.json).settings.tokenSet, isFalse);

    // il file ha il token (0600), nessuna risposta ed evento sì
    final all = (await t.get('/events', as: 'carol')).bytes;
    expect(utf8.decode(all), isNot(contains(tgToken)));
  });

  test('B-EVENTS-04 PATCH pubblica settings con la sezione e i soli nomi dei campi', () async {
    await patch({'enabled': true, 'token': tgToken, 'chat': tgChat});
    final evs = (await t.get('/events', as: 'carol')).obj['events']! as List<Object?>;
    final e = HubEvent.fromJson(evs.last);
    expect(e.type, EventType.settings);
    expect(e.actor, 'carol');
    expect(e.data['section'], 'telegram');
    expect(e.data['fields'], containsAll(['enabled', 'token', 'chat']));
    expect(jsonEncode(e.toJson()), isNot(contains(tgToken)));
    expect(jsonEncode(e.toJson()), isNot(contains(tgChat)));
    expect(e.data.containsKey('values'), isFalse);
  });

  test('B-TG-29 prova: 400 senza config, dati del corpo non salvati, 429, 502', () async {
    var r = await testMsg();
    expect(r.status, 400);
    r = await testMsg({'token': tgToken, 'chat': tgChat, 'language': 'en'});
    expect(r.status, 200);
    expect(TelegramTestResult.fromJson(r.json).chat, tgChat);
    expect(tg.sent.single.text, contains('test message'));
    expect(file.config.token, isNull); // non salvato
    r = await testMsg({'token': tgToken, 'chat': tgChat});
    expect(r.status, 429);
    expect(r.code, 'rate_limited');
    expect(r.details['retryMs'], isA<int>());
    t.clock.advance(const Duration(seconds: 4));
    tg.plan.add(FakeTelegram.fail(400, 'Bad Request: chat not found'));
    r = await testMsg({'token': tgToken, 'chat': tgChat});
    expect(r.status, 502);
    expect(r.code, 'upstream');
    expect(r.details['error'], 'Bad Request: chat not found');
    expect(utf8.decode(r.bytes), isNot(contains(tgToken)));
  });

  test(
    'B-TG-29 prova nel topic: salvato o dal corpo, link di altra chat 400, spazio 404',
    () async {
      await patch({
        'enabled': true,
        'token': tgToken,
        'chat': tgChat,
        'topics': {survival: '42'},
      });
      var r = await testMsg({'spaceId': survival});
      expect(r.status, 200);
      expect(tg.sent.last.thread, 42);
      expect(tg.sent.last.text, contains('Survival'));
      t.clock.advance(const Duration(seconds: 4));
      r = await testMsg({'spaceId': survival, 'topic': 'https://t.me/c/1234567890/77'});
      expect(r.status, 200);
      expect(tg.sent.last.thread, 77);
      expect(file.config.topics[survival], 42); // il topic del corpo non si salva
      t.clock.advance(const Duration(seconds: 4));
      r = await testMsg({'spaceId': survival, 'topic': 'https://t.me/c/555/77'});
      expect(r.status, 400);
      r = await testMsg({'spaceId': 'nessuno'});
      expect(r.status, 404);
    },
  );

  test('B-TG-30 topic via PATCH: numeri e link, mappa sostituita, errori per spazio', () async {
    final creativo = await t.createSpace('Creativo');
    await patch({'enabled': true, 'token': tgToken, 'chat': tgChat});
    var r = await patch({
      'topics': {survival: 'https://t.me/c/1234567890/42/7', creativo: '43', 'ignoto': '9'},
    });
    expect(r.status, 200);
    expect(TelegramStatus.fromJson(r.json).settings.topics, {survival: 42, creativo: 43});
    // assente = invariata
    r = await patch({'language': 'it'});
    expect(TelegramStatus.fromJson(r.json).settings.topics, {survival: 42, creativo: 43});
    // presente = sostituita; "" e "1" = chat principale
    r = await patch({
      'topics': {survival: '1', creativo: ''},
    });
    expect(TelegramStatus.fromJson(r.json).settings.topics, isEmpty);
    r = await patch({
      'topics': {survival: '-3'},
    });
    expect(r.status, 400);
    expect(r.details['field'], 'topics.$survival');
    r = await patch({
      'topics': {survival: 'https://t.me/c/555/42'},
    });
    expect(r.status, 400);
    expect(r.obj.toString(), allOf(contains('-100555'), contains(tgChat)));
    // cambiando chat e link insieme vale la chat nuova
    r = await patch({
      'chat': '-100555',
      'topics': {survival: 'https://t.me/c/555/42'},
    });
    expect(r.status, 200);
    expect(TelegramStatus.fromJson(r.json).settings.topics, {survival: 42});
    // spazio cancellato: sparisce dal GET e dal file al salvataggio successivo
    await t.req('DELETE', '/spaces/$survival', as: 'carol');
    r = await t.get('/telegram', as: 'carol');
    expect(TelegramStatus.fromJson(r.json).settings.topics, isEmpty);
    await patch({'language': 'en'});
    final disk = jsonDecode(await File(file.path).readAsString()) as Map<String, Object?>;
    expect(disk['topics'], isEmpty);
  });

  test('find-chat: dal corpo o salvato, 400 senza token, chat degli aggiornamenti', () async {
    var r = await t.req('POST', '/telegram/find-chat', as: 'carol', body: <String, Object?>{});
    expect(r.status, 400);
    tg.say('ciao', thread: 42);
    r = await t.req('POST', '/telegram/find-chat', as: 'carol', body: {'token': tgToken});
    expect(r.status, 200);
    final chats = (r.obj['chats']! as List<Object?>).map(TelegramChat.fromJson).toList();
    expect(chats.single.id, tgChat);
    expect(chats.single.thread, 42);
  });

  test('il lock vero dell\'hub viene annunciato con l\'IP del socket', () async {
    await patch({'enabled': true, 'token': tgToken, 'chat': tgChat});
    await t.req(
      'POST',
      '/spaces/$survival/lock',
      body: {
        'info': {'client': 'test', 'action': 'play', 'lan': '198.51.100.9'},
      },
    );
    await bot.idle();
    final m = tg.sent.single.text;
    expect(m, contains('<code>127.0.0.1</code>'));
    expect(m, isNot(contains('198.51.100.9')));
  });
}
