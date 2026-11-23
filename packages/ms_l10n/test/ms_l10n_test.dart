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
}
