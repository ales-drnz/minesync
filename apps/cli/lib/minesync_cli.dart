/// La riga di comando `minesync`: login, server, collegamenti, pull, push e
/// verifica, sopra il motore di ms_core.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ms_core/ms_core.dart';
import 'package:ms_l10n/ms_l10n.dart';
import 'package:ms_minecraft/ms_minecraft.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_session/ms_session.dart';

/// Versione della CLI.
const String cliVersion = '0.1.0';

/// Errore con messaggio già tradotto, codice di uscita 1.
final class _Fail implements Exception {
  const _Fail(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Errore d'uso: messaggio già tradotto, codice di uscita 2.
final class _Usage implements Exception {
  const _Usage(this.message);
  final String message;
}

/// Esegue la CLI. Restituisce il codice di uscita.
Future<int> runCli(
  List<String> args, {
  Map<String, String>? env,
  StringSink? out,
  StringSink? err,
  HashPool? pool,
  Stream<String>? input,
}) async {
  final e = env ?? Platform.environment;
  final o = out ?? stdout;
  final er = err ?? stderr;
  final dir = configDir(e);
  final config = AppConfig.load(dir);
  final s = Strings.of(parseLang(config.lang) ?? langFromEnv(e));
  final cli = _Cli(s, config, dir, o, er, pool, e, input);
  try {
    return await cli.run(args);
  } on _Usage catch (u) {
    er
      ..writeln(u.message)
      ..writeln()
      ..write(s.cliUsage);
    return 2;
  } on _Fail catch (f) {
    er.writeln(s.cliError(f.message));
    return 1;
  } on Object catch (x) {
    er.writeln(s.cliError(describeError(s, x)));
    return 1;
  } finally {
    cli.close();
  }
}

/// Spiegazione per l'utente di un errore del sync o dell'hub.
String describeError(Strings s, Object e) => switch (e) {
  SyncException(kind: SyncErrorKind.dirtyLocal) => s.errDirtyLocal(
    diverged: e.diverged,
    changed: e.changed.length,
    removed: e.removed.length,
  ),
  SyncException(kind: SyncErrorKind.staleBase) => s.errStaleBase,
  SyncException(kind: SyncErrorKind.massDelete) => s.errMassDelete(e.removed.length),
  SyncException(kind: SyncErrorKind.emptyRemote) => s.errEmptyRemote,
  SyncException(kind: SyncErrorKind.lockLost) => s.errLockLost,
  SyncException(kind: SyncErrorKind.spaceGone) => s.errSpaceGone,
  SyncException(kind: SyncErrorKind.badManifest) => s.errBadManifest,
  SyncException(kind: SyncErrorKind.corruptDownload) => s.errCorruptDownload,
  SyncException(kind: SyncErrorKind.blobRejected) => s.errBlobRejected,
  SyncException(kind: SyncErrorKind.localDiskFull) => s.errLocalDiskFull,
  SyncException(kind: SyncErrorKind.hubDiskFull) => s.errHubDiskFull,
  SyncException(kind: SyncErrorKind.dirSymlink) => s.errDirSymlink(e.path ?? ''),
  SyncException(kind: SyncErrorKind.outboxNoSpace) => s.errOutboxNoSpace,
  SyncException(kind: SyncErrorKind.snapshotStale) => s.errSnapshotStale,
  SyncException(kind: SyncErrorKind.cancelled) => s.errCancelled,
  ApiError(code: ErrorCode.unauthenticated) => s.errUnauthenticated,
  ApiError(code: ErrorCode.forbidden) => s.errForbidden,
  ApiError(code: ErrorCode.locked) => s.errLocked(
    (e.details['lock'] as Map<String, Object?>?)?['name'] as String? ??
        e.details['owner'] as String? ??
        '?',
  ),
  ApiError(code: ErrorCode.spaceGone || ErrorCode.notFound) => s.errSpaceGone,
  ApiError(code: ErrorCode.diskFull) => s.errHubDiskFull,
  ApiError() => e.message,
  HubUnreachable() => s.cliUnreachable,
  TransferStalled() => s.errStalled,
  _ => '$e',
};

final class _Cli {
  _Cli(this.s, this.config, this.dir, this.out, this.err, this._pool, this.env, this.input);

  final Map<String, String> env;

  /// Righe della console (stdin se null).
  final Stream<String>? input;

  final Strings s;
  final AppConfig config;
  final String dir;
  final StringSink out;
  final StringSink err;
  final HashPool? _pool;
  HubClient? _client;

  HubClient get client {
    final hub = config.hub;
    if (hub == null) throw _Usage(s.cliNoHub);
    return _client ??= HubClient(Uri.parse(hub), userAgent: 'minesync-cli/$cliVersion');
  }

  void close() => _client?.close();

  Future<int> run(List<String> args) async {
    if (args.isEmpty || args.first == 'help' || args.first == '--help' || args.first == '-h') {
      out.write(s.cliUsage);
      return args.isEmpty ? 2 : 0;
    }
    if (args.first == '--version' || args.first == 'version') {
      out.writeln('minesync $cliVersion');
      return 0;
    }
    final rest = args.sublist(1);
    return switch (args.first) {
      'login' => _login(rest),
      'spaces' => _spaces(),
      'link' => _link(rest),
      'status' => _status(rest),
      'pull' => _pull(rest),
      'push' => _push(rest),
      'verify' => _verify(rest),
      'play' => _play(rest),
      final c => throw _Usage(s.cliUnknownCommand(c)),
    };
  }

  Future<int> _login(List<String> a) async {
    if (a.length != 1) throw _Usage(s.cliUsage.split('\n').first);
    var addr = a.single.trim();
    if (!addr.contains('://')) addr = 'http://$addr';
    var uri = Uri.parse(addr);
    if (!uri.hasPort) uri = uri.replace(port: 8084);
    config.hub = uri.toString();
    final info = await client.hub();
    await config.save(dir);
    out.writeln(s.cliConnected(config.hub!, info.me.name, info.me.admin));
    return 0;
  }

  Future<int> _spaces() async {
    final list = await client.spaces();
    if (list.isEmpty) {
      out.writeln(s.cliNoSpaces);
      return 0;
    }
    for (final sp in list) {
      final lock = sp.lock == null ? s.cliLockFree : s.cliLockHeld(sp.lock!.name, sp.lock!.stale);
      final head = sp.head == null ? s.cliEmptySpace : s.cliHead(sp.head!.n, sp.head!.author);
      final linked = config.links[sp.id];
      out.writeln(
        '${sp.id}  ${sp.name}  ·  $head  ·  $lock${linked == null ? '' : '  ·  $linked'}',
      );
    }
    return 0;
  }

  Future<int> _link(List<String> a) async {
    if (a.length != 2) throw _Usage(s.cliNotLinked);
    final details = await client.space(a[0]);
    final folder = Directory(a[1]).absolute.path;
    Directory(folder).createSync(recursive: true);
    config.links[details.summary.id] = folder;
    await config.save(dir);
    out.writeln(s.cliLinked(details.summary.id, folder));
    return 0;
  }

  /// Server indicato, o l'unico collegato.
  (String, String) _target(List<String> positional) {
    if (positional.isNotEmpty) {
      final id = positional.first;
      final folder = config.links[id];
      if (folder == null) throw _Usage(s.cliNotLinked);
      return (id, folder);
    }
    if (config.links.length == 1) {
      final e = config.links.entries.single;
      return (e.key, e.value);
    }
    throw _Usage(s.cliNotLinked);
  }

  SyncEngine _engine(String id, String folder) =>
      SyncEngine(client, id, folder, pool: _pool, onProgress: _progress);

  void _progress(SyncProgress p) {
    if (p.phase == 'scan' || p.total == 0) return;
    if (err is Stdout && (err as Stdout).hasTerminal) {
      err.write('\r${s.cliProgress(p.phase, p.done, p.total)}\x1b[K');
    }
  }

  void _endProgress() {
    if (err is Stdout && (err as Stdout).hasTerminal) err.write('\r\x1b[K');
  }

  Future<int> _status(List<String> a) async {
    final info = await client.hub();
    out.writeln(s.cliConnected(config.hub!, info.me.name, info.me.admin));
    final ids = a.isNotEmpty ? [a.first] : config.links.keys.toList();
    for (final id in ids) {
      final d = await client.space(id);
      final sp = d.summary;
      final lock = sp.lock == null ? s.cliLockFree : s.cliLockHeld(sp.lock!.name, sp.lock!.stale);
      final head = sp.head == null ? s.cliEmptySpace : s.cliHead(sp.head!.n, sp.head!.author);
      final folder = config.links[id];
      final base = folder == null ? null : LocalState(folder).loadBase(id);
      out
        ..writeln('${sp.name} ($id)')
        ..writeln('  $head  ·  $lock');
      if (folder != null) out.writeln('  $folder  ·  ${s.cliLocalBase(base?.n)}');
    }
    return 0;
  }

  Future<int> _pull(List<String> a) async {
    final discard = a.contains('--discard-local');
    final (id, folder) = _target([
      for (final x in a)
        if (!x.startsWith('-')) x,
    ]);
    try {
      final r = await _engine(id, folder).pull(discardLocal: discard);
      _endProgress();
      out.writeln(s.cliPulled(r.n, r.written, r.deleted));
      if (r.backup != null) out.writeln(s.cliBackup(r.backup!));
      return 0;
    } finally {
      _endProgress();
    }
  }

  Future<int> _push(List<String> a) async {
    var message = '';
    final positional = <String>[];
    for (var i = 0; i < a.length; i++) {
      if (a[i] == '-m' && i + 1 < a.length) {
        message = a[++i];
      } else if (!a[i].startsWith('-')) {
        positional.add(a[i]);
      }
    }
    final (id, folder) = _target(positional);
    final lock = await client.acquireLock(id, const LockInfo(client: 'minesync-cli/$cliVersion'));
    try {
      final r = await _engine(id, folder).push(lock: lock, message: message);
      _endProgress();
      if (r.generation == null) {
        out.writeln(s.cliNothingToPush);
      } else {
        out.writeln(s.cliPushed(r.generation!.n, r.uploaded));
      }
      if (r.kept.isNotEmpty) out.writeln(s.cliKept(r.kept.length, r.kept.first));
      return 0;
    } finally {
      _endProgress();
      try {
        await client.releaseLock(id, lock.token);
      } on Object {
        // il lock scade comunque da solo
      }
    }
  }

  /// Comando del guard: MINESYNC_GUARD, oppure minesync-guard accanto a
  /// questo eseguibile.
  List<String> _guardCommand() {
    final fromEnv = env['MINESYNC_GUARD'];
    if (fromEnv != null && fromEnv.isNotEmpty) return [fromEnv];
    final exe = File(Platform.resolvedExecutable);
    final name = Platform.isWindows ? 'minesync-guard.exe' : 'minesync-guard';
    final sibling = File('${exe.parent.path}${Platform.pathSeparator}$name');
    if (sibling.existsSync()) return [sibling.path];
    throw _Fail(s.playGuardMissing);
  }

  Future<int> _play(List<String> a) async {
    var discard = false, eulaOk = false;
    String? javaPath;
    int? xmx;
    final positional = <String>[];
    for (var i = 0; i < a.length; i++) {
      switch (a[i]) {
        case '--discard-local':
          discard = true;
        case '--accept-eula':
          eulaOk = true;
        case '--java' when i + 1 < a.length:
          javaPath = a[++i];
        case '--xmx' when i + 1 < a.length:
          xmx = int.tryParse(a[++i]);
        case final x when !x.startsWith('-'):
          positional.add(x);
      }
    }
    final (id, folder) = _target(positional);
    final guard = _guardCommand();
    final autosave = int.tryParse(env['MINESYNC_AUTOSAVE_SECONDS'] ?? '');
    final engine = _engine(id, folder)..uploadLimit = _uploadLimit();
    late final Session session;

    Future<ServerProcess> launch() async {
      final layout = detectServer(folder);
      if (layout.launch == null) throw _Fail(s.playNoLaunch);
      if (!isEulaAccepted(layout.workDir)) {
        if (!eulaOk) throw _Fail(s.playEulaNeeded);
        await acceptEula(layout.workDir);
      }
      session.port = serverPort(readServerProperties(layout.workDir));
      JavaRuntime? java;
      if (javaPath != null) {
        java = await probeJava(javaPath);
      } else {
        final found = await findJavaRuntimes(serverRoot: layout.workDir, env: env);
        java = pickJava(found, layout.requiredJavaMajor);
      }
      final needsJava = layout.launch is! ScriptLaunch;
      if (needsJava && java == null) throw _Fail(s.playJavaMissing(layout.requiredJavaMajor));
      final cmd = buildLaunch(layout, java: java, xmxMiB: xmx, baseEnv: env);
      err.writeln('minesync: ${s.playStarting(layout.label, java?.path)}');
      return GuardServerProcess.start(guard, cmd);
    }

    session = Session(
      engine: engine,
      launch: launch,
      parse: minecraftParse,
      config: autosave == null
          ? const SessionConfig()
          : SessionConfig(autosaveEvery: Duration(seconds: autosave)),
      // le impostazioni delle sessioni dell'hub, salvo un periodo forzato
      // dall'ambiente (test e diagnostica)
      followHub: autosave == null,
      clientVersion: cliVersion,
    );
    final subs = <StreamSubscription<Object?>>[
      session.events.listen((e) {
        switch (e) {
          case LineReceived(:final line):
            out.writeln(line.text);
          case StateChanged(:final state):
            err.writeln('minesync: ${s.playState(state.name)}');
          case SavedToHub(:final generation):
            err.writeln('minesync: ${s.playSaved(generation)}');
          case SessionWarning(:final code):
            err.writeln('minesync: ${s.playWarning(code)}');
          case SessionAlert(:final kind):
            err.writeln('minesync: ${s.playAlert(kind)}');
          case ServerCrashed(:final exitCode, :final restarting):
            err.writeln('minesync: ${s.playCrashed(exitCode, restarting)}');
          case PlayersChanged() || TransferProgress() || SettingsApplied():
            break;
        }
      }),
      (input ?? stdin.transform(utf8.decoder).transform(const LineSplitter())).listen((line) {
        if (line.trim().isEmpty) return;
        session.send(line).catchError((Object e) => err.writeln('minesync: $e'));
      }),
      // Ctrl+C: arresto pulito (il guard protegge comunque il server)
      if (input == null) ProcessSignal.sigint.watch().listen((_) => session.stop()),
    ];
    try {
      await session.run(discardLocal: discard);
    } finally {
      for (final sub in subs) {
        await sub.cancel();
      }
    }
    return session.state == SessionState.ended ? 0 : 1;
  }

  /// Limite di banda dei salvataggi in background (KiB/s), da
  /// MINESYNC_UPLOAD_LIMIT; assente o -1 = nessun limite.
  int _uploadLimit() {
    final v = int.tryParse(env['MINESYNC_UPLOAD_LIMIT'] ?? '');
    return v == null || v <= 0 ? 0 : v * 1024;
  }

  Future<int> _verify(List<String> a) async {
    final (id, folder) = _target(a);
    final d = await client.space(id);
    final base = LocalState(folder).loadBase(id);
    // senza cache: ogni file si rilegge davvero
    final scan = await scanTree(folder, Exclusions(d.exclusions), pool: _pool);
    final ref = base?.manifest ?? Manifest.empty;
    final diff = ManifestDiff(ref, scan.manifest);
    if (diff.isEmpty) {
      out.writeln(s.cliVerifyOk(scan.manifest.length));
      return 0;
    }
    out.writeln(s.cliVerifyDiff(diff.changed.length, diff.removed.length, diff.added.length));
    for (final p in diff.changed) {
      out.writeln('  ~ $p');
    }
    for (final p in diff.removed) {
      out.writeln('  - $p');
    }
    for (final p in diff.added) {
      out.writeln('  + $p');
    }
    return 1;
  }
}
