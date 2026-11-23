import 'dart:io';

import 'package:ms_minecraft/ms_minecraft.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  group('server.properties', () {
    test('chiavi sconosciute, commenti, escape e separatori', () {
      final dir = mk(tempDir(), {
        'server.properties':
            '\uFEFF#Minecraft server properties\n'
            '! commento alla vecchia\n'
            'server-port=25570\n'
            'motd=A Minecraft Server \\u00E8 qui\\n\n'
            'level-name = world\n'
            'some-mod-key: valore\n'
            'spazio valore con spazi\n'
            'lunga=uno \\\n'
            '    due\n'
            'percorso=C\\:\\\\mondi\n'
            'vuota=\n'
            'server-ip=192.0.2.10\n',
      });
      final props = readServerProperties(dir);
      expect(props['server-port'], '25570');
      expect(props['motd'], 'A Minecraft Server è qui\n');
      expect(props['level-name'], 'world');
      expect(props['some-mod-key'], 'valore');
      expect(props['spazio'], 'valore con spazi');
      expect(props['lunga'], 'uno due');
      expect(props['percorso'], r'C:\mondi');
      expect(props['vuota'], '');
      expect(props['server-ip'], '192.0.2.10');
      expect(props.containsKey('#Minecraft'), isFalse);
      expect(serverPort(props), 25570);
    });

    test('fine riga Windows', () {
      expect(parseProperties('a=1\r\nb=2\r\n'), {'a': '1', 'b': '2'});
    });

    test('file mancante: mappa vuota, porta di default', () {
      final props = readServerProperties(tempDir());
      expect(props, isEmpty);
      expect(serverPort(props), 25565);
    });

    test('porta non valida', () {
      expect(serverPort({'server-port': ''}), 25565);
      expect(serverPort({'server-port': ' 25566 '}), 25566);
      expect(serverPort({'server-port': 'abc'}), isNull);
      expect(serverPort({'server-port': '70000'}), isNull);
      expect(serverPort({'server-port': '0'}), isNull);
    });
  });

  group('eula.txt', () {
    test('accettata solo con eula=true', () {
      final dir = tempDir();
      expect(isEulaAccepted(dir), isFalse);
      mk(dir, {'eula.txt': '#commento\neula=false\n'});
      expect(isEulaAccepted(dir), isFalse);
      mk(dir, {'eula.txt': '#commento\neula=TRUE\n'});
      expect(isEulaAccepted(dir), isTrue);
    });

    test('acceptEula conserva le altre righe', () async {
      final dir = mk(tempDir(), {
        'eula.txt':
            '#By changing the setting below to TRUE you are indicating your agreement to our EULA.\r\n'
            '#Tue Jan 01 12:00:00 CET 2030\r\n'
            'eula=false\r\n'
            'altro=1\r\n',
      });
      await acceptEula(dir);
      final text = File(p.join(dir, 'eula.txt')).readAsStringSync();
      expect(
        text,
        '#By changing the setting below to TRUE you are indicating your agreement to our EULA.\r\n'
        '#Tue Jan 01 12:00:00 CET 2030\r\n'
        'eula=true\r\n'
        'altro=1\r\n',
      );
      expect(isEulaAccepted(dir), isTrue);
      // nessun temporaneo lasciato in giro
      expect(Directory(dir).listSync().map((e) => p.basename(e.path)), ['eula.txt']);
    });

    test('acceptEula crea il file se manca', () async {
      final dir = tempDir();
      await acceptEula(dir);
      expect(isEulaAccepted(dir), isTrue);
      final lines = File(p.join(dir, 'eula.txt')).readAsLinesSync();
      expect(lines.last, 'eula=true');
      expect(lines.first, startsWith('#'));
    });

    test('acceptEula senza riga eula la aggiunge', () async {
      final dir = mk(tempDir(), {'eula.txt': '#solo un commento\n'});
      await acceptEula(dir);
      expect(File(p.join(dir, 'eula.txt')).readAsStringSync(), '#solo un commento\neula=true\n');
    });
  });
}
