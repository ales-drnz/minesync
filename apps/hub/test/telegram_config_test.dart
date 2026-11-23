// Impostazioni del bot: file telegram.json, validazione, topic (B-TG-23…27).
import 'dart:convert';
import 'dart:io';

import 'package:minesync_hub/src/telegram/config.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:test/test.dart';

import 'telegram_support.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('minesync-tg-'));
  tearDown(() => dir.delete(recursive: true));

  test('B-TG-23 file assente: spento, notifiche accese; salvato 0600 e riletto uguale', () async {
    final f = TelegramConfigFile('${dir.path}/telegram.json');
    final c = await f.load();
    expect(c.enabled, isFalse);
    expect(c.active, isFalse);
    expect(c.notify.toJson(), {'open': true, 'close': true, 'alerts': true, 'status': true});
    expect(c.coalesceMinutes, 1);
    expect(c.pushWarnMinutes, 30);
    final want = tgConfig(coalesce: 5, topics: {'survival': 42});
    await f.update((_) async => (want, null));
    if (!Platform.isWindows) {
      expect((await File(f.path).stat()).mode & 0x1ff, 0x180);
    }
    final again = await TelegramConfigFile(f.path).load();
    expect(jsonEncode(again.toJson()), jsonEncode(want.toJson()));
  });

  test('B-TG-23 flag di notifica mancanti nel file valgono accesi', () async {
    final p = '${dir.path}/telegram.json';
    await File(p).writeAsString(
      jsonEncode({
        'enabled': true,
        'token': tgToken,
        'chat': tgChat,
        'notify': {'open': false},
      }),
    );
    final c = await TelegramConfigFile(p).load();
    expect(c.notify.open, isFalse);
    expect(c.notify.close && c.notify.alerts && c.notify.status, isTrue);
    expect(c.active, isTrue);
  });

  group('B-TG-24 validazione: bad_request, niente salvato', () {
    const cur = TelegramConfig();
    final spaces = {'survival'};
    String? field(Map<String, Object?> b, [TelegramConfig c = cur]) {
      try {
        applyPatch(c, b, spaces: spaces);
        return null;
      } on ApiError catch (e) {
        expect(e.code, ErrorCode.badRequest);
        return e.details['field'] as String?;
      }
    }

    test('acceso senza token o chat', () {
      expect(field({'enabled': true}), 'token');
      expect(field({'enabled': true, 'token': tgToken}), 'chat');
      expect(field({'enabled': true, 'token': tgToken, 'chat': tgChat}), isNull);
    });
    test('token malformato, chat non valida, lingua sconosciuta, intervalli', () {
      expect(field({'token': '123:abc'}), 'token');
      for (final c in ['-123456', 'gruppo', '@ab', '-100']) {
        expect(field({'chat': c}), 'chat', reason: c);
      }
      for (final c in ['-1001234567890', '12345', '@canale_mc']) {
        expect(field({'chat': c}), isNull, reason: c);
      }
      expect(field({'language': 'fr'}), 'language');
      expect(field({'coalesceMinutes': 61}), 'coalesceMinutes');
      expect(field({'pushWarnMinutes': 4}), 'pushWarnMinutes');
      expect(
        field({
          'notify': {'open': 'si'},
        }),
        'notify.open',
      );
      expect(field({'boh': 1}), 'boh');
    });
    test('il file non viene creato da una modifica rifiutata', () async {
      final f = TelegramConfigFile('${dir.path}/telegram.json');
      await f.load();
      await expectLater(
        f.update((c) async => applyPatch(c, {'enabled': true}, spaces: spaces)),
        throwsA(isA<ApiError>()),
      );
      expect(File(f.path).existsSync(), isFalse);
    });
  });

  test('B-TG-26 lettura dei topic', () {
    expect(parseTopic('', tgChat), isNull);
    expect(parseTopic('  ', tgChat), isNull);
    expect(parseTopic('1', tgChat), isNull);
    expect(parseTopic('42', tgChat), 42);
    expect(parseTopic('https://t.me/c/1234567890/42', tgChat), 42);
    expect(parseTopic('https://t.me/c/1234567890/42/1001', tgChat), 42);
    expect(parseTopic('t.me/c/1234567890/42', tgChat), 42);
    expect(parseTopic('telegram.me/c/1234567890/42?single', tgChat), 42);
    expect(parseTopic('https://t.me/c/1234567890/42?thread=42#x', tgChat), 42);
    expect(parseTopic('https://t.me/canale_mc/7/99', '@canale_mc'), 7);
    expect(parseTopic('https://t.me/canale_mc/7', tgChat), 7); // non confrontabili
    for (final bad in [
      '0',
      '-5',
      '4.2',
      'topic',
      'https://example.com/c/1234567890/42',
      'https://t.me/c/1234567890',
      'https://t.me/c/1234567890/0',
      '99999999999999999999',
      'https://t.me/s/12',
    ]) {
      expect(() => parseTopic(bad, tgChat), throwsA(isA<TopicError>()), reason: bad);
    }
    expect(
      () => parseTopic('https://t.me/c/555/42', tgChat),
      throwsA(isA<TopicError>().having((e) => e.linkChat, 'chat', '-100555')),
    );
    expect(
      () => parseTopic('https://t.me/altro_canale/42', '@canale_mc'),
      throwsA(isA<TopicError>().having((e) => e.linkChat, 'chat', '@altro_canale')),
    );
  });

  test('B-TG-27 la mappa dei topic è una copia; una modifica rifiutata non cambia nulla', () async {
    final f = TelegramConfigFile('${dir.path}/telegram.json');
    await f.load();
    await f.update((_) async => (tgConfig(topics: {'survival': 42}), null));
    final before = await File(f.path).readAsString();
    final v = f.config.view().topics;
    v['creativo'] = 5; // la vista è una copia
    expect(f.config.topics, {'survival': 42});
    final reread = await f.load();
    expect(() => reread.topics['creativo'] = 5, throwsUnsupportedError);
    await expectLater(
      f.update(
        (c) async => applyPatch(
          c,
          {
            'topics': {'survival': 'parola'},
          },
          spaces: {'survival'},
        ),
      ),
      throwsA(isA<ApiError>()),
    );
    expect(f.config.topics, {'survival': 42});
    expect(await File(f.path).readAsString(), before);
  });
}
