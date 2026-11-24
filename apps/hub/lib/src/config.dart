// Configurazione dell'hub dalle variabili d'ambiente.
import 'dart:io';

import 'disk.dart';

/// Versione dell'hub (allineata a VERSION del repository).
const String hubVersion = '0.1.0';

final class HubConfig {
  HubConfig({
    required this.dataDir,
    InternetAddress? address,
    this.port = 8084,
    this.admins = const [],
    this.dnsZone,
    this.dnsBind,
    this.allowedHosts = const [],
    this.maxUploads = 4,
    this.minFree,
    this.devUser,
    this.devUsers = const {},
    this.ztnetUrl,
    this.ztnetToken,
    this.ztnetNetwork,
    this.keepAlive = const Duration(seconds: 15),
    this.jsonLimit = 64 << 20,
    this.receiveBuffer = 1 << 20,
    String? http,
    this.dnsAddr,
    this.dlDir,
    this.webDir,
    this.timeZone,
  }) : address = address ?? InternetAddress.anyIPv6,
       http = http ?? ':$port';

  /// Legge la configurazione da [env]. Lancia [FormatException] su valori
  /// non validi.
  factory HubConfig.fromEnv(Map<String, String> env) {
    String? v(String k) {
      final s = env[k]?.trim();
      return s == null || s.isEmpty ? null : s;
    }

    List<String> list(String k) => [
      for (final s in (v(k) ?? '').split(','))
        if (s.trim().isNotEmpty) s.trim(),
    ];

    final http = v('MINESYNC_ADDR') ?? ':8084';
    final (addr, port) = parseListenAddress(http);
    final maxUp = int.tryParse(v('MINESYNC_MAX_UPLOADS') ?? '4');
    if (maxUp == null || maxUp < 1) {
      throw const FormatException('MINESYNC_MAX_UPLOADS: atteso un intero ≥ 1');
    }
    final minFree = v('MINESYNC_MIN_FREE');
    final rcv = v('MINESYNC_RCVBUF');
    final zone = v('MINESYNC_DNS_ZONE')?.toLowerCase();
    final dnsAddr = v('MINESYNC_DNS_ADDR');
    (InternetAddress, int)? dnsBind;
    if (zone != null && dnsAddr?.toLowerCase() != 'off') {
      try {
        dnsBind = parseListenAddress(dnsAddr ?? ':53');
      } on FormatException catch (e) {
        throw FormatException('MINESYNC_DNS_ADDR: ${e.message}');
      }
    }
    final devUser = v('MINESYNC_DEV_USER');
    final devUsersRaw = v('MINESYNC_DEV_USERS');
    final devUsers = devUsersRaw == null ? const <String, String>{} : parseDevUsers(devUsersRaw);
    if (devUsersRaw != null) {
      if (devUser != null) {
        throw const FormatException('MINESYNC_DEV_USERS e MINESYNC_DEV_USER si escludono');
      }
      if (!addr.isLoopback) {
        throw FormatException(
          'MINESYNC_DEV_USERS: MINESYNC_ADDR deve essere di loopback, non $http',
        );
      }
      if (addr.type != InternetAddressType.IPv4) {
        throw const FormatException(
          'MINESYNC_DEV_USERS: MINESYNC_ADDR deve essere un IPv4 127.x.y.z',
        );
      }
    }
    return HubConfig(
      dataDir: v('MINESYNC_DATA') ?? '/data',
      address: addr,
      port: port,
      admins: list('MINESYNC_ADMINS'),
      dnsZone: zone,
      dnsBind: dnsBind,
      allowedHosts: list('MINESYNC_HOSTS'),
      maxUploads: maxUp,
      minFree: minFree == null ? null : parseBytes(minFree),
      devUser: devUser,
      devUsers: devUsers,
      ztnetUrl: v('ZTNET_URL'),
      ztnetToken: v('ZTNET_API_TOKEN'),
      ztnetNetwork: v('ZTNET_NETWORK_ID'),
      receiveBuffer: rcv == null ? 1 << 20 : parseBytes(rcv),
      http: http,
      dnsAddr: v('MINESYNC_DNS_ADDR'),
      dlDir: v('MINESYNC_DL'),
      webDir: v('MINESYNC_WEB'),
      timeZone: v('TZ'),
    );
  }

  final String dataDir;
  final InternetAddress address;
  final int port;

  /// Nomi o node id degli admin (MINESYNC_ADMINS).
  final List<String> admins;

  /// Zona DNS dell'hub: i nomi `<x>.<zona>` sono host ammessi.
  final String? dnsZone;

  /// Dove ascolta il server DNS (MINESYNC_DNS_ADDR, `:53` se c'è la zona);
  /// null = DNS spento (`off` o zona assente).
  final (InternetAddress, int)? dnsBind;

  /// Altri host ammessi (MINESYNC_HOSTS).
  final List<String> allowedHosts;

  /// Upload di blob che leggono il corpo in parallelo.
  final int maxUploads;

  /// Soglia di spazio libero esplicita (MINESYNC_MIN_FREE).
  final int? minFree;
  final String? devUser;

  /// MINESYNC_DEV_USERS: indirizzo di loopback → nome, un giocatore di
  /// sviluppo per indirizzo (vuota = spenta).
  final Map<String, String> devUsers;
  final String? ztnetUrl;
  final String? ztnetToken;
  final String? ztnetNetwork;

  /// Commenti di keep-alive sugli stream SSE.
  final Duration keepAlive;

  /// Limite dei corpi JSON (decompressi).
  final int jsonLimit;

  /// SO_RCVBUF delle connessioni accettate, in byte (0 = scelta del kernel).
  /// Tiene piccoli i pezzi in cui arriva il corpo di un upload.
  final int receiveBuffer;

  /// MINESYNC_ADDR come scritto (es. `:8084`), per Admin › Sistema.
  final String http;

  /// MINESYNC_DNS_ADDR come scritto (`off` lo spegne); null = default `:53`
  /// se c'è la zona. Lo usa il server DNS.
  final String? dnsAddr;

  /// MINESYNC_DL: cartella dei download e degli aggiornamenti.
  final String? dlDir;

  /// MINESYNC_WEB: build dell'interfaccia web.
  final String? webDir;

  /// TZ.
  final String? timeZone;

  bool get hasZtnet => ztnetUrl != null && ztnetToken != null && ztnetNetwork != null;
}

/// `:8084`, `0.0.0.0:8084`, `[::1]:8084`, `127.0.0.1:9000`.
(InternetAddress, int) parseListenAddress(String s) {
  final i = s.lastIndexOf(':');
  if (i < 0) throw FormatException('MINESYNC_ADDR non valido: $s');
  var host = s.substring(0, i);
  final port = int.tryParse(s.substring(i + 1));
  if (port == null || port < 0 || port > 65535) {
    throw FormatException('MINESYNC_ADDR: porta non valida in $s');
  }
  if (host.startsWith('[') && host.endsWith(']')) host = host.substring(1, host.length - 1);
  if (host.isEmpty) return (InternetAddress.anyIPv6, port);
  final a = InternetAddress.tryParse(host);
  if (a == null) throw FormatException('MINESYNC_ADDR: atteso un indirizzo IP, non $host');
  return (a, port);
}

/// `127.0.0.1=alice,127.0.0.2=bob` → {indirizzo: nome}. Solo indirizzi IPv4
/// di loopback, senza indirizzi o nomi doppi.
Map<String, String> parseDevUsers(String s) {
  final out = <String, String>{};
  final names = <String>{};
  for (final part in s.split(',')) {
    final p = part.trim();
    if (p.isEmpty) continue;
    final eq = p.indexOf('=');
    final ip = eq < 0 ? '' : p.substring(0, eq).trim();
    final name = eq < 0 ? '' : p.substring(eq + 1).trim();
    if (ip.isEmpty || name.isEmpty) {
      throw FormatException('MINESYNC_DEV_USERS: atteso indirizzo=nome, non $p');
    }
    final a = InternetAddress.tryParse(ip);
    if (a == null || a.type != InternetAddressType.IPv4 || !a.isLoopback) {
      throw FormatException('MINESYNC_DEV_USERS: $ip non è un indirizzo di loopback 127.x.y.z');
    }
    if (out.containsKey(a.address)) {
      throw FormatException('MINESYNC_DEV_USERS: indirizzo ripetuto $ip');
    }
    if (!names.add(name.toLowerCase())) {
      throw FormatException('MINESYNC_DEV_USERS: nome ripetuto $name');
    }
    out[a.address] = name;
  }
  if (out.isEmpty) throw const FormatException('MINESYNC_DEV_USERS: elenco vuoto');
  return out;
}
