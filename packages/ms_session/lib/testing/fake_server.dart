// Solo per i test: un server Minecraft in memoria, comandato dal test, che
// risponde ai comandi della sessione come il server vanilla e scrive i file
// del mondo nella cartella indicata.
import 'dart:async';
import 'dart:io';

import '../src/server_process.dart';

final class FakeServer implements ServerProcess {
  FakeServer(this.root, {this.saveDelay = Duration.zero, this.lateWrite, this.ignoreStop = false});

  final String root;

  /// Ritardo tra `save-all flush` e "Saved the game".
  Duration saveDelay;

  /// Scrittura dopo la conferma (un mod che scrive in ritardo).
  (Duration, String, String)? lateWrite;
  bool ignoreStop;
  bool confirmSaves = true;

  final _lines = StreamController<ServerLine>();
  final _exit = Completer<ServerEnd>();
  final commands = <String>[];
  int stops = 0;
  bool saveOn = true;
  int world = 0;

  @override
  Stream<ServerLine> get lines => _lines.stream;
  @override
  Future<ServerEnd> get exit => _exit.future;
  @override
  bool get running => !_exit.isCompleted;

  /// Scrive una riga con il prefisso del log vanilla (`[hh:mm:ss] `).
  void say(String s) {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final line = '[${two(t.hour)}:${two(t.minute)}:${two(t.second)}] $s';
    if (!_lines.isClosed) _lines.add(ServerLine(line, at: t));
  }

  void write(String rel, String content) => File('$root/$rel')
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  /// Avvio: "Done" dopo un attimo.
  void boot() =>
      Timer(const Duration(milliseconds: 20), () => say('[Server thread/INFO]: Done (1.0s)!'));

  void join(String name) => say('[Server thread/INFO]: $name joined the game');
  void leave(String name) => say('[Server thread/INFO]: $name left the game');

  /// Il gioco cambia il mondo (lo fa sempre, anche in save-off: qui no, per
  /// rendere i test deterministici).
  void play() => write('world/level.dat', 'world ${++world}');

  void crash([int code = 1]) {
    say('[Server thread/ERROR]: Encountered an unexpected exception');
    _end(code, 'exited');
  }

  void _end(int? code, String reason) {
    if (_exit.isCompleted) return;
    unawaited(_lines.close());
    _exit.complete(ServerEnd(exitCode: code, reason: reason));
  }

  @override
  Future<void> send(String command) async {
    if (!running) throw StateError('not running');
    commands.add(command);
    switch (command) {
      case 'save-off':
        saveOn = false;
      case 'save-on':
        saveOn = true;
      case 'save-all flush':
        say('[Server thread/INFO]: Saving the game (this may take a moment!)');
        Timer(saveDelay, () {
          if (!confirmSaves) return;
          say('[Server thread/INFO]: Saved the game');
          final lw = lateWrite;
          if (lw != null) Timer(lw.$1, () => write(lw.$2, lw.$3));
        });
      case 'stop':
        await stop();
    }
  }

  @override
  Future<void> stop() async {
    stops++;
    if (ignoreStop || !running) return;
    say('[Server thread/INFO]: Stopping server');
    write('world/level.dat', 'world $world saved at stop');
    Timer(const Duration(milliseconds: 20), () => _end(0, 'exited'));
  }

  @override
  Future<void> kill() async => _end(null, 'killed');
}

/// Parser minimo per il server finto (quello vero è in ms_minecraft).
ServerFact? fakeParse(String line) {
  final m = RegExp(r'\[Server thread/INFO\]: (.*)$').firstMatch(line);
  if (m == null) return null;
  final body = m[1]!;
  if (body.startsWith('Done (')) return const FactStarted();
  if (body == 'Saved the game') return const FactSaved();
  if (body == 'Stopping server') return const FactStopping();
  final j = RegExp(r'^(\.?\w+) joined the game$').firstMatch(body);
  if (j != null) return FactJoined(j[1]!);
  final l = RegExp(r'^(\.?\w+) left the game$').firstMatch(body);
  if (l != null) return FactLeft(l[1]!);
  return null;
}
