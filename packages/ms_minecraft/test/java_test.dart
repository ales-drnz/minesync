import 'dart:io';

import 'package:ms_minecraft/ms_minecraft.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// Java finto: uno script sh che stampa il banner di `-version` su stderr e,
/// se [marker] è dato, lascia una traccia quando viene eseguito.
String fakeJava(
  String path, {
  String version = '17.0.9',
  String vm = 'OpenJDK 64-Bit Server VM',
  String? marker,
  String extra = '',
}) {
  File(path).parent.createSync(recursive: true);
  File(path).writeAsStringSync(
    '#!/bin/sh\n'
    '${marker == null ? '' : 'touch "$marker"\n'}'
    '$extra'
    'echo \'openjdk version "$version" 2023-10-17\' >&2\n'
    'echo \'$vm (build $version, mixed mode)\' >&2\n',
  );
  Process.runSync('chmod', ['755', path]);
  return path;
}

String get _exe => Platform.isWindows ? 'java.exe' : 'java';

void main() {
  test('B-SESSION-27 major dalla stringa di versione Java', () {
    const cases = {
      '1.8.0_501': 8,
      '17.0.9': 17,
      '21': 21,
      '21.0.1+12': 21,
      '11.0.20.1': 11,
      '24-ea': 24, // early access: in passato veniva scartato
      '25-ea+3': 25,
      '1.8.0-ea': 8,
      '17-internal': 17,
      '': 0,
      'garbage': 0,
    };
    for (final MapEntry(key: v, value: want) in cases.entries) {
      expect(javaMajor(v), want, reason: v);
    }
  });

  group('B-SESSION-28 un java dentro la cartella del server non si esegue', () {
    // Vale su ogni sistema: il runtime del pack risulta trovato ma non
    // verificato, con la versione letta dal file `release`.
    test('runtime incluso nel pack: trovato, non verificato, versione da release', () async {
      final server = mk(tempDir(), {
        'jre/bin/$_exe': 'non un vero eseguibile',
        'jre/release': 'IMPLEMENTOR="Eclipse Adoptium"\nJAVA_VERSION="17.0.2"\n',
        'jdk-21/bin/$_exe': 'nemmeno questo',
        'server.properties': '',
      });
      _chmodX([p.join(server, 'jre', 'bin', _exe), p.join(server, 'jdk-21', 'bin', _exe)]);
      final found = await findJavaRuntimes(
        serverRoot: server,
        env: const {'PATH': ''},
        includeInstallDirs: false,
      );
      expect(found, hasLength(2));
      final jre = found.firstWhere((j) => j.path == p.join(server, 'jre', 'bin', _exe));
      expect(jre.insideServer, isTrue);
      expect(jre.verified, isFalse);
      expect(jre.version, '17.0.2');
      expect(jre.major, 17);
      final jdk = found.firstWhere((j) => j.path == p.join(server, 'jdk-21', 'bin', _exe));
      expect(jdk.verified, isFalse);
      expect(jdk.major, 0, reason: 'senza release la versione resta ignota');
    });

    test('runtime del pack senza permesso di esecuzione: non proposto (POSIX)', () async {
      // capita con i pack copiati da Windows o estratti da uno zip
      final server = mk(tempDir(), {
        'runtime-linux/bin/java': 'non eseguibile',
        'runtime-linux/release': 'JAVA_VERSION="21.0.5"\n',
      });
      final found = await findJavaRuntimes(
        serverRoot: server,
        env: const {'PATH': ''},
        includeInstallDirs: false,
      );
      expect(found, isEmpty);
      _chmodX([p.join(server, 'runtime-linux', 'bin', 'java')]);
      final again = await findJavaRuntimes(
        serverRoot: server,
        env: const {'PATH': ''},
        includeInstallDirs: false,
      );
      expect(again.single.major, 21);
    }, skip: Platform.isWindows ? 'su Windows non esiste il bit di esecuzione' : false);

    test('né incluso nel pack né dal PATH né da JAVA_HOME', () async {
      final marker = p.join(tempDir(), 'eseguito');
      final server = tempDir();
      fakeJava(p.join(server, 'jre', 'bin', 'java'), marker: marker);
      // scelto a mano dentro la cartella: arriva tramite PATH e JAVA_HOME
      fakeJava(p.join(server, 'tools', 'bin', 'java'), marker: marker);
      fakeJava(p.join(server, 'home', 'bin', 'java'), marker: marker);
      // e uno fuori, che invece va verificato
      final outside = fakeJava(p.join(tempDir(), 'jdk', 'bin', 'java'), version: '21.0.1');
      final found = await findJavaRuntimes(
        serverRoot: server,
        env: {
          'PATH': '${p.join(server, 'tools', 'bin')}:${p.dirname(outside)}',
          'JAVA_HOME': p.join(server, 'home'),
        },
        includeInstallDirs: false,
      );
      expect(File(marker).existsSync(), isFalse, reason: 'un java della cartella è stato eseguito');
      final inside = found.where((j) => j.insideServer).toList();
      expect(inside.map((j) => j.path).toSet(), {
        p.join(server, 'jre', 'bin', 'java'),
        p.join(server, 'tools', 'bin', 'java'),
        p.join(server, 'home', 'bin', 'java'),
      });
      expect(inside.every((j) => !j.verified), isTrue);
      final verified = found.singleWhere((j) => !j.insideServer);
      expect(verified.path, outside);
      expect(verified.verified, isTrue);
      expect(verified.major, 21);
      // prima quelli del pack
      expect(found.first.insideServer, isTrue);
    }, testOn: '!windows');

    test('un symlink fuori che punta dentro la cartella non si esegue', () async {
      final marker = p.join(tempDir(), 'eseguito');
      final server = tempDir();
      final real = fakeJava(p.join(server, 'runtime', 'bin', 'java'), marker: marker);
      final binDir = Directory(p.join(tempDir(), 'bin'))..createSync();
      Link(p.join(binDir.path, 'java')).createSync(real);
      final found = await findJavaRuntimes(
        serverRoot: server,
        env: {'PATH': binDir.path},
        includeInstallDirs: false,
      );
      expect(File(marker).existsSync(), isFalse);
      expect(found, hasLength(1), reason: 'stesso runtime, deduplicato sul percorso reale');
      expect(found.single.verified, isFalse);
    }, testOn: '!windows');
  });

  group('ricerca dei runtime fuori dalla cartella', () {
    test('JAVA_HOME e PATH, ordinati per major, deduplicati', () async {
      final a = fakeJava(p.join(tempDir(), 'jdk17', 'bin', 'java'));
      final b = fakeJava(p.join(tempDir(), 'jdk21', 'bin', 'java'), version: '21.0.1');
      final c = fakeJava(p.join(tempDir(), 'jdk8', 'bin', 'java'), version: '1.8.0_392');
      // stessa versione di a in un'altra cartella: un doppione
      final dup = fakeJava(p.join(tempDir(), 'copia', 'bin', 'java'));
      final found = await findJavaRuntimes(
        env: {
          'JAVA_HOME': p.dirname(p.dirname(a)),
          'PATH': [p.dirname(c), p.dirname(b), p.dirname(dup), p.dirname(a)].join(':'),
        },
        includeInstallDirs: false,
      );
      expect(found.map((j) => j.path), [b, a, c]);
      expect(found.map((j) => j.major), [21, 17, 8]);
      expect(found.every((j) => j.verified && !j.insideServer && j.bits == 64), isTrue);
    }, testOn: '!windows');

    test('runtime rotti, muti o lenti vengono scartati', () async {
      final broken = p.join(tempDir(), 'broken', 'bin', 'java');
      File(broken)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\necho boom >&2\nexit 1\n');
      Process.runSync('chmod', ['755', broken]);
      final mute = p.join(tempDir(), 'mute', 'bin', 'java');
      File(mute)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\necho ciao\n');
      Process.runSync('chmod', ['755', mute]);
      final slow = fakeJava(p.join(tempDir(), 'slow', 'bin', 'java'), extra: 'sleep 20\n');
      final notExec = p.join(tempDir(), 'noexec', 'bin', 'java');
      File(notExec)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('niente');
      final good = fakeJava(p.join(tempDir(), 'good', 'bin', 'java'));
      final sw = Stopwatch()..start();
      final found = await findJavaRuntimes(
        env: {
          'PATH': [broken, mute, slow, notExec, good].map(p.dirname).join(':'),
        },
        includeInstallDirs: false,
        timeout: const Duration(milliseconds: 800),
      );
      expect(found.map((j) => j.path), [good]);
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    }, testOn: '!windows');

    test('cartelle d\'installazione tipiche sotto la home', () async {
      final home = tempDir();
      final jdk = fakeJava(
        p.join(home, '.jdks', 'temurin-21.0.1', 'bin', 'java'),
        version: '21.0.1',
      );
      final found = await findJavaRuntimes(env: {'HOME': home, 'PATH': ''});
      expect(found.map((j) => j.path), contains(jdk));
    }, testOn: 'linux || mac-os');

    test('probeJava riconosce una JVM a 32 bit', () async {
      final j32 = fakeJava(
        p.join(tempDir(), 'j32', 'bin', 'java'),
        version: '1.8.0_392',
        vm: 'Java HotSpot(TM) Client VM',
      );
      final r = await probeJava(j32);
      expect(r, isNotNull);
      expect(r!.major, 8);
      expect(r.bits, 32);
      expect(r.home, p.join(p.dirname(p.dirname(j32))));
      expect(await probeJava(p.join(tempDir(), 'manca')), isNull);
    }, testOn: '!windows');
  });

  group('B-SESSION-29 scelta del runtime', () {
    const j17 = JavaRuntime(path: '/x/java17', major: 17, version: '17.0.9', verified: true);
    const j21 = JavaRuntime(path: '/x/java21', major: 21, version: '21', verified: true);
    const j8 = JavaRuntime(path: '/x/java8', major: 8, version: '1.8.0_392', verified: true);

    test('il major richiesto anche se un altro viene prima', () {
      expect(pickJava([j21, j17], requiredJava('1.20.1')), same(j17));
    });

    test('meglio uno più nuovo di uno più vecchio', () {
      expect(pickJava([j8, j21], 17), same(j21));
      expect(pickJava([j8], 17), same(j8), reason: "l'ultima risorsa: il chiamante avvisa");
    });

    test('32 bit penalizzato, a pari merito vince il runtime del pack', () {
      const j17x32 = JavaRuntime(
        path: '/x/j17-32',
        major: 17,
        version: '17',
        verified: true,
        bits: 32,
      );
      expect(pickJava([j17x32, j21], 17), same(j21));
      const bundled = JavaRuntime(
        path: '/s/jre/bin/java',
        major: 17,
        version: '17.0.2',
        insideServer: true,
      );
      expect(pickJava([j17, bundled], 17), same(bundled));
    });

    test('versione ignota: meglio di uno troppo vecchio, peggio di uno buono', () {
      const unknown = JavaRuntime(
        path: '/s/jdk/bin/java',
        major: 0,
        version: '',
        insideServer: true,
      );
      expect(pickJava([j8, unknown], 17), same(unknown));
      expect(pickJava([unknown, j21], 17), same(j21));
    });

    test('Minecraft ignoto: il runtime del pack, altrimenti il più recente', () {
      const bundled = JavaRuntime(
        path: '/s/jre/bin/java',
        major: 0,
        version: '',
        insideServer: true,
      );
      expect(pickJava([j8, j21, bundled], 0), same(bundled));
      expect(pickJava([j8, j17, j21], 0), same(j21));
    });

    test('lista vuota: null', () {
      expect(pickJava(const [], 17), isNull);
    });

    test('contenimento su percorsi normalizzati', () {
      final dir = tempDir();
      final cases = {
        p.join(dir, 'jre', 'bin', 'java'): true,
        dir: true,
        p.join(dir, 'jre', '..', 'jre'): true,
        p.join(dir, '..', 'altro'): false,
        p.join('${dir}x', 'java'): false,
        '': false,
      };
      for (final MapEntry(key: path, value: want) in cases.entries) {
        expect(isInside(path, dir), want, reason: path);
      }
      expect(isInside(dir, ''), isFalse);
    });
  });
}

/// Rende eseguibili [paths] (POSIX; su Windows non serve).
void _chmodX(List<String> paths) {
  if (Platform.isWindows) return;
  // sotto carico l'avvio di chmod può fallire senza messaggio: si riprova
  ProcessResult? r;
  for (var i = 0; i < 3; i++) {
    r = Process.runSync('chmod', ['+x', ...paths]);
    if (r.exitCode == 0) return;
  }
  throw StateError('chmod (uscita ${r!.exitCode}): ${r.stderr}');
}
