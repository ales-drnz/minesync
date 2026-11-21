// Benchmark e prove di correttezza dello spike SHA-256.
//
// Uso:
//   bench all [--data DIR] [--quick]   correttezza + misure + criteri (exit 0 = PASS)
//   bench correctness [--data DIR]     solo correttezza (vettori, incrociata, tool di sistema)
//
// Le misure usano MB = 10^6 byte.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hash_spike/sha256.dart';

const _mib = 1 << 20;

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
double mbps(int bytes, Duration d) => bytes / d.inMicroseconds; // byte/µs = MB/s

final results = <String, Object>{};
var failures = <String>[];

void check(bool ok, String what) {
  stdout.writeln('${ok ? 'OK  ' : 'FAIL'} $what');
  if (!ok) failures.add(what);
}

Future<void> main(List<String> args) async {
  final mode = args.isEmpty ? 'all' : args.first;
  final quick = args.contains('--quick');
  final di = args.indexOf('--data');
  final data = Directory(di >= 0 ? args[di + 1] : '.tmp/data')..createSync(recursive: true);

  // Il log del backend: in un ambiente senza libcrypto qui si vede il fallback.
  stderr.writeln('sha256: backend=${backend.name} native=${backend.isNative} (${backend.detail})');
  results['backend'] = backend.name;
  results['backendDetail'] = backend.detail;
  results['cpus'] = Platform.numberOfProcessors;
  results['os'] = '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';

  vectors();
  crossCheck();
  if (mode == 'correctness') {
    final files = await makeData(data, small: 64, large: 1, largeSize: 8 * _mib, big: 0);
    await systemToolCheck(data, files);
  } else {
    final files = await makeData(data,
        small: 2000, large: 8, largeSize: 256 * _mib, big: 1 << 30);
    await systemToolCheck(data, files);
    singleThread(quick, files);
    await poolBench(files);
    criteria();
  }
  await HashPool.shared.close();
  File('${data.parent.path}/results-$mode.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(results));
  stdout.writeln(failures.isEmpty ? 'RESULT: PASS' : 'RESULT: FAIL (${failures.join('; ')})');
  exit(failures.isEmpty ? 0 : 1);
}

// --- Correttezza -------------------------------------------------------------

/// Vettori FIPS 180-2 / NIST.
final _vectors = <(String, String)>[
  ('', 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'),
  ('abc', 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'),
  ('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
      '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1'),
  ('abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu',
      'cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1'),
  ('a' * 1000000, 'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0'),
];

/// "Extremely long message" NIST: 2^24 ripetizioni di questo blocco = 1 GiB.
const _longBlock = 'abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmno';
const _longDigest = '50e72a0e26442fe2552dc3938ac58658228c0cbfb1d2ca872ae435266fcd055e';

Iterable<Sha256Backend> allBackends() =>
    ['native', 'hashlib', 'crypto'].map(backendByName).whereType<Sha256Backend>();

void vectors() {
  for (final b in allBackends()) {
    var ok = true;
    for (final (msg, want) in _vectors) {
      final h = Sha256Hasher(b)..add(Uint8List.fromList(utf8.encode(msg)));
      if (hex(h.close()) != want) ok = false;
    }
    check(ok, 'vettori noti (${b.name})');
  }
}

/// Dati pseudo-casuali deterministici (xorshift64).
Uint8List prng(int n, int seed) {
  final out = Uint8List(n);
  var x = seed * 0x9e3779b97f4a7c15 + 1;
  final w = out.buffer.asUint64List(0, n ~/ 8);
  for (var i = 0; i < w.length; i++) {
    x ^= x << 13;
    x ^= x >>> 7;
    x ^= x << 17;
    w[i] = x;
  }
  for (var i = w.length * 8; i < n; i++) {
    out[i] = i * 31 + seed;
  }
  return out;
}

/// Tutti i backend devono coincidere su taglie ai bordi dei blocchi e con
/// update spezzati in modo irregolare (anche oltre la staging di 1 MiB).
void crossCheck() {
  final bs = allBackends().toList();
  final sizes = [0, 1, 55, 56, 63, 64, 65, 127, 128, 1000, _mib - 1, _mib, _mib + 1, 3 * _mib + 17];
  var ok = true;
  for (final n in sizes) {
    final d = prng(n, n);
    final ref = hex((Sha256Hasher(bs.last)..add(d)).close());
    for (final b in bs) {
      // update in un colpo
      if (hex((Sha256Hasher(b)..add(d)).close()) != ref) ok = false;
      // update a pezzi di taglia variabile
      final h = Sha256Hasher(b);
      var p = 0, step = 1;
      while (p < n) {
        final e = math.min(n, p + step);
        h.add(d, p, e);
        p = e;
        step = step * 3 + 7;
      }
      if (hex(h.close()) != ref) ok = false;
    }
  }
  // contesto riusato dopo finish (come nei worker)
  for (final b in bs) {
    final c = b.newCtx();
    c.update(prng(100, 1));
    c.finish();
    c.update(Uint8List.fromList(utf8.encode('abc')));
    if (hex(c.finish()) != _vectors[1].$2) ok = false;
    c.dispose();
  }
  check(ok, 'backend concordi (${bs.map((b) => b.name).join(', ')}) su ${sizes.length} taglie, update spezzati, riuso');
}

// --- Dati ---------------------------------------------------------------------

class DataSet {
  final small = <String>[];
  final large = <String>[];
  String? big;
  int get smallBytes => small.length * 512 * 1024;
}

Future<DataSet> makeData(Directory dir,
    {required int small, required int large, required int largeSize, required int big}) async {
  final ds = DataSet();
  final pool = prng(64 * _mib, 42);
  void write(String path, int size, int seed) {
    final f = File(path);
    if (f.existsSync() && f.lengthSync() == size) return;
    f.parent.createSync(recursive: true);
    final raf = f.openSync(mode: FileMode.write);
    var off = (seed * 7919) % (32 * _mib);
    var left = size;
    final head = Uint8List(8)..buffer.asByteData().setUint64(0, seed);
    raf.writeFromSync(head);
    left -= 8;
    while (left > 0) {
      final n = math.min(left, 32 * _mib);
      raf.writeFromSync(pool, off, off + n);
      left -= n;
      off = (off + 4099) % (32 * _mib);
    }
    raf.closeSync();
  }

  for (var i = 0; i < small; i++) {
    final p = '${dir.path}/small/${i.toString().padLeft(4, '0')}.bin';
    write(p, 512 * 1024, i);
    ds.small.add(p);
  }
  for (var i = 0; i < large; i++) {
    final p = '${dir.path}/large/$i.bin';
    write(p, largeSize, 100000 + i);
    ds.large.add(p);
  }
  if (big > 0) {
    ds.big = '${dir.path}/big.bin';
    write(ds.big!, big, 999);
  }
  return ds;
}

/// Confronto con il tool di sistema: sha256sum (Linux), shasum (macOS),
/// Get-FileHash (Windows). Il nostro hash passa dal pool (= sha256File).
Future<void> systemToolCheck(Directory dir, DataSet ds) async {
  final abs = dir.absolute.path;
  ProcessResult r;
  if (Platform.isWindows) {
    r = await Process.run('powershell', [
      '-NoProfile', '-Command',
      "Get-ChildItem -Recurse -File '$abs' | Get-FileHash -Algorithm SHA256 | "
          "ForEach-Object { \$_.Hash.ToLower() + '  ' + \$_.Path }"
    ]);
  } else {
    final tool = Platform.isMacOS ? 'shasum -a 256' : 'sha256sum';
    r = await Process.run('sh', ['-c', "find '$abs' -type f -print0 | xargs -0 $tool"]);
  }
  if (r.exitCode != 0) {
    check(false, 'tool di sistema: ${r.stderr}');
    return;
  }
  String key(String p) => File(p).absolute.path.replaceAll('\\', '/').toLowerCase();
  final want = <String, String>{};
  for (final line in (r.stdout as String).split('\n')) {
    final m = RegExp(r'^([0-9a-f]{64})\s+\*?(.+?)\s*$').firstMatch(line);
    if (m != null) want[key(m[2]!)] = m[1]!;
  }
  final all = [...ds.small, ...ds.large, ?ds.big];
  final got = await Future.wait(all.map(sha256File));
  var bad = 0;
  for (var i = 0; i < all.length; i++) {
    if (want[key(all[i])] != hex(got[i])) bad++;
  }
  results['systemToolFiles'] = all.length;
  check(bad == 0 && want.length >= all.length,
      'identico al tool di sistema su ${all.length} file (${want.length} hash letti, $bad diversi)');
}

// --- Misure -------------------------------------------------------------------

Duration time(void Function() f) {
  final sw = Stopwatch()..start();
  f();
  return sw.elapsed;
}

Future<Duration> timeAsync(Future<void> Function() f) async {
  final sw = Stopwatch()..start();
  await f();
  return sw.elapsed;
}

/// Mediana di [n] esecuzioni.
Duration median(int n, Duration Function() f) {
  final xs = [for (var i = 0; i < n; i++) f()]..sort();
  return xs[n ~/ 2];
}

Future<Duration> medianAsync(int n, Future<Duration> Function() f) async {
  final xs = [for (var i = 0; i < n; i++) await f()]..sort();
  return xs[n ~/ 2];
}

void singleThread(bool quick, DataSet ds) {
  // Il messaggio lungo NIST (1 GiB) a blocchi da 1 MiB nell'heap Dart:
  // misura e verifica insieme.
  final block = Uint8List.fromList(utf8.encode(_longBlock * (_mib ~/ 64)));
  final st = <String, Object>{};
  for (final b in allBackends()) {
    final pure = !b.isNative;
    final blocks = (pure && quick) ? 256 : 1024;
    String? digest;
    final d = median(pure ? 1 : 3, () => time(() {
          final h = Sha256Hasher(b);
          for (var i = 0; i < blocks; i++) {
            h.add(block);
          }
          digest = hex(h.close());
        }));
    final speed = mbps(blocks * _mib, d);
    st['${b.name}.heap'] = speed.round();
    stdout.writeln('single-thread ${b.name.padRight(12)} ${blocks} MiB da heap Dart: '
        '${speed.toStringAsFixed(0)} MB/s');
    if (blocks == 1024) check(digest == _longDigest, 'messaggio lungo NIST 1 GiB (${b.name})');

    if (b.isNative) {
      // Solo hash: dati già nel buffer nativo di staging (limite superiore).
      final c = b.newCtx();
      c.buffer.setAll(0, block);
      final d2 = median(3, () => time(() {
            for (var i = 0; i < 1024; i++) {
              c.updateBuffer(_mib);
            }
            c.finish();
          }));
      c.dispose();
      st['${b.name}.staging'] = mbps(1 << 30, d2).round();
      stdout.writeln('single-thread ${b.name.padRight(12)} 1024 MiB da staging nativo: '
          '${mbps(1 << 30, d2).toStringAsFixed(0)} MB/s');
    }
  }
  // File da 1 GiB letto a blocchi da 1 MiB nell'isolate principale.
  sha256FileSync(ds.big!); // riscalda la page cache
  final df = median(3, () => time(() => sha256FileSync(ds.big!)));
  st['file1GiB'] = mbps(1 << 30, df).round();
  stdout.writeln('single-thread ${backend.name.padRight(12)} file 1 GiB (page cache): '
      '${mbps(1 << 30, df).toStringAsFixed(0)} MB/s');
  results['singleThread'] = st;
}

Future<void> poolBench(DataSet ds) async {
  final ncpu = Platform.numberOfProcessors;
  final sizes = {1, 2, 4, 8, ncpu}.where((s) => s <= ncpu).toList()..sort();
  final out = <String, Object>{};

  // Riferimento: stessi file, in sequenza, nell'isolate principale.
  for (final p in ds.small) {
    sha256FileSync(p);
  }
  final seqSmall = median(3, () => time(() {
        for (final p in ds.small) {
          sha256FileSync(p);
        }
      }));
  final seqSmallMb = mbps(ds.smallBytes, seqSmall);
  out['small.sequential'] = seqSmallMb.round();
  stdout.writeln('2000 x 512 KiB sequenziale: ${seqSmallMb.toStringAsFixed(0)} MB/s '
      '(${(seqSmall.inMicroseconds / 1000).toStringAsFixed(0)} ms)');

  final largeBytes = ds.large.length * File(ds.large.first).lengthSync();
  final seqLarge = median(3, () => time(() {
        for (final p in ds.large) {
          sha256FileSync(p);
        }
      }));
  final seqLargeMb = mbps(largeBytes, seqLarge);
  out['large.sequential'] = seqLargeMb.round();
  stdout.writeln('8 x 256 MiB sequenziale: ${seqLargeMb.toStringAsFixed(0)} MB/s');

  for (final n in sizes) {
    final pool = HashPool.spawn(n);
    await pool.ready;
    await Future.wait(ds.small.take(64).map(pool.file)); // riscaldamento
    final ds1 = await medianAsync(3, () => timeAsync(() => Future.wait(ds.small.map(pool.file))));
    final dl = await medianAsync(3, () => timeAsync(() => Future.wait(ds.large.map(pool.file))));
    // Chunk di un file grande come range da 512 KiB, 16 range per job.
    final len = File(ds.large.first).lengthSync();
    final ranges = <Int64List>[];
    for (var off = 0; off < len; off += 16 * 512 * 1024) {
      final r = <int>[];
      for (var o = off; o < math.min(len, off + 16 * 512 * 1024); o += 512 * 1024) {
        r..add(o)..add(math.min(512 * 1024, len - o));
      }
      ranges.add(Int64List.fromList(r));
    }
    final dc = await medianAsync(3,
        () => timeAsync(() => Future.wait(ranges.map((r) => pool.ranges(ds.large.first, r)))));
    final s = mbps(ds.smallBytes, ds1), l = mbps(largeBytes, dl), c = mbps(len, dc);
    out['small.pool$n'] = s.round();
    out['large.pool$n'] = l.round();
    out['chunks.pool$n'] = c.round();
    stdout.writeln('pool $n'.padRight(8) +
        ' small ${s.toStringAsFixed(0)} MB/s (x${(s / seqSmallMb).toStringAsFixed(2)})'
            '  large ${l.toStringAsFixed(0)} MB/s (x${(l / seqLargeMb).toStringAsFixed(2)})'
            '  chunk 512K ${c.toStringAsFixed(0)} MB/s');
    await pool.close();
  }

  // Verifica i chunk contro l'hash diretto dei range.
  final pool = HashPool.spawn(2);
  final r = Int64List.fromList([0, 512 * 1024, 300000, 700001, 5 * _mib, 2 * _mib]);
  final got = await pool.ranges(ds.large.first, r);
  var ok = true;
  for (var i = 0; i < 3; i++) {
    if (hex(got[i]) != hex(sha256FileSync(ds.large.first, offset: r[2 * i], length: r[2 * i + 1]))) {
      ok = false;
    }
  }
  final bytes = prng(9 * _mib, 5);
  ok &= hex(await pool.bytes(bytes)) == hex(sha256BytesSync(bytes));
  await pool.close();
  check(ok, 'hash dei range e dei byte via pool coincidono con quelli diretti');
  results['pool'] = out;
}

void criteria() {
  final st = results['singleThread'] as Map<String, Object>;
  final pool = results['pool'] as Map<String, Object>;
  final ncpu = Platform.numberOfProcessors;
  final nat = backendByName('native');
  if (nat == null) {
    check(false, 'backend nativo disponibile');
    return;
  }
  final heap = st['${nat.name}.heap'] as int;
  check(heap >= 1000, 'nativo single-thread >= 1000 MB/s (misurati $heap)');
  final seq = pool['small.sequential'] as int;
  final best = [for (final k in pool.keys) if (k.startsWith('small.pool')) pool[k] as int].reduce(math.max);
  check(best >= 2 * seq || ncpu < 2,
      'pool su file piccoli >= 2x single-thread (best $best vs $seq MB/s)');
}
