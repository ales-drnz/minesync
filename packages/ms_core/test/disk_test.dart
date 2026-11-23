import 'dart:io';

import 'package:ms_core/ms_core.dart';
import 'package:test/test.dart';

void main() {
  test('spazio del volume della cartella temporanea', () {
    final d = diskSpace(Directory.systemTemp.path);
    expect(d.total, greaterThan(1 << 30));
    expect(d.free, greaterThan(0));
    expect(d.free, lessThanOrEqualTo(d.total));
  });

  test('percorso inesistente: errore, non numeri inventati', () {
    expect(
      () => diskSpace('${Directory.systemTemp.path}/non/esiste/xyz'),
      throwsA(isA<FileSystemException>()),
    );
  });
}
