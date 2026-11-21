// Entrypoint dello spike: hub HTTP + DNS.
//
// Configurazione da variabili d'ambiente (come la 3.x):
//   HUB_DATA=/data   HUB_HTTP_PORT=8084   HUB_DNS_PORT=53 (0 = disattivo)
//   HUB_DNS_ZONE=internal
//   HUB_DNS_RECORDS=alpha=192.0.2.10:25565,beta=192.0.2.20:25570,gamma=
//       (gamma = spazio esistente senza host; IP di documentazione RFC 5737)
//   HUB_HASH=dart|openssl|none   HUB_KEEPALIVE_S=25   HUB_HASH_WORKERS=<n>
//   HUB_RCVBUF_KB=1024 (SO_RCVBUF per connessione, 0 = autotuning)
//   HUB_MAX_UPLOADS=4 (corpi letti in parallelo; gli altri in coda)
//
// `hub healthcheck` fa GET http://127.0.0.1:<porta>/healthz ed esce 0/1:
// serve all'HEALTHCHECK di un'immagine distroless, che non ha curl né shell.
import 'dart:async';
import 'dart:io';

import 'package:spike_server/api.dart';
import 'package:spike_server/dns.dart';
import 'package:spike_server/hasher.dart';
import 'package:spike_server/store.dart';

Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final httpPort = int.parse(env['HUB_HTTP_PORT'] ?? '8084');

  if (args.isNotEmpty && args.first == 'healthcheck') {
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 2);
      final r = await (await c.get('127.0.0.1', httpPort, '/healthz'))
          .close()
          .timeout(const Duration(seconds: 3));
      exit(r.statusCode == 200 ? 0 : 1);
    } catch (_) {
      exit(1);
    }
  }

  // worker di hash: CPU effettive - 1 (l'event loop deve restare libero
  // anche quando la quota CFS di docker --cpus è al limite), minimo 1
  final cpus = effectiveCpus();
  final nWorkers = int.tryParse(env['HUB_HASH_WORKERS'] ?? '') ?? (cpus - 1).clamp(1, 8);
  final pool = await HashPool.start(hashModeFrom(env['HUB_HASH']), nWorkers);
  final store = BlobStore(env['HUB_DATA'] ?? '/data', pool);
  final cleaned = await store.open();
  final hub = Hub(store,
      keepalive: Duration(seconds: int.parse(env['HUB_KEEPALIVE_S'] ?? '25')),
      rcvBufBytes: int.parse(env['HUB_RCVBUF_KB'] ?? '1024') * 1024,
      maxUploads: int.parse(env['HUB_MAX_UPLOADS'] ?? '4'));
  final port = await hub.serve(InternetAddress.anyIPv4, httpPort);
  stdout.writeln('hub: http :$port, hash=${pool.mode.name} '
      '(worker ${pool.workers}, cpu $cpus), '
      'temporanei ripuliti all\'avvio: $cleaned');

  final dnsPort = int.parse(env['HUB_DNS_PORT'] ?? '53');
  DnsServer? dns;
  if (dnsPort > 0) {
    final hosts = <String, DnsHost?>{};
    for (final e in (env['HUB_DNS_RECORDS'] ?? '').split(',')) {
      if (e.trim().isEmpty) continue;
      final kv = e.split('=');
      if (kv.length < 2 || kv[1].isEmpty) {
        hosts[kv[0]] = null;
        continue;
      }
      final ipPort = kv[1].split(':');
      hosts[kv[0]] = DnsHost(InternetAddress(ipPort[0]),
          ipPort.length > 1 ? int.parse(ipPort[1]) : 25565);
    }
    dns = DnsServer(env['HUB_DNS_ZONE'] ?? 'internal', hosts);
    try {
      final p = await dns.start(InternetAddress.anyIPv4, dnsPort);
      stdout.writeln('hub: dns udp :$p, zona ${dns.zone}, ${hosts.length} spazi');
    } on SocketException catch (e) {
      // come la 3.x: senza la :53 l'hub continua a servire l'HTTP
      stderr.writeln('hub: DNS non avviato: ${e.osError?.message ?? e.message}');
      dns = null;
    }
  }

  // spegnimento ordinato su SIGTERM/SIGINT (docker stop)
  for (final sig in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
    sig.watch().listen((_) async {
      dns?.close();
      await hub.close();
      exit(0);
    });
  }
}
