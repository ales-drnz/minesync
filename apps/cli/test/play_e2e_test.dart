// Prova end to end di "minesync play": hub vero, guard compilato e server
// finto avviato da uno script come quello di un modpack.
@Tags(['e2e'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:io';

import 'package:minesync_cli/minesync_cli.dart';
import 'package:ms_core/ms_core.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:test/test.dart';

import 'support/hub_process.dart';
import 'support/cleanup.dart';

void main() {
  late Directory tmp;
  late HubProcess hub;
  late HashPool pool;
  late String guardExe;
  late String fakeExe;

  setUpAll(() async {
    pool = HashPool.spawn(2);
    tmp = Directory.systemTemp.createTempSync('ms_play');
    final bin = Directory('${tmp.path}/bin')..createSync();
    final built = await Future.wait([
      compileExe('../guard/bin/minesync_guard.dart', bin.path, 'minesync-guard'),
      compileExe('../guard/bin/fake_minecraft.dart', bin.path, 'fake-minecraft'),
      HubProcess.start('${tmp.path}/data').then((h) {
        hub = h;
        return '';
      }),
    ]);
    guardExe = built[0];
    fakeExe = built[1];
    final admin = HubClient(hub.uri);
    await admin.createSpace('Survival', Profile.minecraft);
    admin.close();
  });

  tearDownAll(() async {
    await hub.stop();
    await pool.close();
    await deleteQuietly(tmp);
  });

  String work(String pc) => '${tmp.path}/$pc/world';

  Map<String, String> env(String pc) => {
    'MINESYNC_CONFIG_DIR': '${tmp.path}/$pc/config',
    'LANG': 'en_US.UTF-8',
    'MINESYNC_GUARD': guardExe,
    'MINESYNC_AUTOSAVE_SECONDS': '1',
    if (Platform.environment['PATH'] != null) 'PATH': Platform.environment['PATH']!,
    if (Platform.environment['SystemRoot'] != null)
      'SystemRoot': Platform.environment['SystemRoot']!,
  };

  Future<(int, String)> cli(
    String pc,
    List<String> args, {
    Stream<String>? input,
    StringBuffer? err,
  }) async {
    final out = StringBuffer();
    final e = err ?? StringBuffer();
    final code = await runCli(args, env: env(pc), out: out, err: e, pool: pool, input: input);
    return (code, '$out$e');
  }

  /// Cartella di un server "modpack" con lo script di avvio del server finto.
  void makePack(String dir) {
    Directory('$dir/world').createSync(recursive: true);
    File('$dir/server.properties').writeAsStringSync('server-port=25570\nmotd=prova\n');
    File('$dir/world/level.dat').writeAsStringSync('inizio');
    if (Platform.isWindows) {
      File(
        '$dir/start.bat',
      ).writeAsStringSync('@echo off\r\n"$fakeExe" --stop-ms 200 --save-ms 50\r\n');
    } else {
      File(
        '$dir/start.sh',
      ).writeAsStringSync('#!/bin/sh\nexec "$fakeExe" --stop-ms 200 --save-ms 50\n');
      Process.runSync('chmod', ['+x', '$dir/start.sh']);
    }
  }

  test('play: EULA, avvio, salvataggio automatico, stop dalla console, caricamento', () async {
    for (final pc in ['a', 'b']) {
      expect((await cli(pc, ['login', '127.0.0.1:${hub.port}'])).$1, 0);
      expect((await cli(pc, ['link', 'survival', work(pc)])).$1, 0);
    }
    makePack(work('a'));

    // senza EULA accettata il server non parte (ma le modifiche locali
    // vengono comunque caricate prima, come in ogni sessione)
    var (code, text) = await cli('a', ['play']);
    expect(code, 1, reason: text);
    expect(text, contains('EULA'));

    final input = StreamController<String>();
    final err = StringBuffer();
    final run = cli('a', ['play', '--accept-eula'], input: input.stream, err: err);
    Future<void> waitFor(String what) async {
      final sw = Stopwatch()..start();
      while (!err.toString().contains(what)) {
        if (sw.elapsed > const Duration(seconds: 60)) {
          fail('manca "$what":\n$err\n--- hub ---\n${hub.log}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    await waitFor('server running');
    File('${work('a')}/world/level.dat').writeAsStringSync('giocato');
    await waitFor('saved to the hub');
    input.add('stop');
    (code, text) = await run;
    expect(code, 0, reason: '$text\n--- hub ---\n${hub.log}');
    expect(err.toString(), contains('session ended'));
    await input.close();

    // l'altro PC riceve il mondo giocato e la EULA accettata
    expect((await cli('b', ['pull'])).$1, 0);
    expect(File('${work('b')}/world/level.dat').readAsStringSync(), 'giocato');
    expect(File('${work('b')}/eula.txt').readAsStringSync(), contains('eula=true'));
  });
}
