// Collegamento al guard: il server Minecraft gira sotto il processo guard,
// che lo ferma in modo pulito anche se l'app muore.
import 'package:minesync_guard/minesync_guard.dart';
import 'package:ms_minecraft/ms_minecraft.dart';

import 'server_process.dart';

/// Processo del server avviato tramite il guard.
final class GuardServerProcess implements ServerProcess {
  GuardServerProcess._(this._g);

  /// Avvia [launch] sotto il guard. [guard] è il comando del guard (il binario
  /// compilato, o `dart run .../minesync_guard.dart` in sviluppo).
  static Future<GuardServerProcess> start(
    List<String> guard,
    LaunchCommand launch, {
    Duration grace = const Duration(seconds: 60),
    String? logPath,
  }) async => GuardServerProcess._(
    await GuardClient.start(
      guard: guard,
      executable: launch.executable,
      args: launch.args,
      workDir: launch.workDir,
      env: launch.env,
      grace: grace,
      logPath: logPath,
    ),
  );

  final GuardClient _g;

  @override
  late final Stream<ServerLine> lines = _g.lines.map(
    (l) => ServerLine(truncateConsoleLine(l.text), stderr: l.stderr, at: l.at),
  );

  @override
  Future<void> send(String command) => _g.send(command);

  @override
  Future<void> stop() => _g.stop();

  @override
  Future<void> kill() => _g.kill();

  @override
  Future<ServerEnd> get exit async {
    final e = await _g.exit;
    return ServerEnd(exitCode: e.exitCode, reason: e.reason);
  }

  @override
  bool get running => _g.running;

  /// Uscita "pulita" chiesta da noi o dal server stesso (non un crash).
  static bool isClean(ServerEnd e) =>
      e.reason == GuardExit.stopped || (e.reason == GuardExit.exited && e.exitCode == 0);
}
