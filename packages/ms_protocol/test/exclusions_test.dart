import 'package:ms_protocol/ms_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('glob di segmento', () {
    test('casi base', () {
      expect(globMatch('*.lock', 'session.lock'), isTrue);
      expect(globMatch('*.lock', 'session.lock.bak'), isFalse);
      expect(globMatch('r.?.0.mca', 'r.1.0.mca'), isTrue);
      expect(globMatch('world_backup*', 'world_backup_2024'), isTrue);
      expect(globMatch('[abc]x', 'bx'), isTrue);
      expect(globMatch('[!abc]x', 'bx'), isFalse);
      expect(globMatch('[a-c]x', 'cx'), isTrue);
      expect(globMatch('[a-c', 'a'), isFalse);
      expect(globMatch('*', ''), isTrue);
      expect(globMatch('a*b*c', 'axxbyyc'), isTrue);
      expect(globMatch('a*b*c', 'axxbyy'), isFalse);
    });
  });

  group('profilo minecraft', () {
    final ex = Exclusions(minecraftExclusions);

    test('esclusi', () {
      for (final p in [
        'logs/latest.log',
        'logs/2024/x.log.gz',
        'crash-reports/c.txt',
        'world/session.lock',
        'session.lock',
        'hs_err_pid123.log',
        'world_backup_1/level.dat',
        'backups/a.zip',
        'mods/.DS_Store',
        '.DS_Store',
        '.git/HEAD',
        'x.minesyncpart',
        'world/.minesync-tmp',
        '.minesync/base.json',
        'LOGS/Latest.log',
        r'$recycle.bin/x',
      ]) {
        expect(ex.excludes(p), isTrue, reason: p);
      }
    });

    test('inclusi', () {
      for (final p in [
        'world/level.dat',
        'world/region/r.0.0.mca',
        'libraries/net/minecraftforge/forge.jar',
        'server.properties',
        // i nomi dei giocatori servono all'hub
        'usercache.json',
        'usernamecache.json',
        'mods/backups-mod.jar',
        'config/logs.toml',
        'world/data/logs/stats.dat',
      ]) {
        expect(ex.excludes(p), isFalse, reason: p);
      }
    });

    test('cartella logs annidata: solo alla radice', () {
      // "logs/**" è ancorato alla radice: world/data/logs resta incluso
      expect(ex.excludesDir('world/data/logs'), isFalse);
      expect(ex.excludesDir('logs'), isTrue);
    });

    test('potatura: un glob sul nome non pota una cartella', () {
      expect(ex.excludesDir('weird.lock'), isFalse);
      expect(ex.excludes('weird.lock/inside.txt'), isFalse);
      expect(ex.excludesDir('world_backup_7'), isTrue);
      expect(ex.excludesDir('.minesync'), isTrue);
    });
  });

  test('pattern personalizzati, commenti e barre', () {
    final ex = Exclusions(['# commento', '', r'\dynmap\web\**', '**/cache', 'config/*.bak']);
    expect(ex.excludes('dynmap/web/tiles/a.png'), isTrue);
    expect(ex.excludes('a/b/cache/x'), isTrue);
    expect(ex.excludesDir('a/b/cache'), isTrue);
    expect(ex.excludes('config/x.bak'), isTrue);
    expect(ex.excludes('config/sub/x.bak'), isFalse);
  });
}
