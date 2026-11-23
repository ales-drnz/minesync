// Stato di esecuzione che altre parti dell'hub (DNS, /dl, interfaccia web)
// impostano mentre girano, letto da GET /hub, GET /spaces e GET /system.
import 'package:ms_protocol/ms_protocol.dart';

/// Stato del server DNS integrato. Il server DNS lo aggiorna quando si mette
/// in ascolto (o non ci riesce); finché [running] è falso l'hub non espone
/// né `dnsZone` né `dnsName`.
final class DnsRuntime {
  DnsRuntime({this.zone, this.addr});

  /// Il server risponde sulla porta.
  bool running = false;

  /// Zona servita (MINESYNC_DNS_ZONE, minuscola).
  String? zone;

  /// Indirizzo di ascolto (MINESYNC_DNS_ADDR o `:53`).
  String? addr;

  /// Perché non è partito (es. porta occupata).
  String? error;

  /// La zona, solo con il server in ascolto.
  String? get activeZone => running && zone != null && zone!.isNotEmpty ? zone : null;

  /// `zerotier.<id>.<zona>` (B-DNS-01), solo con il server in ascolto.
  String? nameOf(String spaceId) {
    final z = activeZone;
    return z == null ? null : 'zerotier.$spaceId.$z';
  }

  DnsStatus toStatus() => DnsStatus(on: running, zone: zone, addr: addr, error: error);
}

/// Dati che vengono da /dl e dalla build web, forniti da chi li serve.
final class HubExtras {
  /// Piattaforme con l'aggiornamento automatico pubblicato su /dl.
  Future<List<UpdateChannel>> Function() updates = () async => const [];

  /// Byte occupati da MINESYNC_DL (per `GET /usage`).
  Future<int> Function() dlBytes = () async => 0;

  /// Id della build web servita, se c'è.
  String? Function() webBuild = () => null;
}
