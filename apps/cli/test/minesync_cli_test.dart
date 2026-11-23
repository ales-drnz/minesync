import 'dart:io';

import 'package:minesync_cli/minesync_cli.dart';
import 'package:ms_core/ms_core.dart';
import 'package:ms_l10n/ms_l10n.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Map<String, String> env;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ms_cli');
    env = {'MINESYNC_CONFIG_DIR': tmp.path, 'LANG': 'it_IT.UTF-8'};
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<(int, String, String)> run(List<String> args) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runCli(args, env: env, out: out, err: err);
    return (code, out.toString(), err.toString());
  }

  test('senza argomenti: uso e codice 2', () async {
    final (code, out, _) = await run([]);
    expect(code, 2);
    expect(out, contains('minesync <comando>'));
  });

  test('versione', () async {
    expect((await run(['--version'])).$2, 'minesync $cliVersion\n');
  });

  test('comando sconosciuto: codice 2 e messaggio tradotto', () async {
    final (code, _, err) = await run(['boh']);
    expect(code, 2);
    expect(err, contains('comando sconosciuto: boh'));
  });

  test('lingua inglese dall\'ambiente', () async {
    env['LANG'] = 'en_US.UTF-8';
    expect((await run(['spaces'])).$3, contains('no hub configured'));
  });

  test('nessun hub: indica il login', () async {
    final (code, _, err) = await run(['spaces']);
    expect(code, 2);
    expect(err, contains('minesync login'));
  });

  test('hub irraggiungibile: messaggio sulla rete, niente salvato', () async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    final (code, _, err) = await run(['login', '127.0.0.1:$port']);
    expect(code, 1);
    expect(err, contains('ZeroTier'));
    expect(AppConfig.load(tmp.path).hub, isNull);
  });

  test('configurazione: salvataggio atomico e rilettura', () async {
    final c = AppConfig(hub: 'http://192.0.2.10:8084/', links: {'survival': '/srv/s'});
    await c.save(tmp.path);
    final back = AppConfig.load(tmp.path);
    expect(back.hub, c.hub);
    expect(back.links, {'survival': '/srv/s'});
  });

  group('lingua (B-I18N-02)', () {
    test('riconosce le varianti', () {
      for (final v in ['it', 'it_IT.UTF-8', 'it-IT', 'IT', 'it_CH@euro', 'fr:it']) {
        expect(parseLang(v), Lang.it, reason: v);
      }
      expect(parseLang('en_US'), Lang.en);
      for (final v in ['C', 'POSIX', 'C.UTF-8', 'fr_FR', '', null]) {
        expect(parseLang(v), isNull, reason: '$v');
      }
    });

    test('ambiente: MINESYNC_LANG vince, poi LC_ALL', () {
      expect(langFromEnv({'LANG': 'it_IT', 'MINESYNC_LANG': 'en'}), Lang.en);
      expect(langFromEnv({'LANG': 'en_US', 'LC_ALL': 'it_IT'}), Lang.it);
      expect(langFromEnv({'LANG': 'C'}), Lang.en);
    });
  });

  group('messaggi di errore', () {
    final it = Strings.of(Lang.it);
    final en = Strings.of(Lang.en);

    test('ogni tipo di errore del sync ha un testo in entrambe le lingue', () {
      for (final k in SyncErrorKind.values) {
        final e = SyncException(k, changed: const ['a'], path: 'world');
        expect(describeError(it, e), isNot(contains('SyncException')), reason: k.name);
        expect(describeError(en, e), isNot(contains('SyncException')), reason: k.name);
        expect(describeError(it, e), isNot(describeError(en, e)), reason: k.name);
      }
    });

    test('divergente o no', () {
      expect(
        describeError(it, const SyncException(SyncErrorKind.dirtyLocal, diverged: true)),
        contains('--discard-local'),
      );
      expect(describeError(it, const SyncException(SyncErrorKind.dirtyLocal)), contains('push'));
    });

    test('lock di un altro: nome di chi gioca', () {
      const e = ApiError(ErrorCode.locked, 'locked', details: {'owner': 'bob'});
      expect(describeError(it, e), 'bob sta giocando su questo server');
    });

    test('errori di rete', () {
      expect(describeError(en, const HubUnreachable('x')), contains('ZeroTier'));
      expect(describeError(en, const TransferStalled('x')), contains('stalled'));
    });
  });
}
