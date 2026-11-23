// Supporto dei test del guard: compilazione dei binari (una volta per
// esecuzione), cartelle di stato per scenario e ricerca dei processi rimasti.
import 'dart:async';
import 'dart:io';

import 'package:minesync_guard/src/posix.dart' as px;
import 'package:minesync_guard/src/process_tree.dart';

String get _ext => Platform.isWindows ? '.exe' : '';

/// Binari compilati con dart compile exe in una cartella temporanea.
final class Binaries {
  Binaries._(this.dir);

  final Directory dir;

  String get guard => _path('minesync_guard');
  String get fakeServer => _path('fake_minecraft');
  String get host => _path('host');

  /// Script di avvio come quello di un modpack: sh/cmd resta padre del
  /// server (niente exec), così l'albero ha un livello in più.
  String get startScript => _path(Platform.isWindows ? 'start.bat' : 'start.sh', ext: false);

  String _path(String n, {bool ext = true}) =>
      '${dir.path}${Platform.pathSeparator}$n${ext ? _ext : ''}';

  /// Comando per avviare il finto server attraverso lo script di avvio.
  (String, List<String>) viaScript(List<String> serverArgs) => Platform.isWindows
      ? ('cmd.exe', ['/c', startScript, fakeServer, ...serverArgs])
      : ('/bin/sh', [startScript, fakeServer, ...serverArgs]);

  static Future<Binaries> build() async {
    final dir = Directory.systemTemp.createTempSync('ms_guard_bin');
    final b = Binaries._(dir);
    final root = Directory.current.path; // dart test gira nella cartella del pacchetto
    final sep = Platform.pathSeparator;
    final sources = {
      b.guard: '$root${sep}bin${sep}minesync_guard.dart',
      b.fakeServer: '$root${sep}bin${sep}fake_minecraft.dart',
      b.host: '$root${sep}test${sep}support${sep}host.dart',
    };
    await Future.wait([
      for (final e in sources.entries)
        Process.run(Platform.resolvedExecutable, ['compile', 'exe', e.value, '-o', e.key]).then((
          r,
        ) {
          if (r.exitCode != 0) {
            throw StateError('compilazione di ${e.value} fallita:\n${r.stdout}\n${r.stderr}');
          }
        }),
    ]);
    if (Platform.isWindows) {
      File(b.startScript).writeAsStringSync('@echo off\r\n%*\r\n');
    } else {
      File(b.startScript).writeAsStringSync('#!/bin/sh\n"\$@"\n');
    }
    return b;
  }

  void dispose() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // su Windows un exe appena chiuso può restare bloccato per un attimo
    }
  }
}

/// Cartella di stato di uno scenario: il suo percorso compare nella riga di
/// comando di ogni processo dello scenario, e così si trovano gli orfani.
final class Scenario {
  Scenario(Directory root, String name)
    : dir = Directory('${root.path}${Platform.pathSeparator}$name')..createSync(recursive: true);

  final Directory dir;

  String get path => dir.path;
  String file(String n) => '$path${Platform.pathSeparator}$n';

  bool has(String n) => File(file(n)).existsSync();

  String? read(String n) {
    try {
      return File(file(n)).readAsStringSync().trim();
    } on FileSystemException {
      return null;
    }
  }

  int? pidOf(String n) => int.tryParse(read('$n.pid') ?? '');

  Future<bool> waitFile(String n, [Duration t = const Duration(seconds: 20)]) =>
      waitUntil(() => has(n), t);

  /// Processi vivi che hanno la cartella di stato nella riga di comando,
  /// escluso il processo dei test.
  Future<List<int>> leftovers() async {
    if (Platform.isWindows) {
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        "Get-CimInstance Win32_Process | Where-Object { \$_.CommandLine -like '*$path*' "
            "-and \$_.ProcessId -ne \$PID } | ForEach-Object { \$_.ProcessId }",
      ]);
      return [
        for (final l in (r.stdout as String).split('\n'))
          if (int.tryParse(l.trim()) case final p? when p != pid && processAlive(p)) p,
      ];
    }
    return [
      for (final r in px.listProcesses(withArgs: true))
        if (!r.zombie && r.pid != pid && r.args.contains(path)) r.pid,
    ];
  }

  /// Aspetta che non resti niente dello scenario (oltre a [except]);
  /// restituisce quel che resta allo scadere.
  Future<List<int>> waitNoLeftovers({
    Duration t = const Duration(seconds: 15),
    Set<int> except = const {},
  }) async {
    final end = DateTime.now().add(t);
    var left = <int>[];
    do {
      left = (await leftovers()).where((p) => !except.contains(p)).toList();
      if (left.isEmpty) return left;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    } while (DateTime.now().isBefore(end));
    return left;
  }

  /// Uccide tutto quel che resta: i test non devono lasciare processi.
  Future<void> cleanup() async {
    for (var round = 0; round < 3; round++) {
      final left = await leftovers();
      if (left.isEmpty) return;
      for (final p in left) {
        await killHard(p);
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }
}

/// Kill senza appello: SIGKILL, o taskkill /F su Windows.
Future<void> killHard(int p) async {
  if (Platform.isWindows) {
    await Process.run('taskkill', ['/F', '/PID', '$p']);
  } else {
    Process.killPid(p, ProcessSignal.sigkill);
  }
}

Future<bool> waitUntil(bool Function() cond, [Duration t = const Duration(seconds: 20)]) async {
  final end = DateTime.now().add(t);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return true;
}

/// Raccoglie le righe di console di un client in una lista consultabile.
final class LineLog {
  final List<String> lines = [];

  /// Completato quando lo stream delle righe si chiude.
  final Completer<void> done = Completer<void>();

  void close() {
    if (!done.isCompleted) done.complete();
  }

  final _waiters = <(bool Function(String), Completer<String>)>[];

  void add(String l) {
    lines.add(l);
    for (final w in [..._waiters]) {
      if (w.$1(l)) {
        _waiters.remove(w);
        w.$2.complete(l);
      }
    }
  }

  /// Prima riga (già vista o futura) che soddisfa [test].
  Future<String> wait(bool Function(String) test, [Duration t = const Duration(seconds: 20)]) {
    for (final l in lines) {
      if (test(l)) return Future.value(l);
    }
    final c = Completer<String>();
    _waiters.add((test, c));
    return c.future.timeout(t);
  }

  Future<String> waitFor(String part, [Duration t = const Duration(seconds: 20)]) =>
      wait((l) => l.contains(part), t);

  @override
  String toString() => lines.join('\n');
}
