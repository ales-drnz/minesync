// Servizio di aggiornamento dell'app contro un hub finto locale: firma,
// versioni più vecchie, versioni già fallite, percorso buono fino al
// riavvio, marker di avvio.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_desktop/src/update/update_service.dart';
import 'package:minesync_launcher/update.dart';
import 'package:path/path.dart' as p;

const plat = 'test-x64';

/// Hub finto: serve [root] sotto /dl/ e ricorda le richieste.
Future<(HttpServer, List<String>)> serve(String root) async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final log = <String>[];
  s.listen((req) async {
    log.add(req.uri.path);
    final rel = req.uri.path.replaceFirst('/dl/', '');
    final f = File(p.joinAll([root, ...rel.split('/')]));
    if (req.uri.path.startsWith('/dl/') && f.existsSync()) {
      await req.response.addStream(f.openRead());
    } else {
      req.response.statusCode = 404;
    }
    await req.response.close();
  });
  return (s, log);
}

void main() {
  late Directory tmp;
  late String seed, pub, root, hubDir;
  late HttpServer server;
  late List<String> requests;
  late Uri hub;

  setUpAll(() async => (seed, pub) = await generateKeyPair());
  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('ms_update');
    root = p.join(tmp.path, 'install');
    hubDir = p.join(tmp.path, 'hub');
    await Directory(root).create();
    await Install(root).writeState(InstallState(current: '0.1.0'));
    (server, requests) = await serve(hubDir);
    hub = Uri.parse('http://127.0.0.1:${server.port}');
  });
  tearDown(() async {
    await server.close(force: true);
    tmp.deleteSync(recursive: true);
  });

  Future<void> publish(String version, {String? key}) async {
    final src = Directory(p.join(tmp.path, 'bundle-$version'))..createSync();
    File(p.join(src.path, 'minesync_desktop')).writeAsStringSync('app $version');
    File(p.join(src.path, 'data', 'x.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('dati');
    await packRelease(
      seedB64: key ?? seed,
      version: version,
      platform: plat,
      entrypoint: 'minesync_desktop',
      src: src.path,
      out: hubDir,
    );
  }

  final exits = <int>[];
  HubUpdateService service({Map<String, String>? env, String? key}) {
    exits.clear();
    return HubUpdateService(
      env: env ?? {'MINESYNC_ROOT': root, 'MINESYNC_VERSION': '0.1.0'},
      pubKey: key ?? pub,
      platform: plat,
      exit: exits.add,
      log: (_) {},
    );
  }

  bool archiveRequested() => requests.any((r) => r.endsWith('.tar.gz'));

  test('percorso buono: scarica, verifica, pronta, riavvio con 75', () async {
    await publish('0.2.0');
    final u = service();
    var notified = 0;
    u.addListener(() => notified++);
    await u.check(hub);
    expect(u.ready, '0.2.0');
    expect(notified, 1);
    expect(requests, contains('/dl/update/$plat/manifest.json'));
    expect(requests, contains('/dl/update/$plat/manifest.json.sig'));
    final s = await Install(root).readState();
    expect((s.current, s.pending), ('0.1.0', '0.2.0'));
    expect(
      File(p.join(Install(root).versionDir('0.2.0'), 'minesync_desktop')).readAsStringSync(),
      'app 0.2.0',
    );
    await u.restart();
    expect(exits, [75]);
  });

  test('firma sbagliata: niente download, niente stato', () async {
    final (evil, _) = await generateKeyPair();
    await publish('0.2.0', key: evil);
    final u = service();
    await u.check(hub);
    expect(u.ready, isNull);
    expect(u.lastError, isA<SignatureException>());
    expect(archiveRequested(), isFalse);
    expect((await Install(root).readState()).pending, isNull);
    await u.restart();
    expect(exits, isEmpty);
  });

  test('versione più vecchia o uguale: rifiutata senza scaricare', () async {
    for (final v in ['0.0.9', '0.1.0']) {
      await publish(v);
      final u = service();
      await u.check(hub);
      expect(u.ready, isNull, reason: v);
      expect(archiveRequested(), isFalse, reason: v);
    }
  });

  test('versione già fallita (bad): ignorata', () async {
    await Install(root).writeState(InstallState(current: '0.1.0', bad: ['0.2.0']));
    await publish('0.2.0');
    final u = service();
    await u.check(hub);
    expect(u.ready, isNull);
    expect(archiveRequested(), isFalse);
  });

  test('pending già pronta da prima: nessuna richiesta all\'hub', () async {
    await Install(root).writeState(InstallState(current: '0.1.0', pending: '0.3.0'));
    final u = service();
    await u.check(hub);
    expect(u.ready, '0.3.0');
    expect(requests, isEmpty);
  });

  test('senza launcher o senza chiave incorporata non fa niente', () async {
    await publish('0.2.0');
    for (final u in [service(env: const {}), service(key: '')]) {
      expect(u.managed, isFalse);
      await u.check(hub);
      expect(u.ready, isNull);
    }
    expect(requests, isEmpty);
  });

  test('hub con un percorso: il manifest si cerca sotto /dl/', () async {
    await publish('0.2.0');
    final u = service();
    await u.check(hub.replace(path: '/'));
    expect(u.ready, '0.2.0');
  });

  test('marker di avvio: scritto con la versione, solo se il launcher lo chiede', () async {
    final f = p.join(tmp.path, 'run', 'healthy-0.1.0');
    await markHealthy({'MINESYNC_HEALTH_FILE': f, 'MINESYNC_VERSION': '0.1.0'});
    expect(File(f).readAsStringSync(), '0.1.0');
    await markHealthy(const {});
  });
}
