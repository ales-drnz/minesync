import 'package:minesync_cli/minesync_cli.dart';
import 'package:test/test.dart';

void main() {
  test('il pacchetto si risolve nel workspace', () {
    expect(packageName, 'minesync_cli');
  });
}
