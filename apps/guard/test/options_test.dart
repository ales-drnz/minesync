import 'package:minesync_guard/src/guard.dart';
import 'package:test/test.dart';

void main() {
  test('opzioni del guard', () {
    final o = GuardOptions.parse([
      '--grace',
      '2.5',
      '--parent-pid',
      '42',
      '--log',
      'g.log',
      '--cwd',
      '/srv',
      '--no-stdin-eof',
      '--',
      'java',
      '--grace',
      '-jar',
    ]);
    expect(o.grace, const Duration(milliseconds: 2500));
    expect(o.parentPid, 42);
    expect(o.logPath, 'g.log');
    expect(o.cwd, '/srv');
    expect(o.stdinEof, isFalse);
    expect(o.parentWatch, isTrue);
    expect(o.selfPdeathsig, isTrue);
    // dopo "--" tutto è del server, anche quel che sembra un'opzione
    expect(o.command, ['java', '--grace', '-jar']);
  });

  test('default: grazia di 60 s', () {
    expect(GuardOptions.parse(['--', 'x']).grace, const Duration(seconds: 60));
  });

  test('opzioni non valide', () {
    expect(() => GuardOptions.parse([]), throwsFormatException);
    expect(() => GuardOptions.parse(['--']), throwsFormatException);
    expect(() => GuardOptions.parse(['--boh', '--', 'x']), throwsFormatException);
    expect(() => GuardOptions.parse(['--grace']), throwsFormatException);
    expect(() => GuardOptions.parse(['--grace', '-1', '--', 'x']), throwsFormatException);
  });
}
