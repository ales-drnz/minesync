// Driver delle prove: per ogni scenario avvia fake_app → guard → script →
// fake_server (→ nipote), esegue l'azione (kill -9, chiusura, raffica...),
// poi controlla entro un timeout che nessun processo dell'albero resti vivo
// e se l'arresto è stato pulito (<state>/saved scritto dal finto server).
//
// uso: scenarios --bin DIR --work DIR [--only nome,nome] [--fixtures DIR]
// Exit code 0 solo se passano tutti gli scenari "gating" del sistema corrente.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:guard_spike/tree.dart' show isAlive, listProcesses;

late String binDir, workDir, fixDir;
String get exeExt => Platform.isWindows ? '.exe' : '';
String exe(String n) => '$binDir${Platform.pathSeparator}$n$exeExt';
String get os => Platform.operatingSystem;

class Scn {
  Scn(this.name, this.action,
      {this.gating = true,
      this.oses = const {'linux', 'macos', 'windows'},
      this.guardArgs = const [],
      this.serverArgs = const [],
      this.fallback = false,
      this.execScript = false,
      this.appStays = false,
      this.expectClean,
      this.expectOrphans = false,
      this.timeout = const Duration(seconds: 15),
      this.note = ''});
  final String name;
  final Future<Map<String, Object?>> Function(Ctx) action;
  final bool gating, fallback, execScript, appStays, expectOrphans;
  final Set<String> oses;
  final List<String> guardArgs, serverArgs;
  final bool? expectClean;
  final Duration timeout;
  final String note;
}

class Ctx {
  Ctx(this.state, this.app);
  final String state;
  final Process app;
  final pids = <String, int>{};
  void send(String cmd) => app.stdin.writeln(cmd);
  Future<void> kill9(int pid) async {
    if (Platform.isWindows) {
      await Process.run('taskkill', ['/F', '/PID', '$pid']);
    } else {
      Process.killPid(pid, ProcessSignal.sigkill);
    }
  }
}

Future<bool> waitFile(String p, Duration t) async {
  final end = DateTime.now().add(t);
  while (DateTime.now().isBefore(end)) {
    if (File(p).existsSync()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return false;
}

int? readPid(String p) {
  try {
    return int.parse(File(p).readAsStringSync().trim());
  } catch (_) {
    return null;
  }
}

/// Processi che hanno la cartella di stato nella riga di comando (cioè
/// qualunque pezzo dell'albero di questo scenario), escluso il driver.
Future<List<int>> scanByArgs(String state) async {
  if (Platform.isWindows) {
    final r = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      "Get-CimInstance Win32_Process | Where-Object { \$_.CommandLine -like '*$state*' -and \$_.ProcessId -ne \$PID } | ForEach-Object { \$_.ProcessId }"
    ]);
    return [
      for (final l in (r.stdout as String).split('\n'))
        if (int.tryParse(l.trim()) != null) int.parse(l.trim())
    ];
  }
  return [
    for (final r in listProcesses(withArgs: true))
      if (!r.zombie && r.pid != pid && r.args.contains(state)) r.pid
  ];
}

List<Scn> scenarios() {
  Future<Map<String, Object?>> killApp(Ctx c) async {
    await c.kill9(c.pids['app']!);
    return {};
  }

  final linuxOnly = {'linux'};
  final posix = {'linux', 'macos'};
  return [
    Scn('normal-stop', (c) async {
      c.send('stop');
      return {};
    }, expectClean: true),
    Scn('app-exit-without-stop', (c) async {
      c.send('abrupt');
      return {};
    }, expectClean: true, note: 'app exits(0) without telling the guard'),
    Scn('app-closes-guard-stdin', (c) async {
      c.send('closestdin');
      return {};
    }, expectClean: true, appStays: true),
    Scn('kill9-app', killApp, expectClean: true),
    Scn('kill9-app-during-burst', (c) async {
      c.send('burst 10000000 5000');
      await Future<void>.delayed(const Duration(seconds: 1));
      await c.kill9(c.pids['app']!);
      return {};
    }, expectClean: true, note: 'guard must survive EPIPE on its stdout'),
    Scn('sigterm-app', (c) async {
      Process.killPid(c.pids['app']!, ProcessSignal.sigterm);
      return {};
    }, oses: posix, expectClean: true),
    Scn('kill9-app-stdin-eof-only', killApp,
        guardArgs: ['--no-pdeathsig', '--no-parent-watch'],
        expectClean: true,
        note: 'only EOF on the guard\'s stdin can notice'),
    Scn('kill9-app-parent-poll-only', killApp,
        oses: posix,
        guardArgs: ['--no-stdin-eof', '--no-pdeathsig'],
        expectClean: true,
        note: 'only the getppid() poll (250 ms) can notice'),
    Scn('kill9-app-pdeathsig-only', killApp,
        oses: linuxOnly,
        guardArgs: ['--no-stdin-eof', '--no-parent-watch'],
        expectClean: true,
        note: 'only the guard\'s own PR_SET_PDEATHSIG(SIGUSR2) can notice'),
    Scn('kill9-app-parent-handle-only', killApp,
        oses: {'windows'},
        guardArgs: ['--no-stdin-eof'],
        expectClean: true,
        note: 'only the OpenProcess/WaitForSingleObject poll can notice'),
    Scn('hang-server-grace-kill', killApp,
        guardArgs: ['--grace', '3'],
        serverArgs: [
          '--hang',
          if (!Platform.isMacOS) '--helper-detached',
        ],
        expectClean: false,
        note: 'server ignores stop; grandchild left the process group '
            '(Linux/Windows): tree must be killed after the 3 s grace'),
    Scn('burst-5000-lines-per-s', (c) async {
      c.send('burst 50000 5000');
      final ok =
          await waitFile('${c.state}/burst.json', const Duration(seconds: 40));
      final res = ok
          ? jsonDecode(File('${c.state}/burst.json').readAsStringSync()) as Map
          : {'lost': -1};
      c.send('stop');
      return {'burst': res, 'burstOk': res['lost'] == 0 && res['dup'] == 0};
    }, expectClean: true, timeout: const Duration(seconds: 20)),
    Scn('burst-max-speed', (c) async {
      c.send('burst 500000 0');
      final ok =
          await waitFile('${c.state}/burst.json', const Duration(seconds: 60));
      final res = ok
          ? jsonDecode(File('${c.state}/burst.json').readAsStringSync()) as Map
          : {'lost': -1};
      c.send('stop');
      return {'burst': res, 'burstOk': res['lost'] == 0 && res['dup'] == 0};
    }, gating: false, expectClean: true, timeout: const Duration(seconds: 20)),
    Scn('kill9-guard-app-fallback', (c) async {
      await c.kill9(c.pids['guard']!);
      return {};
    },
        oses: posix,
        fallback: true,
        appStays: true,
        expectClean: true,
        timeout: const Duration(seconds: 20),
        note: 'app sees guard die, sends SIGTERM to the guard\'s process group'),
    Scn('kill9-guard-job-object', (c) async {
      await c.kill9(c.pids['guard']!);
      return {};
    },
        oses: {'windows'},
        appStays: true,
        expectClean: false,
        note: 'kernel kills the tree when the job handle closes (not clean)'),
    Scn('taskkill-tree-app', (c) async {
      await Process.run('taskkill', ['/F', '/T', '/PID', '${c.pids['app']}']);
      return {};
    },
        oses: {'windows'},
        note: 'Task Manager "End process tree": everything dies at once'),
    Scn('kill9-guard-no-fallback', (c) async {
      await c.kill9(c.pids['guard']!);
      return {};
    },
        oses: posix,
        gating: false,
        appStays: true,
        expectOrphans: true,
        timeout: const Duration(seconds: 4),
        note: 'documents the residual risk'),
    Scn('kill9-app-and-guard', (c) async {
      await c.kill9(c.pids['guard']!);
      await c.kill9(c.pids['app']!);
      return {};
    },
        oses: posix,
        gating: false,
        expectOrphans: true,
        timeout: const Duration(seconds: 4),
        note: 'documents the residual risk'),
    Scn('kill9-app-and-guard-setpriv-exec', (c) async {
      await c.kill9(c.pids['guard']!);
      await c.kill9(c.pids['app']!);
      return {};
    },
        oses: linuxOnly,
        gating: false,
        guardArgs: ['--pdeathsig-wrapper'],
        execScript: true,
        expectClean: true,
        note: 'setpriv --pdeathsig TERM, script uses exec'),
    Scn('kill9-app-and-guard-setpriv-sh', (c) async {
      await c.kill9(c.pids['guard']!);
      await c.kill9(c.pids['app']!);
      return {};
    },
        oses: linuxOnly,
        gating: false,
        guardArgs: ['--pdeathsig-wrapper'],
        expectOrphans: true,
        timeout: const Duration(seconds: 5),
        note: 'setpriv signals only sh; java-like child survives'),
    Scn('idle-20s-no-spurious-pdeathsig', (c) async {
      await Future<void>.delayed(const Duration(seconds: 20));
      final alive = isAlive(c.pids['server']!);
      final saved = File('${c.state}/saved').existsSync();
      final log = File('${c.state}/app_console.log').readAsStringSync();
      c.send('stop');
      return {
        'idleOk': alive && !saved && !log.contains('spurio'),
      };
    },
        oses: linuxOnly,
        guardArgs: ['--pdeathsig-wrapper'],
        execScript: true,
        expectClean: true,
        timeout: const Duration(seconds: 15),
        note: 'both PDEATHSIGs armed; nothing may fire while idle'),
  ];
}

Future<Map<String, Object?>> runOne(Scn s) async {
  final state = '$workDir${Platform.pathSeparator}${s.name}';
  final d = Directory(state);
  if (d.existsSync()) d.deleteSync(recursive: true);
  d.createSync(recursive: true);

  final List<String> server;
  if (Platform.isWindows) {
    server = ['cmd.exe', '/c', '$fixDir\\start.bat', exe('fake_server'),
      '--state', state, ...s.serverArgs];
  } else {
    server = ['/bin/sh', '$fixDir/${s.execScript ? 'start_exec.sh' : 'start.sh'}',
      exe('fake_server'), '--state', state, ...s.serverArgs];
  }
  final app = await Process.start(exe('fake_app'), [
    '--guard', exe('guard'),
    '--state', state,
    if (s.fallback) '--fallback',
    for (final g in [...s.guardArgs, '--log', '$state/guard_after_parent.log'])
      ...['--guard-arg', g],
    '--', ...server,
  ]);
  final stdio = File('$state/app_stdio.log').openWrite();
  app.stdout.listen(stdio.add);
  app.stderr.listen(stdio.add);
  app.stdin.done.then((_) {}, onError: (_) {});

  final c = Ctx(state, app);
  final res = <String, Object?>{'name': s.name, 'gating': s.gating, 'note': s.note};
  final ready = await waitFile('$state/ready', const Duration(seconds: 20)) &&
      await waitFile('$state/helper.pid', const Duration(seconds: 5));
  for (final n in ['app', 'guard', 'child', 'server', 'helper']) {
    final p = readPid('$state/$n.pid');
    if (p != null) c.pids[n] = p;
  }
  res['pids'] = c.pids;
  if (File('$state/contain.json').existsSync()) {
    res['contain'] = jsonDecode(File('$state/contain.json').readAsStringSync());
  }
  if (!ready || c.pids.length < 5) {
    res['pass'] = false;
    res['error'] = 'tree did not start';
    await cleanup(c, res);
    return res;
  }

  final sw = Stopwatch()..start();
  res.addAll(await s.action(c));
  final actionMs = sw.elapsedMilliseconds;

  final targets = [
    for (final e in c.pids.entries)
      if (!(s.appStays && e.key == 'app')) e.value
  ];
  final end = DateTime.now().add(s.timeout);
  var alive = targets.where(isAlive).toList();
  while (alive.isNotEmpty && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    alive = targets.where(isAlive).toList();
  }
  final treeGoneMs = sw.elapsedMilliseconds - actionMs;
  final scanned = (await scanByArgs(state))
      .where((p) => !(s.appStays && p == c.pids['app']))
      .toList();
  final orphans = {...alive, ...scanned}.toList();
  final saved = File('$state/saved');
  final clean = saved.existsSync();
  res['treeGoneMs'] = alive.isEmpty ? treeGoneMs : null;
  res['orphans'] = orphans;
  res['clean'] = clean;
  if (clean) res['cleanVia'] = saved.readAsStringSync();
  if (File('$state/guard_exit.json').existsSync()) {
    res['guardExit'] = jsonDecode(File('$state/guard_exit.json').readAsStringSync());
  }

  var pass = (orphans.isNotEmpty) == s.expectOrphans;
  if (s.expectClean != null) pass = pass && clean == s.expectClean;
  if (res.containsKey('burstOk')) pass = pass && res['burstOk'] == true;
  if (res.containsKey('idleOk')) pass = pass && res['idleOk'] == true;
  res['pass'] = pass;
  await cleanup(c, res);
  await stdio.close();
  return res;
}

/// Non lasciare niente in giro, comunque sia andata.
Future<void> cleanup(Ctx c, Map<String, Object?> res) async {
  for (var round = 0; round < 3; round++) {
    final left = {
      ...c.pids.values.where(isAlive),
      ...await scanByArgs(c.state),
    };
    if (left.isEmpty) return;
    for (final p in left) {
      await c.kill9(p);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  res['cleanupFailed'] = true;
}

Future<void> main(List<String> a) async {
  Set<String>? only;
  for (var i = 0; i < a.length; i++) {
    switch (a[i]) {
      case '--bin':
        binDir = a[++i];
      case '--work':
        workDir = a[++i];
      case '--fixtures':
        fixDir = a[++i];
      case '--only':
        only = a[++i].split(',').toSet();
    }
  }
  Directory(workDir).createSync(recursive: true);
  final results = <Map<String, Object?>>[];
  for (final s in scenarios()) {
    if (!s.oses.contains(os)) continue;
    if (only != null && !only.contains(s.name)) continue;
    stdout.write('${s.name.padRight(36)} ');
    final r = await runOne(s);
    results.add(r);
    final b = r['burst'] as Map?;
    stdout.writeln([
      r['pass'] == true ? 'PASS' : 'FAIL',
      s.gating ? '' : '(info)',
      'clean=${r['clean']}',
      'treeGoneMs=${r['treeGoneMs']}',
      'orphans=${(r['orphans'] as List?)?.length ?? '?'}',
      if (b != null)
        'lost=${b['lost']} recv=${b['received']}/${b['expected']} '
            'emitMs=${b['serverEmitMs']} lat=${jsonEncode(b['latencyUs'])}',
      if (r['error'] != null) 'error=${r['error']}',
    ].where((x) => x.isNotEmpty).join(' '));
  }
  File('$workDir/results-$os.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(results));
  final failed =
      results.where((r) => r['gating'] == true && r['pass'] != true).toList();
  stdout.writeln(failed.isEmpty
      ? 'ALL GATING SCENARIOS PASSED ($os)'
      : 'GATING FAILURES: ${failed.map((r) => r['name']).join(', ')}');
  exit(failed.isEmpty ? 0 : 1);
}
