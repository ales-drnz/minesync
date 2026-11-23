import 'package:ms_minecraft/ms_minecraft.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  // Layout dei server pack che si incontrano davvero: da ognuno MineSync
  // deve sapere come partire e quale Minecraft (quindi quale Java) serve.
  group('B-SESSION-22 layout reali', () {
    test('Forge 1.20.1: run.sh + unix_args.txt, mai avviato', () {
      final dir = mk(
        tempDir(),
        {
          'run.sh':
              '#!/usr/bin/env bash\njava @user_jvm_args.txt '
              '@libraries/net/minecraftforge/forge/1.20.1-47.3.0/unix_args.txt "\$@"\n',
          'run.bat': 'java @user_jvm_args.txt @libraries/...\r\n',
          'user_jvm_args.txt': '-Xmx6G\n',
          'libraries/net/minecraftforge/forge/1.20.1-47.3.0/unix_args.txt': '-cp\nlibraries/...\n',
          'server.properties': 'server-port=25565\n',
        },
        executable: {'run.sh'},
      );
      final l = detectServer(dir, os: HostOs.linux);
      expect(l.launch, isA<ScriptLaunch>().having((s) => p.basename(s.path), 'script', 'run.sh'));
      expect(l.label, 'run.sh');
      expect(l.loader, 'forge');
      expect(l.mcVersion, '1.20.1');
      expect(l.requiredJavaMajor, 17);
      expect(l.empty, isFalse);
    });

    test('NeoForge 21.1.x → 1.21.1', () {
      final dir = mk(tempDir(), {
        'run.sh':
            '#!/usr/bin/env bash\njava @user_jvm_args.txt '
            '@libraries/net/neoforged/neoforge/21.1.79/unix_args.txt "\$@"\n',
        'libraries/net/neoforged/neoforge/21.1.79/unix_args.txt': '-cp\n...\n',
        'server.properties': 'server-port=25565\n',
      });
      final l = detectServer(dir, os: HostOs.linux);
      expect(l.launch, isA<ScriptLaunch>());
      expect(l.loader, 'neoforge');
      expect(l.mcVersion, '1.21.1');
      expect(l.requiredJavaMajor, 21);
    });

    test('Fabric senza script: solo il launcher jar', () {
      final dir = mk(tempDir(), {
        'fabric-server-launch.jar': 'PK',
        'fabric-server-launcher.properties': 'serverJar=server.jar\n',
        'server.properties': 'server-port=25565\n',
      });
      final l = detectServer(dir, os: HostOs.linux);
      expect(
        l.launch,
        isA<JarLaunch>().having((j) => p.basename(j.jarPath), 'jar', 'fabric-server-launch.jar'),
      );
      expect(l.label, 'fabric-server-launch.jar');
      expect(l.loader, 'fabric');
    });

    test('Fabric già avviato: versione dalle librerie intermediary', () {
      final dir = mk(tempDir(), {
        'fabric-server-launch.jar': 'PK',
        'libraries/net/fabricmc/intermediary/1.21.1/intermediary-1.21.1.jar': 'PK',
        'libraries/net/fabricmc/fabric-loader/0.16.9/fabric-loader-0.16.9.jar': 'PK',
        'libraries/net/fabricmc/fabric-loader/0.19.5/fabric-loader-0.19.5.jar': 'PK',
        'server.properties': 'server-port=25565\n',
      });
      final l = detectServer(dir, os: HostOs.linux);
      expect(l.launch, isA<JarLaunch>());
      expect(l.mcVersion, '1.21.1');
      // versione del loader dalla libreria più recente
      expect(l.loaderVersion, '0.19.5');
    });

    test('Forge 1.12.2 vecchio stile: ServerStart.sh', () {
      final dir = mk(tempDir(), {
        'ServerStart.sh': '#!/bin/bash\njava -jar forge-1.12.2-14.23.5.2860.jar nogui\n',
        'ServerStart.bat': 'java -jar forge...\r\n',
        'settings.sh': 'MAX_RAM="6G"\n',
        'forge-1.12.2-14.23.5.2860.jar': 'PK',
        'minecraft_server.1.12.2.jar': 'PK',
        'server.properties': 'server-port=25565\n',
      });
      final l = detectServer(dir, os: HostOs.linux);
      expect(l.launch, isA<ScriptLaunch>());
      expect(l.label, 'ServerStart.sh');
      expect(l.loader, 'forge');
      expect(l.loaderVersion, '14.23.5.2860');
      expect(l.mcVersion, '1.12.2');
      expect(l.requiredJavaMajor, 8);
    });

    test('vanilla/Paper: solo server.jar', () {
      final dir = mk(tempDir(), {'server.jar': 'PK', 'server.properties': 'server-port=25565\n'});
      final l = detectServer(dir, os: HostOs.linux);
      expect(l.launch, isA<JarLaunch>().having((j) => p.basename(j.jarPath), 'jar', 'server.jar'));
      expect(l.loader, 'vanilla');
    });

    test('Paper: versione dal nome del jar', () {
      final dir = mk(tempDir(), {'paper-1.20.4-497.jar': 'PK', 'eula.txt': 'eula=true\n'});
      final l = detectServer(dir, os: HostOs.linux);
      expect(l.launch, isA<JarLaunch>());
      expect(l.mcVersion, '1.20.4');
    });

    test('server.jar con version.json: versione e Java dichiarati da Mojang', () {
      for (final deflate in [true, false]) {
        final dir = mk(tempDir(), {
          'server.jar': zipBytes({
            'META-INF/MANIFEST.MF': 'Manifest-Version: 1.0\n',
            'version.json': '{"id": "1.20.6", "name": "1.20.6", "java_version": 21}',
          }, deflate: deflate),
          'server.properties': '',
        });
        final l = detectServer(dir, os: HostOs.linux);
        expect(l.mcVersion, '1.20.6');
        expect(l.declaredJava, 21);
        expect(l.requiredJavaMajor, 21);
      }
    });

    test('pack preparato su Windows (solo start.bat) su host Linux', () {
      final dir = mk(tempDir(), {
        'start.bat': 'java -Xmx8G -jar server.jar nogui\r\npause\r\n',
        'server.jar': 'PK',
        'server.properties': 'server-port=25565\n',
      });
      final l = detectServer(dir, os: HostOs.linux);
      expect(l.scripts, isEmpty);
      expect(l.launch, isA<JarLaunch>());
      // su Windows invece vale lo script
      final w = detectServer(dir, os: HostOs.windows);
      expect(w.launch, isA<ScriptLaunch>().having((s) => s.kind, 'kind', ScriptKind.batch));
      expect(w.label, 'start.bat');
    });

    test('Forge moderno senza script per questo sistema: file di argomenti', () {
      final dir = mk(tempDir(), {
        'run.bat': 'java @user_jvm_args.txt @libraries/.../win_args.txt %*\r\n',
        'user_jvm_args.txt': '# -Xmx4G\n',
        'libraries/net/minecraftforge/forge/1.20.1-47.3.0/unix_args.txt': '-cp\n...\n',
        'libraries/net/minecraftforge/forge/1.20.1-47.3.0/win_args.txt': '-cp\n...\n',
        'server.properties': '',
      });
      final l = detectServer(dir, os: HostOs.linux);
      expect(
        l.launch,
        isA<ArgsFileLaunch>()
            .having(
              (a) => a.argsFile,
              'argsFile',
              'libraries/net/minecraftforge/forge/1.20.1-47.3.0/unix_args.txt',
            )
            .having((a) => a.jvmArgsFile, 'jvmArgsFile', 'user_jvm_args.txt'),
      );
      expect(l.label, 'unix_args.txt');
      final mac = detectServer(dir, os: HostOs.macos);
      expect(mac.launch, isA<ArgsFileLaunch>());
    });

    test('più script candidati: run.sh prima di un start.sh di servizio', () {
      final dir = mk(tempDir(), {
        'run.sh': '#!/bin/sh\njava @user_jvm_args.txt\n',
        'start.sh': "#!/bin/sh\necho script sbagliato: e' un helper\n",
        'server.properties': 'server-port=25565\n',
      });
      final l = detectServer(dir, os: HostOs.linux);
      expect(l.label, 'run.sh');
      expect(l.scripts.map(p.basename), ['run.sh', 'start.sh']);
    });

    test('a parità vince lo script che imposta -Xmx', () {
      final dir = mk(tempDir(), {
        'run.sh': '#!/bin/sh\njava @user_jvm_args.txt\n',
        'start.sh': '#!/bin/sh\njava -Xmx10G -jar server.jar nogui\n',
        'server.jar': 'PK',
      });
      final l = detectServer(dir, os: HostOs.linux);
      expect(l.label, 'start.sh');
      expect((l.launch! as ScriptLaunch).setsHeap, isTrue);
    });

    test('pack aggiornato sul posto: vince la versione più alta, non la prima', () {
      final dir = mk(tempDir(), {
        'libraries/net/minecraftforge/forge/1.20.1-47.3.0/': '',
        'libraries/net/minecraftforge/forge/1.9.4-12.17.0/': '',
        'server.properties': '',
      });
      expect(detectServer(dir).mcVersion, '1.20.1');
    });

    test('versione dal manifest del pack, prima del primo avvio', () {
      final cf = mk(tempDir(), {
        'manifest.json': '{"minecraft": {"version": "1.19.2"}}',
        'start.sh': '#!/bin/sh\n',
      });
      expect(detectServer(cf, os: HostOs.linux).mcVersion, '1.19.2');
      final mr = mk(tempDir(), {
        'modrinth.index.json': '{"dependencies": {"minecraft": "1.20.1", "fabric-loader": "0.15"}}',
        'start.sh': '#!/bin/sh\n',
      });
      expect(detectServer(mr, os: HostOs.linux).mcVersion, '1.20.1');
    });
  });

  test('B-SESSION-23 pack avvolto in una sola sottocartella', () {
    final root = mk(tempDir(), {
      'Modpack-Server/run.sh': '#!/bin/sh\njava @user_jvm_args.txt\n',
      'Modpack-Server/server.properties': 'server-port=25565\n',
    });
    final l = detectServer(root, os: HostOs.linux);
    expect(l.launch, isNotNull);
    expect(p.basename(l.workDir), 'Modpack-Server');
    expect(buildLaunch(l, os: HostOs.linux).workDir, l.workDir);

    // due sottocartelle: ambiguo, non si indovina
    mk(root, {'Altro/server.properties': ''});
    expect(detectServer(root, os: HostOs.linux).workDir, p.normalize(root));
  });

  group('B-SESSION-24 cartella vuota', () {
    test('vuota: empty e etichetta ?', () {
      final dir = tempDir();
      final l = detectServer(dir, os: HostOs.linux);
      expect(l.empty, isTrue);
      expect(l.label, '?');
      expect(l.launch, isNull);
    });

    test('lo stato di MineSync non conta come contenuto', () {
      final dir = mk(tempDir(), {'.minesync/state.json': '{}'});
      expect(detectServer(dir, os: HostOs.linux).empty, isTrue);
    });

    test('inesistente: vuota', () {
      expect(detectServer(p.join(tempDir(), 'non-esiste'), os: HostOs.linux).empty, isTrue);
    });

    test('con start.sh: etichetta dello script', () {
      final dir = mk(tempDir(), {'start.sh': '#!/bin/sh\n'}, executable: {'start.sh'});
      final l = detectServer(dir, os: HostOs.linux);
      expect(l.empty, isFalse);
      expect(l.label, 'start.sh');
    });

    test('file senza modo di partire: non vuota, etichetta ?', () {
      final dir = mk(tempDir(), {'server.properties': ''});
      final l = detectServer(dir, os: HostOs.linux);
      expect(l.empty, isFalse);
      expect(l.launch, isNull);
      expect(l.label, '?');
      expect(() => buildLaunch(l), throwsA(isA<NoLaunchTarget>()));
    });
  });

  group('B-SESSION-25 versione di Minecraft dalle librerie', () {
    String lib(String rel) => mk(tempDir(), {'$rel/': ''});

    test('Forge forge/<mc>-<ver>', () {
      expect(
        mcVersionFromLibraries(lib('libraries/net/minecraftforge/forge/1.20.1-47.4.0')),
        '1.20.1',
      );
    });
    test('NeoForge 20.4.x → 1.20.4', () {
      expect(mcVersionFromLibraries(lib('libraries/net/neoforged/neoforge/20.4.190')), '1.20.4');
    });
    test('NeoForge 1.20.1 sotto net/neoforged/forge', () {
      expect(
        mcVersionFromLibraries(lib('libraries/net/neoforged/forge/1.20.1-47.1.106')),
        '1.20.1',
      );
    });
    test('NeoForge 21.0.x → 1.21', () {
      expect(mcVersionFromLibraries(lib('libraries/net/neoforged/neoforge/21.0.167')), '1.21');
    });
    test('Fabric intermediary/<mc>', () {
      expect(mcVersionFromLibraries(lib('libraries/net/fabricmc/intermediary/1.21.1')), '1.21.1');
    });
    test('server vanilla net/minecraft/server', () {
      expect(
        mcVersionFromLibraries(lib('libraries/net/minecraft/server/1.20.1-20230612.114412')),
        '1.20.1',
      );
    });
    test('nessuna libreria: ignota', () {
      expect(mcVersionFromLibraries(tempDir()), isNull);
    });
  });

  test('B-SESSION-26 Java richiesto per versione di Minecraft', () {
    const cases = {
      '1.7.10': 8,
      '1.12.2': 8,
      '1.16.5': 8,
      // Mojang per la 1.17 chiedeva Java 16, ma è fuori supporto e non ce
      // l'ha quasi nessuno: il 17 la esegue senza problemi
      '1.17': 17,
      '1.17.1': 17,
      '1.18.2': 17,
      '1.19.4': 17,
      '1.20': 17,
      '1.20.1': 17,
      '1.20.4': 17,
      '1.20.5': 21,
      '1.20.6': 21,
      '1.21': 21,
      '1.21.4': 21,
      // numerazione per anno: dalla 26.1 serve Java 25 (minecraft.wiki)
      '26.1': 25,
      '26.2.1': 25,
      '': 0,
      'garbage': 0,
      '2.0': 0,
    };
    for (final MapEntry(key: v, value: want) in cases.entries) {
      expect(requiredJava(v), want, reason: v);
    }
    expect(requiredJava(null), 0);
  });

  group('comando di avvio', () {
    const java = JavaRuntime(
      path: '/opt/jdk-17/bin/java',
      major: 17,
      version: '17.0.9',
      verified: true,
    );

    test('script eseguibile: lanciato direttamente, Java imposto dall\'ambiente', () {
      final dir = mk(
        tempDir(),
        {'run.sh': '#!/usr/bin/env bash\njava @user_jvm_args.txt "\$@"\n'},
        executable: {'run.sh'},
      );
      final l = detectServer(dir, os: HostOs.linux);
      final c = buildLaunch(
        l,
        java: java,
        xmxMiB: 4096,
        os: HostOs.linux,
        baseEnv: {'PATH': '/usr/bin'},
      );
      expect(c.executable, p.join(dir, 'run.sh'));
      expect(c.args, isEmpty);
      expect(c.workDir, dir);
      expect(c.env['JAVA_HOME'], '/opt/jdk-17');
      expect(c.env['JAVA'], '/opt/jdk-17/bin/java');
      expect(c.env['PATH'], '/opt/jdk-17/bin:/usr/bin');
    }, testOn: '!windows');

    test('script non eseguibile: sh, oppure bash se usa sintassi bash', () {
      final dir = mk(tempDir(), {
        'start.sh': '#!/bin/sh\njava -jar server.jar\n',
        'other/run.sh': '#!/usr/bin/env bash\nif [[ -f x ]]; then java; fi\n',
      });
      final plain = buildLaunch(detectServer(dir, os: HostOs.linux), os: HostOs.linux);
      expect(plain.executable, 'sh');
      expect(plain.args, ['start.sh']);
      expect(plain.env, isEmpty);
      final bashy = buildLaunch(
        detectServer(p.join(dir, 'other'), os: HostOs.linux),
        os: HostOs.linux,
      );
      expect(bashy.executable, 'bash');
      expect(bashy.args, ['run.sh']);
    });

    test('script con fine riga Windows: interprete esplicito e segnalato', () {
      final dir = mk(
        tempDir(),
        {'run.sh': '#!/bin/sh\r\njava -jar server.jar\r\n'},
        executable: {'run.sh'},
      );
      final l = detectServer(dir, os: HostOs.linux);
      expect((l.launch! as ScriptLaunch).crlf, isTrue);
      expect(buildLaunch(l, os: HostOs.linux).executable, 'sh');
    });

    test('.bat su Windows: cmd /c, Path con la chiave originale', () {
      final dir = mk(tempDir(), {'start.bat': '@echo off\r\njava -jar server.jar nogui\r\n'});
      final l = detectServer(dir, os: HostOs.windows);
      const winJava = JavaRuntime(
        path: r'C:\Program Files\Eclipse Adoptium\jdk-21\bin\java.exe',
        major: 21,
        version: '21.0.1',
        verified: true,
      );
      final c = buildLaunch(l, java: winJava, os: HostOs.windows, baseEnv: {'Path': r'C:\Windows'});
      expect(c.executable, 'cmd.exe');
      expect(c.args, ['/c', 'call', 'start.bat']);
      expect(c.env.containsKey('PATH'), isFalse);
      expect(c.env['JAVA_HOME'], r'C:\Program Files\Eclipse Adoptium\jdk-21');
      expect(c.env['Path'], endsWith(r';C:\Windows'));
    });

    test('.ps1 su Windows: powershell -File', () {
      final dir = mk(tempDir(), {'start.ps1': 'java -jar server.jar\r\n'});
      final c = buildLaunch(detectServer(dir, os: HostOs.windows), os: HostOs.windows);
      expect(c.executable, 'powershell.exe');
      expect(c.args, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'start.ps1']);
    });

    test('jar: java -Xmx.. -jar .. nogui con il runtime scelto', () {
      final dir = mk(tempDir(), {'server.jar': 'PK'});
      final l = detectServer(dir, os: HostOs.linux);
      final c = buildLaunch(l, java: java, xmxMiB: 6144, os: HostOs.linux, baseEnv: const {});
      expect(c.executable, '/opt/jdk-17/bin/java');
      expect(c.args, ['-Xmx6144M', '-jar', 'server.jar', 'nogui']);
      expect(c.env['PATH'], '/opt/jdk-17/bin');
      final noJava = buildLaunch(l, os: HostOs.linux);
      expect(noJava.executable, 'java');
      expect(noJava.args, ['-jar', 'server.jar', 'nogui']);
    });

    test('file di argomenti: -Xmx dopo user_jvm_args.txt', () {
      final dir = mk(tempDir(), {
        'user_jvm_args.txt': '-Xmx2G\n',
        'libraries/net/neoforged/neoforge/21.1.79/unix_args.txt': '-cp\n...\n',
      });
      final c = buildLaunch(detectServer(dir, os: HostOs.linux), xmxMiB: 8192, os: HostOs.linux);
      expect(c.args, [
        '@user_jvm_args.txt',
        '-Xmx8192M',
        '@libraries/net/neoforged/neoforge/21.1.79/unix_args.txt',
        'nogui',
      ]);
    });

    test('script che scrive a mano il percorso di java: rispettato e segnalato', () {
      final cases = {
        '#!/bin/sh\n/usr/lib/jvm/java-17-openjdk/bin/java -Xmx4G -jar server.jar nogui\n':
            '/usr/lib/jvm/java-17-openjdk/bin/java',
        '#!/bin/sh\n"./jre/bin/java" -jar server.jar\n': './jre/bin/java',
        '#!/bin/sh\n"\$JAVA_HOME/bin/java" -jar server.jar\n': null,
        '#!/bin/sh\n# /old/jdk/bin/java -jar server.jar\njava -jar server.jar\n': null,
        '#!/bin/sh\njava -jar server.jar\n': null,
      };
      for (final MapEntry(key: script, value: want) in cases.entries) {
        final dir = mk(tempDir(), {'start.sh': script});
        final l = detectServer(dir, os: HostOs.linux);
        expect((l.launch! as ScriptLaunch).hardcodedJava, want, reason: script);
        // il comando resta lo script: non si riscrive
        expect(buildLaunch(l, java: java, os: HostOs.linux).args, ['start.sh']);
      }
      final bat = mk(tempDir(), {
        'start.bat': '"C:\\Program Files\\Java\\jdk-17\\bin\\java.exe" -jar server.jar\r\n',
      });
      expect(
        (detectServer(bat, os: HostOs.windows).launch! as ScriptLaunch).hardcodedJava,
        r'C:\Program Files\Java\jdk-17\bin\java.exe',
      );
    });
  });
}
