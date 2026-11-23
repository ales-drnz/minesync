// Supporto ai test end to end: l'hub vero in un processo separato e i
// binari del guard e del server finto compilati una volta.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Hub avviato con `dart run` su una porta effimera di loopback.
final class HubProcess {
  HubProcess._(this.process, this.port, this.log);

  static Future<HubProcess> start(String dataDir) async {
    final p = await Process.start(
      Platform.resolvedExecutable,
      ['run', File('../hub/bin/hub.dart').absolute.path],
      environment: {
        'MINESYNC_DATA': dataDir,
        'MINESYNC_ADDR': '127.0.0.1:0',
        'MINESYNC_DEV_USER': 'alice',
        'MINESYNC_ADMINS': 'alice',
        'MINESYNC_MIN_FREE': '1MiB',
      },
    );
    final log = StringBuffer();
    final ready = Completer<int>();
    final re = RegExp(r':(\d+), dati');
    void onLine(String l) {
      log.writeln(l);
      final m = re.firstMatch(l);
      if (m != null && !ready.isCompleted) ready.complete(int.parse(m[1]!));
    }

    // l'hub scrive i log su stderr
    for (final s in [p.stdout, p.stderr]) {
      s.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine);
    }
    unawaited(
      p.exitCode.then((c) {
        if (!ready.isCompleted) ready.completeError(StateError('hub uscito ($c): $log'));
      }),
    );
    final port = await ready.future.timeout(const Duration(minutes: 2));
    return HubProcess._(p, port, log);
  }

  final Process process;
  final int port;
  final StringBuffer log;

  Uri get uri => Uri.parse('http://127.0.0.1:$port/');

  Future<void> stop() async {
    process.kill();
    await process.exitCode;
  }
}

/// Compila un entrypoint Dart in [outDir]; restituisce il percorso del binario.
Future<String> compileExe(String entry, String outDir, String name) async {
  final out = '$outDir${Platform.pathSeparator}$name${Platform.isWindows ? '.exe' : ''}';
  final r = await Process.run(Platform.resolvedExecutable, [
    'compile',
    'exe',
    File(entry).absolute.path,
    '-o',
    out,
  ]);
  if (r.exitCode != 0) throw StateError('compilazione di $entry fallita: ${r.stderr}${r.stdout}');
  return out;
}
