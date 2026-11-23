// Testi: completezza (le classi astratte lo garantiscono a compilazione;
// qui si controlla che nessun testo sia vuoto o uguale al tipo grezzo),
// eventi di ogni EventType, errori di ogni ErrorCode, formati.
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_hub_web/src/l10n/l10n.dart';
import 'package:ms_protocol/ms_protocol.dart';

import 'support/fixtures.dart';

void main() {
  for (final lang in Lang.values) {
    group(lang.name, () {
      final s = WebStrings(lang);

      test('ogni tipo di evento ha badge, frase e riga', () {
        for (final type in EventType.all) {
          final e = HubEvent(
            seq: 1,
            ts: 0,
            type: type,
            space: 'survival',
            actor: 'alice',
            data: const {'n': 3, 'restoredFrom': 2, 'bytes': 1024, 'kind': 'push'},
          );
          final badge = s.events.badge(type);
          expect(badge, isNotEmpty, reason: type);
          expect(badge.length, lessThanOrEqualTo(10), reason: '$type: badge troppo lungo');
          final text = s.events.text(e, 'Survival', s.fmt).map((p) => p.$1).join();
          expect(text, isNot(type), reason: '$type senza frase');
          expect(text, isNot(contains('null')), reason: type);
          expect(s.events.meta(e, 'Survival'), isNotEmpty);
        }
        // tipo sconosciuto: mostrato com'è, senza errori
        const unknown = HubEvent(seq: 1, ts: 0, type: 'future.type');
        expect(s.events.badge('future.type'), 'future.type');
        expect(s.events.text(unknown, null, s.fmt).single.$1, 'future.type');
      });

      test('ogni codice di errore ha un testo', () {
        final seen = <String>{};
        for (final c in ErrorCode.values) {
          final t = s.common.apiError(c, const {});
          expect(t, isNotEmpty, reason: c.wire);
          expect(t, isNot(contains('null')), reason: c.wire);
          seen.add(t);
        }
        expect(seen.length, ErrorCode.values.length, reason: 'due codici con lo stesso testo');
        expect(
          s.common.apiError(ErrorCode.locked, const {
            'lock': {'name': 'bob'},
          }),
          contains('bob'),
        );
      });

      test('le due lingue sono davvero diverse', () {
        final other = WebStrings(lang == Lang.it ? Lang.en : Lang.it);
        expect(s.shell.offlineTitle, isNot(other.shell.offlineTitle));
        expect(s.overview.title, isNot(other.overview.title));
        expect(s.download.lead, isNot(other.download.lead));
        expect(s.events.badge(EventType.push), isNot(other.events.badge(EventType.push)));
      });
    });
  }

  test('formati: dimensioni, durate, date relative, nomi', () {
    final it = FormatStrings.of(Lang.it);
    final en = FormatStrings.of(Lang.en);
    expect(it.size(31 << 30), '31 GB');
    expect(it.size(1900 << 20), '1,9 GB');
    expect(en.size(1900 << 20), '1.9 GB');
    expect(it.duration(const Duration(minutes: 74)), '1 h 14 min');
    expect(it.duration(const Duration(minutes: 125)), '2 h 05 min');
    expect(it.ago(DateTime.utc(2026, 11, 22, 17, 56), testNow), '4 min fa');
    expect(en.ago(DateTime.utc(2026, 11, 22, 17, 56), testNow), '4 min ago');
    expect(it.when(DateTime.utc(2026, 11, 21, 22, 47), testNow), 'ieri 22:47');
    expect(it.eventTime(DateTime.utc(2026, 11, 22, 17, 52), testNow), '17:52');
    expect(it.names(['bob', 'carol', 'alice']), 'bob, carol e alice');
    expect(en.names(['bob', 'carol']), 'bob and carol');
    expect(it.percentSpaced(.91), '91 %');
    expect(it.gen(41), '#41');
  });
}
