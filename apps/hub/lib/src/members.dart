// Identità di chi chiama. La rete ZeroTier è l'autenticazione: l'indirizzo
// sorgente del socket (mai le intestazioni inoltrate) si risolve in un
// membro tramite ZTNET. Gli admin vengono da MINESYNC_ADMINS e dai ruoli di
// members.json.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ms_protocol/ms_protocol.dart' show MemberInfo, MemberRole;

import 'clock.dart';
import 'jsonfile.dart';
import 'mutex.dart';

/// Un membro della rete.
final class Identity {
  const Identity(this.id, this.name);

  /// Node id ZeroTier (o un id di sviluppo).
  final String id;
  final String name;

  @override
  bool operator ==(Object other) => other is Identity && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => '$name ($id)';
}

/// Risolve l'indirizzo sorgente in un membro; null = sconosciuto.
abstract interface class IdentityResolver {
  Future<Identity?> resolve(InternetAddress remote);
}

/// Forma canonica di un indirizzo: gli IPv4 mappati in IPv6 (`::ffff:a.b.c.d`,
/// tipici di un socket in ascolto su `::`) tornano IPv4.
String canonicalIp(InternetAddress a) {
  final s = a.address.toLowerCase();
  if (s.startsWith('::ffff:') && s.contains('.')) return s.substring(7);
  return s;
}

/// Vero se l'indirizzo è di loopback (anche IPv4 mappato).
bool isLoopback(InternetAddress a) {
  if (a.isLoopback) return true;
  final s = canonicalIp(a);
  return s.startsWith('127.') || s == '::1';
}

/// Mappa fissa indirizzo → membro (test, configurazioni statiche).
final class StaticResolver implements IdentityResolver {
  StaticResolver(Map<String, Identity> byIp) : byIp = Map.of(byIp);

  /// Modificabile dai test.
  final Map<String, Identity> byIp;

  @override
  Future<Identity?> resolve(InternetAddress remote) async => byIp[canonicalIp(remote)];
}

/// Identità di sviluppo (MINESYNC_DEV_USER): vale solo per chi chiama dal
/// loopback; chiunque altro resta sconosciuto.
final class DevResolver implements IdentityResolver {
  const DevResolver(this.name);
  final String name;

  @override
  Future<Identity?> resolve(InternetAddress remote) async =>
      isLoopback(remote) ? Identity('dev-${name.toLowerCase()}', name) : null;
}

/// Prova i resolver in ordine; vince il primo che riconosce l'indirizzo.
final class ChainResolver implements IdentityResolver {
  const ChainResolver(this.resolvers);
  final List<IdentityResolver> resolvers;

  @override
  Future<Identity?> resolve(InternetAddress remote) async {
    for (final r in resolvers) {
      final id = await r.resolve(remote);
      if (id != null) return id;
    }
    return null;
  }
}

/// Elenco dei membri: indirizzo IP → identità.
typedef MemberFetch = Future<Map<String, Identity>> Function();

/// Un membro come lo elenca ZTNET (anche non autorizzato).
final class ZtMember {
  const ZtMember({
    required this.id,
    required this.name,
    required this.authorized,
    this.ips = const [],
  });

  /// Node id, minuscolo.
  final String id;

  /// Nome in ZTNET; vuoto se non ne ha.
  final String name;
  final bool authorized;
  final List<String> ips;

  Identity get identity => Identity(id, name.isEmpty ? id : name);
}

/// Resolver ZTNET con cache. La prima richiesta aspetta l'elenco; poi si
/// risponde sempre dalla cache e un solo aggiornamento alla volta gira in
/// background ogni [ttl]. Con ZTNET irraggiungibile i membri già noti restano
/// riconosciuti per [grace] (≤ 0 = senza limite); un membro tolto sparisce
/// solo dopo un aggiornamento riuscito. [ttl] e [grace] si possono cambiare
/// mentre gira (Admin › Membri).
final class ZtnetResolver implements IdentityResolver {
  /// Resolver da un elenco indirizzo → identità (tutti autorizzati).
  factory ZtnetResolver(
    MemberFetch fetch, {
    required Clock clock,
    Duration ttl = const Duration(seconds: 30),
    Duration grace = const Duration(hours: 24),
    Duration retryEvery = const Duration(seconds: 5),
    void Function(String)? log,
  }) => ZtnetResolver.roster(
    () async {
      final byId = <String, (Identity, List<String>)>{};
      for (final e in (await fetch()).entries) {
        final cur = byId[e.value.id];
        byId[e.value.id] = (e.value, [...?cur?.$2, e.key]);
      }
      return [
        for (final v in byId.values)
          ZtMember(id: v.$1.id, name: v.$1.name, authorized: true, ips: v.$2),
      ];
    },
    clock: clock,
    ttl: ttl,
    grace: grace,
    retryEvery: retryEvery,
    log: log,
  );

  /// Resolver dall'elenco completo dei membri di ZTNET.
  ZtnetResolver.roster(
    this._fetch, {
    required Clock clock,
    this.ttl = const Duration(seconds: 30),
    this.grace = const Duration(hours: 24),
    this.retryEvery = const Duration(seconds: 5),
    this.log,
  }) : _clock = clock;

  /// Resolver che legge i membri dall'API di ZTNET.
  factory ZtnetResolver.http({
    required String url,
    required String token,
    required String networkId,
    required Clock clock,
    void Function(String)? log,
  }) {
    final base = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    Future<List<ZtMember>> fetch() async {
      final req = await client.getUrl(Uri.parse('$base/api/v1/network/$networkId/member'));
      req.headers.set('x-ztnet-auth', token);
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw HttpException('ZTNET HTTP ${res.statusCode}');
      }
      final bytes = <int>[];
      await for (final c in res.timeout(const Duration(seconds: 8))) {
        bytes.addAll(c);
        if (bytes.length > 8 << 20) throw const HttpException('ZTNET: risposta troppo grande');
      }
      return parseZtnetRoster(jsonDecode(utf8.decode(bytes)));
    }

    return ZtnetResolver.roster(fetch, clock: clock, log: log);
  }

  final Future<List<ZtMember>> Function() _fetch;
  final Clock _clock;
  Duration ttl;
  Duration grace;
  final Duration retryEvery;
  final void Function(String)? log;

  /// Chiamata a ogni passaggio ok ↔ errore (evento `ztnet`).
  void Function(bool down, String? error)? onChange;

  Map<String, Identity> _byIp = const {};
  List<ZtMember>? _roster;
  int? _fetchedAt;
  int? _lastTry;
  Future<void>? _refreshing;
  bool _down = false;

  /// ZTNET non risponde (l'ultimo aggiornamento è fallito).
  bool get down => _down;

  /// Aggiornamenti tentati (per i test).
  int fetches = 0;

  /// Ultimo aggiornamento riuscito (ora di parete).
  int? lastRefresh;

  /// Ultimo errore, anche dopo che è rientrato, e quando.
  String? lastError;
  int? lastErrorAt;

  /// L'ultimo elenco completo ricevuto (null finché non ne arriva uno).
  List<ZtMember>? get roster => _roster;

  /// Membri autorizzati nell'ultimo elenco.
  int get authorizedCount => _roster?.where((m) => m.authorized).length ?? 0;

  @override
  Future<Identity?> resolve(InternetAddress remote) async {
    final fetched = _fetchedAt;
    if (fetched == null) {
      await _refresh();
    } else if (_clock.monoMs() - fetched > ttl.inMilliseconds) {
      unawaited(_refresh());
    }
    final at = _fetchedAt;
    if (at == null) return null;
    if (grace > Duration.zero && _clock.monoMs() - at > grace.inMilliseconds) return null;
    return _byIp[canonicalIp(remote)];
  }

  /// Un aggiornamento subito («Controlla ora»), unito a quello in corso.
  Future<void> refreshNow() {
    final running = _refreshing;
    if (running != null) return running;
    _lastTry = null;
    return _refresh();
  }

  Future<void> _refresh() {
    final running = _refreshing;
    if (running != null) return running;
    final last = _lastTry;
    if (last != null && _clock.monoMs() - last < retryEvery.inMilliseconds) {
      return Future.value();
    }
    _lastTry = _clock.monoMs();
    fetches++;
    final f = _doRefresh();
    _refreshing = f;
    return f.whenComplete(() => _refreshing = null);
  }

  Future<void> _doRefresh() async {
    try {
      final fresh = await _fetch();
      final byIp = <String, Identity>{};
      for (final m in fresh) {
        if (!m.authorized) continue;
        for (final ip in m.ips) {
          byIp[ip.toLowerCase()] = m.identity;
        }
      }
      final was = _down;
      if (was) log?.call('ztnet: di nuovo raggiungibile (${byIp.length} indirizzi)');
      _byIp = byIp;
      _roster = List.unmodifiable(fresh);
      _fetchedAt = _clock.monoMs();
      lastRefresh = _clock.wallMs();
      _down = false;
      if (was) onChange?.call(false, null);
    } catch (e) {
      final msg = '$e';
      lastError = msg.length > 300 ? msg.substring(0, 300) : msg;
      lastErrorAt = _clock.wallMs();
      if (!_down) {
        log?.call('ztnet: irraggiungibile ($e), resto sui ${_byIp.length} indirizzi noti');
        _down = true;
        onChange?.call(true, lastError);
      }
    }
  }
}

/// Il primo [ZtnetResolver] dentro [r] (anche in una catena), o null.
ZtnetResolver? findZtnet(IdentityResolver r) => switch (r) {
  final ZtnetResolver z => z,
  final ChainResolver c => c.resolvers.map(findZtnet).nonNulls.firstOrNull,
  _ => null,
};

/// Decodifica l'elenco dei membri di ZTNET, anche quelli non autorizzati.
List<ZtMember> parseZtnetRoster(Object? json) {
  if (json is! List<Object?>) throw const FormatException('ZTNET: attesa una lista di membri');
  final out = <ZtMember>[];
  for (final m in json) {
    if (m is! Map<String, Object?>) continue;
    var id = (m['id'] as String? ?? '').toLowerCase();
    if (id.isEmpty) id = (m['address'] as String? ?? '').toLowerCase();
    if (id.isEmpty) continue;
    out.add(
      ZtMember(
        id: id,
        name: (m['name'] as String? ?? '').trim(),
        authorized: m['authorized'] != false,
        ips: [
          for (final ip in (m['ipAssignments'] as List<Object?>? ?? const []))
            if (ip is String && ip.isNotEmpty) ip.toLowerCase(),
        ],
      ),
    );
  }
  return out;
}

/// Decodifica l'elenco dei membri di ZTNET: solo i membri autorizzati, ogni
/// indirizzo assegnato porta all'identità (node id, nome o id se senza nome).
Map<String, Identity> parseZtnetMembers(Object? json) => {
  for (final m in parseZtnetRoster(json))
    if (m.authorized)
      for (final ip in m.ips) ip: m.identity,
};

/// Ruolo di un membro.
enum Role { member, admin }

/// Registro dei membri visti (members.json) e regola degli admin.
final class Members {
  Members(this.path, {Iterable<String> admins = const [], required Clock clock})
    : _admins = {for (final a in admins) a.trim().toLowerCase()}..remove(''),
      _clock = clock;

  final String path;
  final Set<String> _admins;
  final Clock _clock;
  final _records = <String, Map<String, Object?>>{};
  final _io = Mutex();
  bool _dirty = false;
  Future<void>? _pending;

  /// Ogni quanto si salva solo un "visto alle".
  static const _seenEvery = Duration(minutes: 10);

  Future<void> load() async {
    final j = await tryReadJsonFile(path);
    final m = j is Map<String, Object?> ? j['members'] : null;
    if (m is Map<String, Object?>) {
      for (final e in m.entries) {
        if (e.value is Map<String, Object?>) {
          _records[e.key] = Map.of(e.value! as Map<String, Object?>);
        }
      }
    }
  }

  bool isAdmin(Identity who) =>
      fromConfig(who.id, who.name) || _records[who.id]?['role'] == Role.admin.name;

  /// Admin da MINESYNC_ADMINS (nome o node id, senza maiuscole).
  bool fromConfig(String id, String name) =>
      _admins.contains(name.toLowerCase()) || _admins.contains(id.toLowerCase());

  /// MINESYNC_ADMINS come configurato (minuscolo).
  List<String> get configAdmins => _admins.toList();

  /// Cambia il ruolo di [id] e lo salva subito. Un membro elencato da ZTNET
  /// ma mai visto dall'hub viene registrato con [name].
  Future<void> setRole(String id, String name, Role role) async {
    final r = _records.putIfAbsent(id, () => {'name': name});
    r['role'] = role.name;
    _schedule();
    await flush();
  }

  /// Registra che [who] ha fatto una richiesta. Salva subito i membri nuovi
  /// e i cambi di nome, il resto al più ogni dieci minuti.
  void seen(Identity who) {
    final now = _clock.wallMs();
    final r = _records[who.id];
    if (r == null) {
      _records[who.id] = {
        'name': who.name,
        'role': Role.member.name,
        'firstSeen': now,
        'lastSeen': now,
      };
    } else {
      final last = r['lastSeen'];
      final changed = r['name'] != who.name;
      if (!changed && last is int && now - last < _seenEvery.inMilliseconds) return;
      r['name'] = who.name;
      r['lastSeen'] = now;
    }
    _schedule();
  }

  void _schedule() {
    _dirty = true;
    _pending ??= _io.run(() async {
      _pending = null;
      if (!_dirty) return;
      _dirty = false;
      await writeJsonAtomic(path, {'members': _records}, mode: 0x180);
    });
  }

  /// Aspetta la scrittura in corso (spegnimento, test).
  Future<void> flush() async {
    await _pending;
    await _io.run(() {});
  }

  Map<String, Map<String, Object?>> get records => Map.unmodifiable(_records);

  /// I membri visti uniti all'elenco di ZTNET [roster] (anche i non
  /// autorizzati). Ordine: admin, poi i visti più di recente, poi per nome.
  List<MemberInfo> list(List<ZtMember>? roster) {
    final byId = {for (final z in roster ?? const <ZtMember>[]) z.id: z};
    final out = <MemberInfo>[];
    MemberInfo info(String id, String name, int? lastSeen) {
      final z = byId[id];
      final admin = isAdmin(Identity(id, name));
      return MemberInfo(
        id: id,
        name: name,
        role: admin ? MemberRole.admin : MemberRole.member,
        ip: z?.ips.firstOrNull,
        lastSeen: lastSeen,
        fromConfig: fromConfig(id, name),
        // con l'elenco di ZTNET in mano, chi non c'è (o non è autorizzato)
        // non può entrare
        authorized: roster == null || (z?.authorized ?? false),
      );
    }

    for (final e in _records.entries) {
      final z = byId[e.key];
      final name = z != null && z.name.isNotEmpty ? z.name : (e.value['name'] as String? ?? '');
      final last = e.value['lastSeen'];
      out.add(info(e.key, name, last is int ? last : null));
    }
    for (final z in byId.values) {
      if (_records.containsKey(z.id)) continue;
      out.add(info(z.id, z.name, null));
    }
    out.sort((a, b) {
      if (a.role != b.role) return a.role == MemberRole.admin ? -1 : 1;
      final la = a.lastSeen ?? -1, lb = b.lastSeen ?? -1;
      if (la != lb) return lb.compareTo(la);
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }
}
