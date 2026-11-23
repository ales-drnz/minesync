// Testi della pagina Server: le due lingue sono diverse, migliaia e plurali.
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_hub_web/src/l10n/l10n.dart';
import 'package:ms_protocol/ms_protocol.dart';

import '../support/fixtures.dart';

void main() {
  test('IT ed EN diversi in ogni area della pagina Server', () {
    final it = WebStrings(Lang.it).server;
    final en = WebStrings(Lang.en).server;
    expect(it.lockTitle, isNot(en.lockTitle));
    expect(it.history.emptyTitle, isNot(en.history.emptyTitle));
    expect(it.admin.dangerTitle, isNot(en.admin.dangerTitle));
    expect(it.history.title(sampleGen(3)), 'Salvataggio automatico');
    expect(en.history.count(1), '1 version');
    expect(en.playersCount(2), '2 players');
  });

  test('numeri con le migliaia', () {
    expect(groupInt(Lang.it, 1842), '1.842');
    expect(groupInt(Lang.en, 1234567), '1,234,567');
    expect(groupInt(Lang.it, 999), '999');
    expect(groupInt(Lang.it, -1024), '−1.024');
  });

  test('regole di conservazione in frase', () {
    final h = WebStrings(Lang.it).server.history;
    expect(h.rules(const HistorySettings(keepLast: 5, keepHours: 0, keepDays: 0)), [
      'sempre le ultime 5 versioni',
    ]);
  });
}
