// `hub healthcheck`: il controllo dell'HEALTHCHECK dell'immagine Docker.
import 'dart:io';

import 'package:minesync_hub/minesync_hub.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  HubConfig cfg(String addr) => HubConfig.fromEnv({'MINESYNC_ADDR': addr, 'MINESYNC_DATA': '/x'});

  test('su tutti gli indirizzi si interroga il loopback, altrimenti quello d\'ascolto', () {
    expect(healthCheckAddress(cfg(':8084')), InternetAddress.loopbackIPv4);
    expect(healthCheckAddress(cfg('0.0.0.0:8084')), InternetAddress.loopbackIPv4);
    expect(healthCheckAddress(cfg('[::]:8084')), InternetAddress.loopbackIPv4);
    expect(healthCheckAddress(cfg('192.0.2.10:8084')).address, '192.0.2.10');
    expect(healthCheckAddress(cfg('[::1]:8084')).address, '::1');
  });

  test('un hub vero senza web UI è sano (404 su /, senza identità)', () async {
    final t = await TestHub.start();
    addTearDown(t.close);
    expect(await healthCheck(cfg('127.0.0.1:${t.hub.port}')), isNull);
    expect(await healthCheck(cfg(':${t.hub.port}')), isNull);
    // nessun membro visto, nessuna riga di log
    expect(t.hub.members.records, isEmpty);
    expect(t.logs.where((l) => !l.startsWith('hub: web')), isEmpty);
  });

  test('un 5xx o una porta chiusa non sono sani', () async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => s.close(force: true));
    s.listen(
      (r) => r.response
        ..statusCode = 503
        ..close(),
    );
    expect(await healthCheck(cfg('127.0.0.1:${s.port}')), 'HTTP 503');

    final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = free.port;
    await free.close();
    expect(await healthCheck(cfg('127.0.0.1:$port')), isNotNull);
  });

  test('un server che non risponde scade', () async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(s.close);
    s.listen((_) {}); // accetta e tace
    final r = await healthCheck(
      cfg('127.0.0.1:${s.port}'),
      timeout: const Duration(milliseconds: 300),
    );
    expect(r, contains('nessuna risposta'));
  });
}
