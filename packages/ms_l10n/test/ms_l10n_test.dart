import 'dart:io';

import 'package:ms_l10n/ms_l10n.dart';
import 'package:test/test.dart';

void main() {
  test('dimensioni leggibili', () {
    final s = Strings.of(Lang.en);
    expect(s.sizeBytes(512), '512 B');
    expect(s.sizeBytes(1536), '1.5 KiB');
    expect(s.sizeBytes(5 << 30), '5.0 GiB');
    expect(s.sizeBytes(300 << 20), '300 MiB');
  });

  test('le due lingue sono diverse e complete', () {
    final it = Strings.of(Lang.it);
    final en = Strings.of(Lang.en);
    expect(it.lang, Lang.it);
    expect(en.lang, Lang.en);
    expect(it.errStaleBase, isNot(en.errStaleBase));
    expect(en.cliKept(1, 'a'), startsWith('1 file could'));
    expect(en.cliKept(2, 'a'), startsWith('2 files could'));
  });

  test('ogni avviso e allarme della sessione ha un testo, mai il codice', () {
    // i codici si leggono dal sorgente della sessione: uno nuovo senza testo
    // fa fallire il test
    final src = File('../ms_session/lib/src/session.dart').readAsStringSync();
    final warnings = {for (final m in RegExp(r"SessionWarning\('(\w+)'").allMatches(src)) m[1]!};
    final alerts = {for (final m in RegExp(r"SessionAlert\('(\w+)'").allMatches(src)) m[1]!};
    expect(warnings, contains('saveFailed'));
    for (final lang in Lang.values) {
      final s = Strings.of(lang);
      for (final c in warnings) {
        expect(s.playWarning(c), isNot(contains(c)), reason: '$lang $c');
      }
      for (final c in alerts) {
        expect(s.playAlert(c), isNot(contains(c)), reason: '$lang $c');
      }
    }
  });
}
