// Dal layout rilevato al comando da eseguire. Puro: non avvia nulla, la
// supervisione del processo è altrove.
import 'dart:io';

import 'package:path/path.dart' as p;

import 'detect.dart';
import 'java.dart';

/// Comando di avvio del server.
final class LaunchCommand {
  const LaunchCommand({
    required this.executable,
    required this.args,
    required this.workDir,
    this.env = const {},
  });

  final String executable;
  final List<String> args;
  final String workDir;

  /// Variabili da impostare SOPRA l'ambiente ereditato (PATH già completo).
  final Map<String, String> env;

  @override
  String toString() => 'LaunchCommand($executable ${args.join(' ')} in $workDir)';
}

/// Il layout non ha un modo di avviare il server.
final class NoLaunchTarget implements Exception {
  const NoLaunchTarget(this.workDir);

  final String workDir;

  @override
  String toString() => 'NoLaunchTarget: no start script or launchable jar in $workDir';
}

/// Costruisce il comando di avvio di [l].
///
/// Con uno script il runtime scelto si impone dall'ambiente, senza toccare
/// lo script: JAVA_HOME, JAVA e la sua `bin` in testa al PATH (gli script
/// Forge/Fabric chiamano `java` nudo). Uno script che scrive a mano il
/// percorso di java ([ScriptLaunch.hardcodedJava]) viene rispettato, e così
/// la memoria che imposta: [xmxMiB] vale solo per jar e file di argomenti.
/// [baseEnv] è l'ambiente ereditato (default quello del processo), serve a
/// comporre il PATH.
LaunchCommand buildLaunch(
  ServerLayout l, {
  JavaRuntime? java,
  int? xmxMiB,
  HostOs? os,
  Map<String, String>? baseEnv,
}) {
  final host = os ?? HostOs.current;
  final target = l.launch;
  if (target == null) throw NoLaunchTarget(l.workDir);
  final env = java == null
      ? const <String, String>{}
      : _javaEnv(java, host, baseEnv ?? Platform.environment);
  final javaExe = java?.path ?? 'java';
  final xmx = xmxMiB != null && xmxMiB > 0 ? ['-Xmx${xmxMiB}M'] : const <String>[];

  switch (target) {
    case ScriptLaunch(:final path, :final kind, :final args):
      final base = p.basename(path);
      return switch (kind) {
        // `call` regge i nomi con spazi e i .bat che ne chiamano altri
        ScriptKind.batch => LaunchCommand(
          executable: 'cmd.exe',
          args: ['/c', 'call', base, ...args],
          workDir: l.workDir,
          env: env,
        ),
        ScriptKind.powershell => LaunchCommand(
          executable: 'powershell.exe',
          args: ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', base, ...args],
          workDir: l.workDir,
          env: env,
        ),
        // eseguibile: si lancia direttamente, così vale lo shebang; darlo a
        // sh (dash) romperebbe gli script bash di mezzo mondo dei pack
        ScriptKind.posix when target.executable && !target.crlf => LaunchCommand(
          executable: path,
          args: args,
          workDir: l.workDir,
          env: env,
        ),
        ScriptKind.posix => LaunchCommand(
          executable: target.bashOnly ? 'bash' : 'sh',
          args: [base, ...args],
          workDir: l.workDir,
          env: env,
        ),
      };
    case JarLaunch(:final jarPath, :final extraArgs):
      return LaunchCommand(
        executable: javaExe,
        args: [
          ...xmx,
          ...extraArgs,
          '-jar',
          p.relative(jarPath, from: l.workDir),
          'nogui',
        ],
        workDir: l.workDir,
        env: env,
      );
    case ArgsFileLaunch(:final argsFile, :final jvmArgsFile):
      return LaunchCommand(
        executable: javaExe,
        args: [
          if (jvmArgsFile != null) '@$jvmArgsFile',
          // dopo user_jvm_args.txt: per la JVM vince l'ultimo -Xmx
          ...xmx,
          '@$argsFile',
          'nogui',
        ],
        workDir: l.workDir,
        env: env,
      );
  }
}

Map<String, String> _javaEnv(JavaRuntime java, HostOs os, Map<String, String> base) {
  final ctx = os == HostOs.windows ? p.windows : p.posix;
  final bin = ctx.dirname(java.path);
  var pathKey = 'PATH';
  if (os == HostOs.windows) {
    // su Windows la chiave è di solito "Path"
    for (final k in base.keys) {
      if (k.toUpperCase() == 'PATH') {
        pathKey = k;
        break;
      }
    }
  }
  final old = base[pathKey];
  final sep = os == HostOs.windows ? ';' : ':';
  return {
    'JAVA_HOME': ctx.dirname(bin),
    'JAVA': java.path,
    pathKey: old == null || old.isEmpty ? bin : '$bin$sep$old',
  };
}
