import 'package:ms_core/ms_core.dart';
import 'package:test/test.dart';

void main() {
  test('il pacchetto si risolve nel workspace', () {
    expect(packageName, 'ms_core');
  });
}
