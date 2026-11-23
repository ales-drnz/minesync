// Prova end to end: l'hub vero in un processo separato e due "PC" (due
// cartelle di configurazione e due cartelle di lavoro) che usano la CLI.
@Tags(['e2e'])
@Timeout(Duration(minutes: 4))
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
  late int port;
  late HashPool pool;

  setUpAll(() async {
    pool = HashPool.spawn(2);
    tmp = Directory.systemTemp.createTempSync('ms_e2e');
    hub = await HubProcess.start('${tmp.path}/data');
    port = hub.port;
    final admin = HubClient(hub.uri);
    await admin.createSpace('Survival', Profile.minecraft);
    admin.close();
  });

  tearDownAll(() async {
    await hub.stop();
    await pool.close();
    await deleteQuietly(tmp);
  });

  Future<(int, String, String)> cli(String pc, List<String> args) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runCli(
      args,
      env: {'MINESYNC_CONFIG_DIR': '${tmp.path}/$pc/config', 'LANG': 'en_US.UTF-8'},
      out: out,
      err: err,
      pool: pool,
    );
    return (code, out.toString(), err.toString());
  }

  String work(String pc) => '${tmp.path}/$pc/world';

  File put(String pc, String rel, String content) => File('${work(pc)}/$rel')
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  Future<void> ok(String pc, List<String> args) async {
    final (code, out, err) = await cli(pc, args);
    expect(code, 0, reason: '$pc ${args.join(' ')}\n$out$err\n--- hub ---\n${hub.log}');
  }

  test('due PC si passano il mondo attraverso l\'hub', () async {
    for (final pc in ['a', 'b']) {
      await ok(pc, ['login', '127.0.0.1:$port']);
      await ok(pc, ['link', 'survival', work(pc)]);
    }

    // A carica il primo mondo
    put('a', 'server.properties', 'motd=prima');
    put('a', 'world/level.dat', 'L1');
    File('${work('a')}/world/region/r.0.0.mca')
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.generate(5 << 20, (i) => (i * 13 + (i >> 10)) & 0xff));
    put('a', 'logs/latest.log', 'escluso');
    await ok('a', ['push', '-m', 'primo']);

    // B lo scarica uguale
    await ok('b', ['pull']);
    expect(File('${work('b')}/world/level.dat').readAsStringSync(), 'L1');
    expect(File('${work('b')}/logs/latest.log').existsSync(), isFalse);
    expect(
      File('${work('b')}/world/region/r.0.0.mca').readAsBytesSync(),
      File('${work('a')}/world/region/r.0.0.mca').readAsBytesSync(),
    );
    await ok('b', ['verify']);

    // B gioca e carica; A scarica
    put('b', 'world/level.dat', 'L2');
    await ok('b', ['push']);
    await ok('a', ['pull']);
    expect(File('${work('a')}/world/level.dat').readAsStringSync(), 'L2');

    // A modifica senza caricare, B carica: il pull di A si ferma
    put('a', 'world/level.dat', 'L3 di A');
    put('b', 'server.properties', 'motd=di B');
    await ok('b', ['push']);
    var (code, _, err) = await cli('a', ['pull']);
    expect(code, 1);
    expect(err, contains('--discard-local'));
    expect(File('${work('a')}/world/level.dat').readAsStringSync(), 'L3 di A');

    // e anche il push di A, che parte da una versione vecchia
    (code, _, err) = await cli('a', ['push']);
    expect(code, 1);
    expect(err, contains('pull first'));

    // A sceglie la versione dell'hub: le sue modifiche finiscono nel backup
    final (c2, out, _) = await cli('a', ['pull', '--discard-local']);
    expect(c2, 0);
    expect(out, contains('.minesync'));
    expect(File('${work('a')}/server.properties').readAsStringSync(), 'motd=di B');
    expect(File('${work('a')}/world/level.dat').readAsStringSync(), 'L2');

    // stato e storia
    final (_, status, _) = await cli('a', ['status']);
    expect(status, contains('version #3'));
    final (_, spaces, _) = await cli('a', ['spaces']);
    expect(spaces, contains('survival'));
    expect(spaces, contains('free'));
  });
}
