import 'package:ms_l10n/ms_l10n.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('ogni messaggio automatico della sessione ha un testo in ogni lingua', () {
    for (final l in Lang.values) {
      final s = Strings.of(l);
      for (final m in AutoMessage.all) {
        expect(s.autoMessage(m), isNotNull, reason: '$l $m');
        expect(s.autoMessage(m), isNot(contains('@')));
      }
      // un messaggio scritto da una persona resta com'è
      expect(s.autoMessage('primo caricamento'), isNull);
    }
  });
}
