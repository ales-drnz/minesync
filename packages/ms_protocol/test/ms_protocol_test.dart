import 'dart:convert';

import 'package:ms_protocol/ms_protocol.dart';
import 'package:test/test.dart';

String h(int i) => i.toRadixString(16).padLeft(64, '0');

void main() {
  group('percorsi', () {
    test('validi', () {
      for (final p in [
        'server.properties',
        'world/region/r.0.0.mca',
        'mods/Città-1.2.jar',
        'a/.hidden/b',
        'config/x..y',
      ]) {
        expect(checkPath(p), isNull, reason: p);
      }
    });

    test('non validi', () {
      final cases = {
        '': PathProblem.empty,
        '/etc/passwd': PathProblem.absolute,
        'a/': PathProblem.trailingSlash,
        'a//b': PathProblem.emptySegment,
        'a/../b': PathProblem.dotSegment,
        './a': PathProblem.dotSegment,
        'a\\b': PathProblem.forbiddenChar,
        'a:b': PathProblem.forbiddenChar,
        'what?': PathProblem.forbiddenChar,
        'a\u0001b': PathProblem.controlChar,
        'a\nb': PathProblem.controlChar,
        'dir./x': PathProblem.trailingDotOrSpace,
        'name ': PathProblem.trailingDotOrSpace,
        'CON': PathProblem.reservedName,
        'logs/nul.txt': PathProblem.reservedName,
        'Com1.log': PathProblem.reservedName,
        '.minesync/base.json': PathProblem.reservedPrefix,
        '.MineSync-backup/x': PathProblem.reservedPrefix,
        'Città': PathProblem.notNfc,
        'x' * 1025: PathProblem.tooLong,
      };
      cases.forEach((p, want) => expect(checkPath(p), want, reason: p));
    });

    test('nomi simili ai riservati restano validi', () {
      for (final p in [
        'console',
        'con.d/x'.replaceAll('con.d', 'cond'),
        'auxiliary.txt',
        'com10',
        'lpt',
      ]) {
        expect(checkPath(p), isNull, reason: p);
      }
    });

    test('collisioni di maiuscole', () {
      expect(caseCollisions(['a/B.txt', 'a/b.txt', 'c']), [('a/B.txt', 'a/b.txt')]);
      expect(caseCollisions(['a', 'b']), isEmpty);
    });

    test('ordine per code point, non per unità UTF-16', () {
      // U+FF21 (BMP alto) viene prima di U+1F600 (fuori BMP) in UTF-8,
      // mentre in UTF-16 il surrogato 0xD83D viene prima di 0xFF21.
      expect(comparePaths('Ａ', '\u{1F600}'), lessThan(0));
      expect('Ａ'.compareTo('\u{1F600}'), greaterThan(0));
      expect(comparePaths('a', 'ab'), lessThan(0));
      expect(comparePaths('ab', 'ab'), 0);
    });
  });

  group('manifest', () {
    test('digest stabile e indipendente dall\'ordine di inserimento', () {
      final a = Manifest({
        'b': FileEntry(size: 1, h: h(1)),
        'a': FileEntry(size: 2, h: h(2), x: true),
      });
      final b = Manifest({
        'a': FileEntry(size: 2, h: h(2), x: true),
        'b': FileEntry(size: 1, h: h(1)),
      });
      expect(a.digest(), b.digest());
      expect(
        utf8.decode(a.canonicalBytes()),
        '{"a":{"size":2,"h":"${h(2)}","x":true},"b":{"size":1,"h":"${h(1)}"}}',
      );
    });

    test('il digest cambia con il bit di esecuzione', () {
      final a = Manifest({'s.sh': FileEntry(size: 1, h: h(1))});
      final b = Manifest({'s.sh': FileEntry(size: 1, h: h(1), x: true)});
      expect(a.digest(), isNot(b.digest()));
    });

    test('vuoto', () {
      expect(utf8.decode(Manifest.empty.canonicalBytes()), '{}');
      expect(emptyDigest, '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a');
    });

    test('rifiuta percorsi non validi e collisioni', () {
      expect(() => Manifest({'../x': FileEntry(size: 0, h: h(0))}), throwsA(isA<ManifestError>()));
      expect(
        () => Manifest({'A': FileEntry(size: 0, h: h(0)), 'a': FileEntry(size: 0, h: h(0))}),
        throwsA(isA<ManifestError>()),
      );
    });

    test('chunk: la somma deve tornare', () {
      expect(() => FileEntry(size: 10, h: h(1), chunks: [Chunk(h(2), 4)]), throwsFormatException);
      final e = FileEntry(size: 10, h: h(1), chunks: [Chunk(h(2), 4), Chunk(h(3), 6)]);
      expect(e.blobs, [h(2), h(3)]);
    });

    test('andata e ritorno JSON', () {
      final m = Manifest({
        'world/region/r.0.0.mca': FileEntry(
          size: 10,
          h: h(1),
          chunks: [Chunk(h(2), 4), Chunk(h(3), 6)],
        ),
        'run.sh': FileEntry(size: 3, h: h(4), x: true),
      });
      final back = Manifest.fromJson(jsonDecode(jsonEncode(m.toJson())));
      expect(back.digest(), m.digest());
      expect(back['world/region/r.0.0.mca'], m['world/region/r.0.0.mca']);
      expect(m.blobs, {h(2), h(3), h(4)});
    });

    test('hash non valido rifiutato in decodifica', () {
      expect(
        () => Manifest.fromJson({
          'a': {'size': 1, 'h': 'ABC'},
        }),
        throwsFormatException,
      );
      expect(
        () => Manifest.fromJson({
          'a': {'size': -1, 'h': h(1)},
        }),
        throwsFormatException,
      );
    });

    test('diff', () {
      final a = Manifest({
        'keep': FileEntry(size: 1, h: h(1)),
        'gone': FileEntry(size: 1, h: h(2)),
        'mod': FileEntry(size: 1, h: h(3)),
      });
      final b = Manifest({
        'keep': FileEntry(size: 1, h: h(1)),
        'mod': FileEntry(size: 1, h: h(4)),
        'new': FileEntry(size: 1, h: h(5)),
      });
      final d = ManifestDiff(a, b);
      expect(d.added, ['new']);
      expect(d.removed, ['gone']);
      expect(d.changed, ['mod']);
    });
  });

  group('errori', () {
    test('andata e ritorno', () {
      const e = ApiError(ErrorCode.staleBase, 'HEAD moved', details: {'head': 7});
      final back = ApiError.fromJson(jsonDecode(jsonEncode(e.toJson())), status: 409);
      expect(back.code, ErrorCode.staleBase);
      expect(back.details['head'], 7);
      expect(back.httpStatus, 409);
    });

    test('corpo non riconosciuto', () {
      expect(ApiError.fromJson('boh', status: 502).code, ErrorCode.internal);
      expect(
        ApiError.fromJson({
          'error': {'code': 'nuovo_codice'},
        }).code,
        ErrorCode.internal,
      );
    });

    test('codici unici', () {
      expect(ErrorCode.values.map((c) => c.wire).toSet().length, ErrorCode.values.length);
    });
  });

  group('modelli', () {
    test('push begin andata e ritorno', () {
      final p = PushBegin(
        parent: 3,
        parentDigest: h(9),
        lockToken: 't',
        manifest: Manifest({'a': FileEntry(size: 1, h: h(1))}),
        message: 'ciao',
        kind: GenerationKind.autosave,
      );
      final back = PushBegin.fromJson(jsonDecode(jsonEncode(p.toJson())));
      expect(back.parent, 3);
      expect(back.kind, GenerationKind.autosave);
      expect(back.manifest.digest(), p.manifest.digest());
      expect(back.confirmMassDelete, isFalse);
    });

    test('spazio vuoto: testa 0 e digest del manifest vuoto', () {
      final s = SpaceSummary.fromJson({
        'id': 'survival',
        'name': 'Survival',
        'profile': 'minecraft',
        'createdAt': 1,
        'head': null,
        'lock': null,
      });
      expect(s.headN, 0);
      expect(s.headDigest, emptyDigest);
    });

    test('campo mancante = FormatException', () {
      expect(() => Me.fromJson({'id': 'x'}), throwsFormatException);
      expect(() => Profile.parse('modded'), throwsFormatException);
    });
  });
}
