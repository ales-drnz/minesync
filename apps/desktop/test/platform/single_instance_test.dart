// Istanza singola: la seconda chiede alla prima di mostrarsi ed esce.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_desktop/src/platform/single_instance.dart';

/// Lock sempre occupato: simula un'altra istanza nello stesso processo
/// (su POSIX i lock fcntl non si escludono dentro un processo).
Future<RandomAccessFile?> _held(String _) async => null;

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ms_instance'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('la prima è principale, la seconda le chiede di mostrarsi', () async {
    final first = await SingleInstance.acquire(dir.path);
    expect(first, isA<PrimaryInstance>());
    final primary = first as PrimaryInstance;
    final shown = primary.showRequests.first.timeout(const Duration(seconds: 5));
    final second = await SingleInstance.acquire(dir.path, lock: _held);
    expect(second, isA<SecondaryInstance>());
    expect((second as SecondaryInstance).signaled, isTrue);
    await shown;
    await primary.dispose();
    expect(File('${dir.path}/instance.json').existsSync(), isFalse);
  });

  test('token sbagliato: la principale non obbedisce', () async {
    final primary = await SingleInstance.acquire(dir.path) as PrimaryInstance;
    var shown = false;
    final sub = primary.showRequests.listen((_) => shown = true);
    File(
      '${dir.path}/instance.json',
    ).writeAsStringSync(jsonEncode({'port': primary.port, 'token': 'falso'}));
    final second = await SingleInstance.acquire(
      dir.path,
      lock: _held,
      wait: const Duration(milliseconds: 300),
    );
    expect((second as SecondaryInstance).signaled, isFalse);
    expect(shown, isFalse);
    await sub.cancel();
    await primary.dispose();
  });

  test('file di una istanza morta (lock libero): si diventa principali', () async {
    File('${dir.path}/instance.json').writeAsStringSync(jsonEncode({'port': 1, 'token': 'x'}));
    final role = await SingleInstance.acquire(dir.path);
    expect(role, isA<PrimaryInstance>());
    final j = jsonDecode(File('${dir.path}/instance.json').readAsStringSync()) as Map;
    expect(j['port'], (role as PrimaryInstance).port);
    await role.dispose();
  });

  test('principale irraggiungibile: secondaria che non ha avvisato nessuno', () async {
    final role = await SingleInstance.acquire(
      dir.path,
      lock: _held,
      wait: const Duration(milliseconds: 300),
    );
    expect((role as SecondaryInstance).signaled, isFalse);
  });

  test('lock tenuto da un altro processo: non si diventa principali', () async {
    // Un processo dart a parte tiene il lock sul file, come una prima istanza.
    final script = File('${dir.path}/hold.dart')
      ..writeAsStringSync('''
import 'dart:io';
Future<void> main(List<String> a) async {
  final f = await File(a[0]).open(mode: FileMode.append);
  await f.lock(FileLock.exclusive);
  stdout.writeln('locked');
  await stdin.first;
}
''');
    final Process proc;
    try {
      proc = await Process.start('dart', [
        script.path,
        '${dir.path}${Platform.pathSeparator}instance.lock',
      ], runInShell: Platform.isWindows);
    } on ProcessException {
      markTestSkipped('dart non è nel PATH');
      return;
    }
    await proc.stdout.transform(utf8.decoder).firstWhere((l) => l.contains('locked'));
    final role = await SingleInstance.acquire(dir.path, wait: const Duration(milliseconds: 300));
    expect(role, isA<SecondaryInstance>());
    proc.stdin.writeln('fine');
    await proc.exitCode;
  });
}
