import 'dart:convert';

import 'package:ms_minecraft/ms_minecraft.dart';
import 'package:test/test.dart';

void main() {
  // Le righe di sistema vanno riconosciute su tutti i loader; la chat non
  // deve mai poter pilotare la sessione: bastava scrivere "alice left the
  // game" per svuotare la lista giocatori e far scattare l'arresto
  // automatico con il server pieno.
  group('B-SESSION-11 join e leave', () {
    const sistema = {
      '[22:20:14] [Server thread/INFO]: alice joined the game': PlayerJoined('alice'),
      '[22:23:33] [Server thread/INFO]: bob left the game': PlayerLeft('bob'),
      '[12:00:00] [Server thread/INFO] [minecraft/MinecraftServer]: Steve joined the game':
          PlayerJoined('Steve'),
      '[29Jan2024 12:00:00.123] [Server thread/INFO] [net.minecraft.server.MinecraftServer/]: '
          'alice left the game': PlayerLeft(
        'alice',
      ),
      '[Server thread/INFO]: Alex_99 left the game': PlayerLeft('Alex_99'),
      '[22:20:14] [Server thread/INFO]: .BedrockUser joined the game': PlayerJoined('.BedrockUser'),
      '[12:00:00 INFO]: alice joined the game': PlayerJoined('alice'),
      '[12:00:00] [Server thread/INFO]: bob joined the game\r': PlayerJoined('bob'),
      '\x1B[32m[12:00:00 INFO]: alice joined the game\x1B[0m': PlayerJoined('alice'),
    };
    for (final MapEntry(key: line, value: fact) in sistema.entries) {
      test('riconosce ${jsonEncode(line)}', () {
        expect(parseConsoleLine(line), fact);
      });
    }

    const chat = [
      '[22:20:14] [Server thread/INFO]: <bob> alice left the game',
      "[22:20:14] [Server thread/INFO]: <bob> chi e' appena joined the game?",
      '[22:20:14] [Server thread/INFO]: [Not Secure] <bob> alice left the game',
      '[22:20:14] [Server thread/INFO]: <alice> bob joined the game',
      '[22:20:14] [Server thread/INFO]: [bob] alice left the game', // /say
      '[22:20:14] [Server thread/INFO]: * bob alice left the game', // /me
      '[22:20:14] [Server thread/INFO]: bob » alice left the game', // mod di chat
      '[22:20:14] [Server thread/INFO]: bob: alice left the game',
      '[12:00:00 INFO]: [bob] alice left the game', // /say su Paper
      '[12:00:00] [Async Chat Thread - #0/INFO]: alice left the game',
      'alice left the game',
    ];
    for (final line in chat) {
      test('ignora la chat ${jsonEncode(line)}', () {
        expect(parseConsoleLine(line), isNull);
      });
    }
  });

  group('B-SESSION-12 avvio, salvataggio e spegnimento solo da righe di sistema', () {
    test('le righe vere', () {
      expect(
        parseConsoleLine('[12:00:00] [Server thread/INFO]: Done (41.402s)! For help, type "help"'),
        const ServerStarted(),
      );
      expect(
        parseConsoleLine(
          '[12:00:00] [Server thread/INFO] [minecraft/DedicatedServer]: '
          'Done (12.345s)! For help, type "help" or "?"',
        ),
        const ServerStarted(),
      );
      expect(
        parseConsoleLine('[12:00:00 INFO]: Done (8.1s)! For help, type "help"'),
        const ServerStarted(),
      );
      expect(
        parseConsoleLine(
          "[12:00:00] [Server thread/INFO]: Saving chunks for level 'ServerLevel[world]'/minecraft:overworld",
        ),
        const SavingStarted(),
      );
      expect(
        parseConsoleLine(
          '[12:00:00] [Server thread/INFO]: Saving the game (this may take a moment!)',
        ),
        const SavingStarted(),
      );
      expect(
        parseConsoleLine('[12:00:00] [Server thread/INFO]: Stopping server'),
        const ServerStopping(),
      );
      expect(
        parseConsoleLine('[12:00:00] [Server thread/INFO]: Stopping the server'),
        const ServerStopping(),
      );
      expect(
        parseConsoleLine('[12:00:00] [Server thread/INFO]: Saved the game'),
        const SaveConfirmed(),
      );
    });

    test('la chat non li produce', () {
      const falsi = [
        '[12:00:00] [Server thread/INFO]: <bob> Saved the game',
        '[12:00:00] [Server thread/INFO]: <bob> Stopping server adesso',
        '[12:00:00] [Server thread/INFO]: <bob> Done (1.0s)!',
        '[12:00:00] [Server thread/INFO]: [bob] Done (1.0s)! For help, type "help"',
        '[12:00:00] [Server thread/INFO]: * bob Stopping server',
        '[12:00:00] [Server thread/INFO]: [bob] Stopping server',
        '[12:00:00] [Server thread/INFO]: Stopping server adesso',
        '[12:00:00] [Server thread/INFO]: [bob] Saving the game',
        'Done (1.0s)! For help, type "help"',
        'Stopping server',
      ];
      for (final l in falsi) {
        expect(parseConsoleLine(l), isNull, reason: l);
      }
    });

    test('EULA non accettata', () {
      expect(parseConsoleLine('[12:00:00] [main/WARN]: Failed to load eula.txt'), isNull);
      expect(
        parseConsoleLine(
          '[12:00:00] [main/INFO]: You need to agree to the EULA in order to run the server. '
          'Go to eula.txt for more info.',
        ),
        const EulaRequired(),
      );
      expect(
        parseConsoleLine(
          '[12:00:00] [Server thread/INFO]: <bob> You need to agree to the EULA in order to run '
          'the server.',
        ),
        isNull,
      );
    });
  });

  // La conferma di salvataggio si riconosce solo come corpo ESATTO di una
  // riga INFO del thread del server, nei formati veri dei vari server.
  test('B-SESSION-13 conferma di salvataggio nei formati veri', () {
    const veri = [
      '[12:00:00] [Server thread/INFO]: Saved the game',
      '[12:00:00] [Server thread/INFO] [minecraft/MinecraftServer]: Saved the game',
      '[29Jan2024 12:00:00.123] [Server thread/INFO] [net.minecraft.server.MinecraftServer/]: '
          'Saved the game',
      '[12:00:00] [Server thread/INFO] (Minecraft) Saved the game',
      '[12:00:00 INFO]: Saved the game',
      '> [12:00:00 INFO]: Saved the game',
      '[12:00:00] [Server thread/INFO]: ThreadedAnvilChunkStorage: All dimensions are saved',
      '[12:00:00] [Server thread/INFO]: Saved the game\r',
    ];
    for (final l in veri) {
      expect(parseConsoleLine(l), const SaveConfirmed(), reason: l);
    }
  });

  // Un falso "salvato" faceva partire lo snapshot a mondo ancora in scrittura.
  test('B-SESSION-14 conferma di salvataggio non falsificabile', () {
    const falsi = [
      '[12:00:00] [Server thread/INFO]: * Steve Saved the game', // /me
      '[12:00:00] [Server thread/INFO]: [Steve] Saved the game', // /say
      '[12:00:00] [Server thread/INFO] [minecraft/MinecraftServer]: [Steve] Saved the game',
      '[12:00:00 INFO]: [Steve] Saved the game', // /say su Paper
      '[12:00:00] [Server thread/INFO]: Steve was slain by Zombie using [Saved the game]',
      '[12:00:00] [Server thread/INFO]: Steve » Saved the game', // mod di chat
      '[12:00:00] [Server thread/INFO]: <Steve> Saved the game',
      '[12:00:00] [Server thread/INFO]: [Not Secure] <Steve> Saved the game',
      '[12:00:00] [Async Chat Thread - #0/INFO]: Saved the game', // altro thread
      '[12:00:00] [Server thread/WARN]: Saved the game',
      'Saved the game',
      '[12:00:00] [Server thread/INFO]: Saved the game, scherzo',
      '[12:00:00] [Server thread/INFO]: [Steve] [Server thread/INFO]: Saved the game',
    ];
    for (final l in falsi) {
      expect(parseConsoleLine(l), isNot(const SaveConfirmed()), reason: l);
    }
  });

  test('B-SESSION-15 conferma solo con un flush in attesa, una volta', () {
    final t = ConsoleTracker();
    const line = '[12:00:00] [Server thread/INFO]: Saved the game';
    expect(t.feed(line), isNull, reason: 'nessun save-all flush in attesa');
    t.expectSave();
    expect(t.savePending, isTrue);
    expect(t.feed(line), const SaveConfirmed());
    expect(t.savePending, isFalse);
    expect(t.feed(line), isNull, reason: 'una seconda conferma per lo stesso flush');
    // gli altri fatti non dipendono dal flush
    expect(t.feed('[12:00:00] [Server thread/INFO]: Stopping server'), const ServerStopping());
  });

  group('B-SESSION-16 righe lunghe', () {
    test('truncateConsoleLine', () {
      expect(truncateConsoleLine('breve'), 'breve');
      final exact = 'x' * maxConsoleLine;
      expect(truncateConsoleLine(exact), exact);
      final long = truncateConsoleLine('y' * (maxConsoleLine * 3));
      expect(long.length, maxConsoleLine + truncatedMarker.length);
      expect(long, endsWith(truncatedMarker));
      // una coppia surrogata a cavallo del limite non viene spezzata
      final emoji = '${'z' * (maxConsoleLine - 1)}😀tail';
      expect(truncateConsoleLine(emoji), '${'z' * (maxConsoleLine - 1)}$truncatedMarker');
    });

    // Prima un bufio.Scanner si arrendeva su una riga troppo lunga, nessuno
    // drenava più la pipe e il server si bloccava sulla write.
    test('la lettura continua e la riga dopo resta intatta', () async {
      final monster = 'x' * (maxConsoleLine * 3);
      const done = '[12:00:00] [Server thread/INFO]: Done (1.234s)! For help, type "help"';
      final bytes = utf8.encode('prima riga\r\n$monster\n$done\nultima senza a capo');
      // a pezzi piccoli, come arrivano da una pipe
      final chunks = [
        for (var i = 0; i < bytes.length; i += 4096)
          bytes.sublist(i, i + 4096 > bytes.length ? bytes.length : i + 4096),
      ];
      final lines = await Stream<List<int>>.fromIterable(
        chunks,
      ).transform(const ConsoleLineSplitter()).toList();
      expect(lines, hasLength(4));
      expect(lines[0], 'prima riga');
      expect(lines[1].length, maxConsoleLine + truncatedMarker.length);
      expect(lines[1], endsWith(truncatedMarker));
      expect(lines[2], done);
      expect(parseConsoleLine(lines[2]), const ServerStarted());
      expect(lines[3], 'ultima senza a capo');
    });

    test('byte non UTF-8 non interrompono la lettura', () async {
      final lines = await Stream<List<int>>.fromIterable([
        [0x63, 0x69, 0xE0, 0x6F, 0x0A], // "cià" in cp1252
        utf8.encode('dopo\n'),
      ]).transform(const ConsoleLineSplitter()).toList();
      expect(lines, ['ci�o', 'dopo']);
    });
  });

  // I fatti riconosciuti finiscono in coda anche se nessuno legge le righe.
  test('B-SESSION-17 i fatti si accodano, la chat no, drain svuota', () {
    final t = ConsoleTracker()..expectSave();
    const righe = [
      '[12:00:00] [Server thread/INFO]: Done (10.0s)! For help, type "help"',
      '[12:00:01] [Server thread/INFO]: alice joined the game',
      '[12:00:02] [Server thread/INFO]: <alice> ciao a tutti',
      '[12:00:03] [Server thread/INFO]: Saved the game',
    ];
    righe.forEach(t.feed);
    expect(t.drain(), const [ServerStarted(), PlayerJoined('alice'), SaveConfirmed()]);
    expect(t.drain(), isEmpty);
  });
}
