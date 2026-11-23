// Controllo di salute per l'HEALTHCHECK dell'immagine Docker: l'immagine è
// distroless (niente shell né curl), quindi è il binario stesso dell'hub a
// interrogarsi (`hub healthcheck`).
import 'dart:async';
import 'dart:io';

import 'config.dart';

/// L'indirizzo da interrogare per [config]: quello d'ascolto, o il loopback
/// IPv4 se l'hub ascolta su tutti gli indirizzi (il socket è dual-stack).
InternetAddress healthCheckAddress(HubConfig config) {
  final a = config.address;
  return a.rawAddress.every((b) => b == 0) ? InternetAddress.loopbackIPv4 : a;
}

/// Una GET di `/` all'hub: qualunque risposta HTTP sotto 500 vuol dire che
/// risponde. `/` (web UI o 404) non chiede l'identità, quindi il controllo
/// non interroga ZTNET, non segna nessun membro come visto e non scrive log.
/// Ritorna il motivo del fallimento, o null se l'hub è sano.
Future<String?> healthCheck(
  HubConfig config, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  final addr = healthCheckAddress(config);
  final host = addr.type == InternetAddressType.IPv6 ? '[${addr.address}]' : addr.address;
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final req = await client.get(addr.address, config.port, '/').timeout(timeout);
    // un IP letterale è sempre un host ammesso
    req.headers.host = host;
    req.headers.port = config.port;
    final res = await req.close().timeout(timeout);
    await res.drain<void>().timeout(timeout);
    return res.statusCode < 500 ? null : 'HTTP ${res.statusCode}';
  } on TimeoutException {
    return 'nessuna risposta da $host:${config.port} entro ${timeout.inSeconds} s';
  } on Object catch (e) {
    return '$host:${config.port}: $e';
  } finally {
    client.close(force: true);
  }
}
