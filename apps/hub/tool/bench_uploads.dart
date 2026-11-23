// Misura della memoria dell'hub con molti upload paralleli.
//
//   dart compile exe bin/hub.dart -o .dart_tool/hub
//   dart run tool/bench_uploads.dart .dart_tool/hub <cartella-dati> [upload] [MiB]
//
// Avvia l'hub compilato con DART_VM_OPTIONS=--old_gen_heap_size=128, crea
// uno spazio, inizia un push con [upload] blob da [MiB] MiB (16 × 256 di
// default) e li carica tutti insieme, campionando VmRSS e VmHWM del processo
// da /proc. Solo Linux. La cartella dati viene svuotata alla fine.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ms_core/ms_core.dart';

const _block = 1 << 20;

/// Blocco [i] del blob [b]: un blocco casuale fisso con indici diversi in
/// testa, così ogni blob ha un hash suo senza generare GiB di rumore.
Uint8List block(Uint8List base, int b, int i) {
  final out = Uint8List.fromList(base);
  ByteData.sublistView(out)
    ..setUint64(0, b)
    ..setUint64(8, i);
  return out;
}

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('uso: bench_uploads.dart <hub-exe> <cartella-dati> [upload] [MiB]');
    exit(2);
  }
  final exe = args[0], data = args[1];
  final count = args.length > 2 ? int.parse(args[2]) : 16;
  final mib = args.length > 3 ? int.parse(args[3]) : 256;
  await Directory(data).create(recursive: true);
  final base = Uint8List(_block);
  for (var i = 0; i < _block; i++) {
    base[i] = (i * 2654435761) >> 13;
  }
  stdout.writeln('hash di $count blob da $mib MiB...');
  final hashes = <String>[];
  for (var b = 0; b < count; b++) {
    final ctx = backend.newCtx();
    for (var i = 0; i < mib; i++) {
      ctx.update(block(base, b, i));
    }
    hashes.add(hex(ctx.finish()));
    ctx.dispose();
  }

  final p = await Process.start(
    exe,
    const [],
    environment: {
      'MINESYNC_DATA': data,
      'MINESYNC_ADDR': '127.0.0.1:0',
      'MINESYNC_DEV_USER': 'alice',
      'MINESYNC_ADMINS': 'alice',
      'MINESYNC_MIN_FREE': '1',
      'DART_VM_OPTIONS': '--old_gen_heap_size=128',
      'MINESYNC_RCVBUF': ?Platform.environment['MINESYNC_RCVBUF'],
    },
  );
  final port = Completer<int>();
  p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
    stderr.writeln('[hub] $l');
    final m = RegExp(r'in ascolto su .*:(\d+),').firstMatch(l);
    if (m != null && !port.isCompleted) port.complete(int.parse(m[1]!));
  });
  final api = 'http://127.0.0.1:${await port.future}/api/v1';
  final client = HttpClient()..maxConnectionsPerHost = count + 4;

  Future<Map<String, Object?>> call(String method, String path, [Object? body]) async {
    final r = await client.openUrl(method, Uri.parse('$api$path'));
    r.headers.set('X-MineSync', '1');
    if (body != null) r.add(utf8.encode(jsonEncode(body)));
    final res = await r.close();
    final s = await utf8.decoder.bind(res).join();
    if (res.statusCode >= 300) throw StateError('$method $path: ${res.statusCode} $s');
    return jsonDecode(s) as Map<String, Object?>;
  }

  int kb(String key) {
    final l = File('/proc/${p.pid}/status').readAsLinesSync().firstWhere((l) => l.startsWith(key));
    return int.parse(l.split(RegExp(r'\s+'))[1]);
  }

  await call('POST', '/spaces', {'name': 'Bench'});
  final tok = (await call('POST', '/spaces/bench/lock', {}))['token']! as String;
  final head = await call('GET', '/spaces/bench/generations/head');
  final begin = await call('POST', '/spaces/bench/pushes', {
    'parent': 0,
    'parentDigest': head['digest'],
    'lockToken': tok,
    'manifest': {
      for (var b = 0; b < count; b++) 'blob$b.bin': {'size': mib * _block, 'h': hashes[b]},
    },
  });
  final pid = begin['pushId']! as String;
  final idle = kb('VmRSS:');
  var peak = idle;
  final sampler = Timer.periodic(const Duration(milliseconds: 50), (_) {
    try {
      final r = kb('VmRSS:');
      if (r > peak) peak = r;
    } catch (_) {
      // processo finito
    }
  });
  final sw = Stopwatch()..start();
  final results = await Future.wait([
    for (var b = 0; b < count; b++)
      () async {
        final r = await client.putUrl(Uri.parse('$api/pushes/$pid/blobs/${hashes[b]}'));
        r.headers.set('X-MineSync', '1');
        r.contentLength = mib * _block;
        for (var i = 0; i < mib; i++) {
          r.add(block(base, b, i));
          await r.flush();
        }
        final res = await r.close();
        await res.drain<void>();
        return res.statusCode;
      }(),
  ]);
  sw.stop();
  sampler.cancel();
  final commit = await call('POST', '/pushes/$pid/commit');
  final hwm = kb('VmHWM:');
  final ok = results.where((s) => s == 201).length;
  final total = count * mib;
  stdout
    ..writeln('upload riusciti: $ok/$count, commit n=${commit['n']}')
    ..writeln(
      'tempo ${sw.elapsedMilliseconds} ms, ${(total * 1000 / sw.elapsedMilliseconds).round()} MiB/s',
    )
    ..writeln(
      'RSS a riposo ${idle ~/ 1024} MiB, picco campionato ${peak ~/ 1024} MiB, VmHWM ${hwm ~/ 1024} MiB',
    );
  p.kill();
  await p.exitCode;
  client.close(force: true);
  await Directory(data).delete(recursive: true);
}
