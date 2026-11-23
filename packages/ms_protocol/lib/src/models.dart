// Modelli dell'API v1. Decodifica stretta: un campo obbligatorio mancante o
// del tipo sbagliato è un FormatException, mai un valore inventato.
import 'admin.dart';
import 'event_types.dart';
import 'json.dart';
import 'manifest.dart';

/// Versione dell'API servita sotto /api/v1.
const int apiVersion = 1;

/// Intestazione obbligatoria sulle richieste che cambiano stato.
const String csrfHeader = 'X-MineSync';

/// Profilo di uno spazio.
enum Profile {
  minecraft,
  generic;

  static Profile parse(Object? v) => switch (v) {
    'minecraft' => minecraft,
    'generic' => generic,
    _ => throw FormatException('profilo sconosciuto: $v'),
  };
}

/// Chi chiama.
final class Me {
  const Me({required this.id, required this.name, required this.admin});

  factory Me.fromJson(Object? j) {
    final m = obj(j, 'me');
    return Me(id: str(m, 'id'), name: str(m, 'name'), admin: m['admin'] == true);
  }

  /// Node id ZeroTier.
  final String id;
  final String name;
  final bool admin;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'admin': admin};
}

/// Spazio su disco dell'hub, in byte.
final class DiskInfo {
  const DiskInfo({required this.free, required this.total, required this.minFree});

  factory DiskInfo.fromJson(Object? j) {
    final m = obj(j, 'disk');
    return DiskInfo(
      free: integer(m, 'free'),
      total: integer(m, 'total'),
      minFree: integer(m, 'minFree'),
    );
  }

  final int free;
  final int total;

  /// Sotto questa soglia l'hub rifiuta i salvataggi.
  final int minFree;

  Map<String, Object?> toJson() => {'free': free, 'total': total, 'minFree': minFree};
}

/// `GET /hub`.
final class HubInfo {
  const HubInfo({
    required this.name,
    required this.version,
    required this.api,
    required this.time,
    required this.disk,
    required this.me,
    this.language = 'auto',
    this.dnsZone,
  });

  factory HubInfo.fromJson(Object? j) {
    final m = obj(j, 'hub');
    return HubInfo(
      name: str(m, 'name'),
      version: str(m, 'version'),
      api: integer(m, 'api'),
      time: integer(m, 'time'),
      disk: DiskInfo.fromJson(m['disk']),
      me: Me.fromJson(m['me']),
      language: optStr(m, 'language') ?? 'auto',
      dnsZone: optStr(m, 'dnsZone'),
    );
  }

  final String name;
  final String version;
  final int api;

  /// Lingua predefinita dei messaggi (Admin › Generale): `auto`, `it`, `en`.
  final String language;

  /// Zona DNS dei server, se il DNS integrato è attivo.
  final String? dnsZone;

  /// Ora dell'hub in millisecondi dall'epoch.
  final int time;
  final DiskInfo disk;
  final Me me;

  Map<String, Object?> toJson() => {
    'name': name,
    'version': version,
    'api': api,
    'time': time,
    'disk': disk.toJson(),
    'me': me.toJson(),
    'language': language,
    if (dnsZone != null) 'dnsZone': dnsZone,
  };
}

/// Informazioni che chi ospita pubblica con il lock.
final class LockInfo {
  const LockInfo({
    this.client = '',
    this.action,
    this.players = const [],
    this.port,
    this.address,
    this.lan,
  });

  factory LockInfo.fromJson(Object? j) {
    if (j == null) return const LockInfo();
    final m = obj(j, 'info');
    return LockInfo(
      client: m['client'] as String? ?? '',
      action: m['action'] as String?,
      players: [for (final p in (m['players'] as List<Object?>? ?? const [])) p as String],
      port: m['port'] as int?,
      address: m['address'] as String?,
      lan: optStr(m, 'lan'),
    );
  }

  /// Versione del client che ospita.
  final String client;

  /// Cosa sta facendo chi tiene il lock: `play` (sessione di gioco) o `push`.
  final String? action;
  final List<String> players;
  final int? port;
  final String? address;

  /// Indirizzo LAN di chi ospita, solo per il DNS a orizzonte diviso: l'hub
  /// lo tiene per sé e non lo restituisce mai nelle risposte.
  final String? lan;

  /// Copia senza l'indirizzo LAN, come la serve l'hub.
  LockInfo public() => lan == null
      ? this
      : LockInfo(client: client, action: action, players: players, port: port, address: address);

  Map<String, Object?> toJson() => {
    'client': client,
    'action': ?action,
    'players': players,
    if (port != null) 'port': port,
    if (address != null) 'address': address,
    if (lan != null) 'lan': lan,
  };
}

/// Stato del lock di uno spazio, se qualcuno lo tiene.
final class LockHolder {
  const LockHolder({
    required this.memberId,
    required this.name,
    required this.since,
    required this.lastBeat,
    required this.stale,
    required this.info,
    this.ip,
    this.portCheck,
  });

  factory LockHolder.fromJson(Object? j) {
    final m = obj(j, 'lock');
    return LockHolder(
      memberId: str(m, 'memberId'),
      name: str(m, 'name'),
      since: integer(m, 'since'),
      lastBeat: integer(m, 'lastBeat'),
      stale: m['stale'] == true,
      info: LockInfo.fromJson(m['info']),
      ip: optStr(m, 'ip'),
      portCheck: m['portCheck'] == null ? null : PortCheck.fromJson(m['portCheck']),
    );
  }

  final String memberId;
  final String name;
  final int since;
  final int lastBeat;

  /// Heartbeat perso oltre il TTL: chiunque può prendere il lock.
  final bool stale;
  final LockInfo info;

  /// Indirizzo da cui l'hub vede chi ospita (il socket, mai un valore del
  /// client): è l'«IP diretto» e la risposta del DNS.
  final String? ip;

  /// Ultima prova della porta di gioco fatta dall'hub.
  final PortCheck? portCheck;

  Map<String, Object?> toJson() => {
    'memberId': memberId,
    'name': name,
    'since': since,
    'lastBeat': lastBeat,
    'stale': stale,
    'info': info.toJson(),
    if (ip != null) 'ip': ip,
    if (portCheck != null) 'portCheck': portCheck!.toJson(),
  };
}

/// Esito della prova della porta di chi ospita.
enum PortState {
  /// Prova in corso o non ancora fatta.
  pending,
  reachable,
  blocked,

  /// Prova spenta (Admin › Sessioni) o lock di solo push.
  off;

  static PortState parse(Object? v) => enumOf(values, v, 'stato della porta');
}

/// Prova della porta: l'hub apre una connessione TCP verso [LockHolder.ip]
/// sulla porta pubblicata, mai verso un host scelto dal client.
final class PortCheck {
  const PortCheck({required this.state, this.port, this.checkedAt});

  factory PortCheck.fromJson(Object? j) {
    final m = obj(j, 'portCheck');
    return PortCheck(
      state: PortState.parse(m['state']),
      port: optInt(m, 'port'),
      checkedAt: optInt(m, 'checkedAt'),
    );
  }

  final PortState state;
  final int? port;

  /// Fine dell'ultima prova (ms dall'epoch); null finché è `pending`.
  final int? checkedAt;

  Map<String, Object?> toJson() => {
    'state': state.name,
    if (port != null) 'port': port,
    if (checkedAt != null) 'checkedAt': checkedAt,
  };
}

/// Lock concesso.
final class LockGrant {
  const LockGrant({required this.token, required this.ttlMs, required this.heartbeatMs});

  factory LockGrant.fromJson(Object? j) {
    final m = obj(j, 'grant');
    return LockGrant(
      token: str(m, 'token'),
      ttlMs: integer(m, 'ttlMs'),
      heartbeatMs: integer(m, 'heartbeatMs'),
    );
  }

  final String token;
  final int ttlMs;
  final int heartbeatMs;

  Map<String, Object?> toJson() => {'token': token, 'ttlMs': ttlMs, 'heartbeatMs': heartbeatMs};
}

enum GenerationKind {
  push,
  autosave,
  restore;

  static GenerationKind parse(Object? v) => values.firstWhere(
    (k) => k.name == v,
    orElse: () => throw FormatException('tipo di generazione sconosciuto: $v'),
  );
}

/// Conteggi di una generazione rispetto alla precedente.
final class GenerationStats {
  const GenerationStats({
    required this.files,
    required this.size,
    this.added = 0,
    this.changed = 0,
    this.removed = 0,
  });

  factory GenerationStats.fromJson(Object? j) {
    final m = obj(j, 'stats');
    return GenerationStats(
      files: integer(m, 'files'),
      size: integer(m, 'size'),
      added: m['added'] as int? ?? 0,
      changed: m['changed'] as int? ?? 0,
      removed: m['removed'] as int? ?? 0,
    );
  }

  final int files;
  final int size;
  final int added;
  final int changed;
  final int removed;

  Map<String, Object?> toJson() => {
    'files': files,
    'size': size,
    'added': added,
    'changed': changed,
    'removed': removed,
  };
}

/// Riassunto di una generazione (senza manifest).
final class GenerationSummary {
  const GenerationSummary({
    required this.n,
    required this.parent,
    required this.digest,
    required this.authorId,
    required this.author,
    required this.message,
    required this.ts,
    required this.kind,
    required this.stats,
    this.restoredFrom,
    this.restoredPath,
    this.damaged = const [],
  });

  factory GenerationSummary.fromJson(Object? j) {
    final m = obj(j, 'generation');
    return GenerationSummary(
      n: integer(m, 'n'),
      parent: integer(m, 'parent'),
      digest: str(m, 'digest'),
      authorId: str(m, 'authorId'),
      author: str(m, 'author'),
      message: m['message'] as String? ?? '',
      ts: integer(m, 'ts'),
      kind: GenerationKind.parse(m['kind']),
      stats: GenerationStats.fromJson(m['stats']),
      restoredFrom: m['restoredFrom'] as int?,
      restoredPath: optStr(m, 'restoredPath'),
      damaged: optListOf(m, 'damaged', DamagedFile.fromJson),
    );
  }

  /// Numero, da 1. Lo spazio vuoto è la generazione 0.
  final int n;
  final int parent;
  final String digest;
  final String authorId;
  final String author;
  final String message;
  final int ts;
  final GenerationKind kind;
  final GenerationStats stats;
  final int? restoredFrom;

  /// Con restore-file: l'unico file ripreso da [restoredFrom].
  final String? restoredPath;

  /// File segnalati danneggiati dal client al momento del push (B-GEN-11).
  final List<DamagedFile> damaged;

  Map<String, Object?> toJson() => {
    'n': n,
    'parent': parent,
    'digest': digest,
    'authorId': authorId,
    'author': author,
    'message': message,
    'ts': ts,
    'kind': kind.name,
    'stats': stats.toJson(),
    if (restoredFrom != null) 'restoredFrom': restoredFrom,
    if (restoredPath != null) 'restoredPath': restoredPath,
    if (damaged.isNotEmpty) 'damaged': [for (final d in damaged) d.toJson()],
  };
}

/// Un file del mondo che il client ha trovato danneggiato (es. un file
/// region con chunk illeggibili). Viaggia con il push e resta nella
/// generazione.
final class DamagedFile {
  const DamagedFile({required this.path, this.bad, this.total});

  factory DamagedFile.fromJson(Object? j) {
    final m = obj(j, 'damaged');
    return DamagedFile(path: str(m, 'path'), bad: optInt(m, 'bad'), total: optInt(m, 'total'));
  }

  final String path;

  /// Chunk illeggibili e chunk presenti, se il formato li conta.
  final int? bad;
  final int? total;

  Map<String, Object?> toJson() => {
    'path': path,
    if (bad != null) 'bad': bad,
    if (total != null) 'total': total,
  };
}

/// Una generazione completa.
final class Generation {
  const Generation(this.summary, this.manifest);

  factory Generation.fromJson(Object? j) {
    final m = obj(j, 'generation');
    return Generation(GenerationSummary.fromJson(m), Manifest.fromJson(m['manifest']));
  }

  final GenerationSummary summary;
  final Manifest manifest;

  int get n => summary.n;
  String get digest => summary.digest;

  Map<String, Object?> toJson() => {...summary.toJson(), 'manifest': manifest.toJson()};
}

/// La testa di uno spazio vuoto: generazione 0, manifest vuoto.
final String emptyDigest = Manifest.empty.digest();

/// Riassunto di uno spazio.
final class SpaceSummary {
  const SpaceSummary({
    required this.id,
    required this.name,
    required this.profile,
    required this.createdAt,
    required this.head,
    required this.lock,
    this.dnsName,
    this.world,
    this.lastSession,
  });

  factory SpaceSummary.fromJson(Object? j) {
    final m = obj(j, 'space');
    return SpaceSummary(
      id: str(m, 'id'),
      name: str(m, 'name'),
      profile: Profile.parse(m['profile']),
      createdAt: integer(m, 'createdAt'),
      head: m['head'] == null ? null : GenerationSummary.fromJson(m['head']),
      lock: m['lock'] == null ? null : LockHolder.fromJson(m['lock']),
      dnsName: optStr(m, 'dnsName'),
      world: m['world'] == null ? null : WorldChip.fromJson(m['world']),
      lastSession: m['lastSession'] == null ? null : SessionRecord.fromJson(m['lastSession']),
    );
  }

  final String id;
  final String name;
  final Profile profile;
  final int createdAt;

  /// null finché nessuno ha mai salvato.
  final GenerationSummary? head;
  final LockHolder? lock;

  /// `zerotier.<id>.<zona>`, solo con il DNS integrato attivo (B-DNS-01).
  final String? dnsName;

  /// Versione di Minecraft, loader e numero di mod della HEAD.
  final WorldChip? world;

  /// L'ultima sessione di gioco finita.
  final SessionRecord? lastSession;

  int get headN => head?.n ?? 0;
  String get headDigest => head?.digest ?? emptyDigest;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'profile': profile.name,
    'createdAt': createdAt,
    'head': head?.toJson(),
    'lock': lock?.toJson(),
    if (dnsName != null) 'dnsName': dnsName,
    if (world != null) 'world': world!.toJson(),
    if (lastSession != null) 'lastSession': lastSession!.toJson(),
  };
}

/// Loader del server.
enum Loader {
  vanilla,
  fabric,
  quilt,
  forge,
  neoforge,
  paper;

  static Loader parse(Object? v) => enumOf(values, v, 'loader');
}

/// Riassunto del mondo nella HEAD per le card: «Minecraft 1.21.1 · Fabric ·
/// 42 mod». Calcolato dall'hub e tenuto in cache per generazione.
final class WorldChip {
  const WorldChip({this.mcVersion, this.loader, this.loaderVersion, this.mods = 0});

  factory WorldChip.fromJson(Object? j) {
    final m = obj(j, 'world');
    return WorldChip(
      mcVersion: optStr(m, 'mcVersion'),
      loader: m['loader'] == null ? null : Loader.parse(m['loader']),
      loaderVersion: optStr(m, 'loaderVersion'),
      mods: optInt(m, 'mods') ?? 0,
    );
  }

  final String? mcVersion;

  /// null se l'hub non lo riconosce.
  final Loader? loader;
  final String? loaderVersion;
  final int mods;

  Map<String, Object?> toJson() => {
    if (mcVersion != null) 'mcVersion': mcVersion,
    if (loader != null) 'loader': loader!.name,
    if (loaderVersion != null) 'loaderVersion': loaderVersion,
    'mods': mods,
  };
}

/// Come è finita una sessione.
enum SessionEnd {
  /// Ancora in corso.
  ongoing,
  released,

  /// Lock diventato stale e mai più rinnovato.
  stale,
  forced;

  static SessionEnd parse(Object? v) => enumOf(values, v, 'fine della sessione');
}

/// Una sessione di gioco, registrata dall'hub dal lock `play` (presa →
/// rilascio). I push manuali non sono sessioni.
final class SessionRecord {
  const SessionRecord({
    required this.memberId,
    required this.name,
    required this.start,
    this.end,
    this.ended = SessionEnd.ongoing,
    this.players = const {},
  });

  factory SessionRecord.fromJson(Object? j) {
    final m = obj(j, 'session');
    return SessionRecord(
      memberId: str(m, 'memberId'),
      name: str(m, 'name'),
      start: integer(m, 'start'),
      end: optInt(m, 'end'),
      ended: SessionEnd.parse(m['ended']),
      players: intMap(m, 'players'),
    );
  }

  /// Chi ha ospitato.
  final String memberId;
  final String name;
  final int start;

  /// null finché è in corso; per una sessione stale è l'ultimo heartbeat.
  final int? end;
  final SessionEnd ended;

  /// Giocatore Minecraft → millisecondi in gioco in questa sessione
  /// (campionati dagli heartbeat).
  final Map<String, int> players;

  Map<String, Object?> toJson() => {
    'memberId': memberId,
    'name': name,
    'start': start,
    if (end != null) 'end': end,
    'ended': ended.name,
    if (players.isNotEmpty) 'players': players,
  };
}

/// Dettaglio di uno spazio.
final class SpaceDetails {
  const SpaceDetails(
    this.summary, {
    required this.exclusions,
    required this.ownExclusions,
    this.profileExclusions = const [],
    this.settings,
    this.inherited,
    this.overrides = const {},
    this.usage,
  });

  factory SpaceDetails.fromJson(Object? j) {
    final m = obj(j, 'space');
    return SpaceDetails(
      SpaceSummary.fromJson(m),
      exclusions: strings(m, 'exclusions'),
      ownExclusions: strings(m, 'ownExclusions'),
      profileExclusions: strings(m, 'profileExclusions'),
      settings: m['settings'] == null ? null : SpaceSettings.fromJson(m['settings']),
      inherited: m['inherited'] == null ? null : SpaceSettings.fromJson(m['inherited']),
      overrides: optObj(m, 'overrides') ?? const {},
      usage: m['usage'] == null ? null : SpaceUsage.fromJson(m['usage']),
    );
  }

  final SpaceSummary summary;

  /// Esclusioni effettive: quelle predefinite del profilo più le proprie.
  final List<String> exclusions;

  /// Esclusioni aggiunte a questo spazio.
  final List<String> ownExclusions;

  /// Esclusioni ereditate dal profilo (Admin › Esclusioni), senza quelle di
  /// sistema ([systemExclusions]).
  final List<String> profileExclusions;

  /// Valori effettivi delle sezioni sovrascrivibili.
  final SpaceSettings? settings;

  /// Valori globali delle stesse sezioni: quelli che lo spazio eredita.
  final SpaceSettings? inherited;

  /// Sovrascritture proprie, campi parziali: `{sessions: {...}, history:
  /// {...}, protection: {...}}`.
  final Map<String, Object?> overrides;

  /// Spazio su disco occupato (calcolato in background; null se non pronto).
  final SpaceUsage? usage;

  Map<String, Object?> toJson() => {
    ...summary.toJson(),
    'exclusions': exclusions,
    'ownExclusions': ownExclusions,
    if (profileExclusions.isNotEmpty) 'profileExclusions': profileExclusions,
    if (settings != null) 'settings': settings!.toJson(),
    if (inherited != null) 'inherited': inherited!.toJson(),
    if (overrides.isNotEmpty) 'overrides': overrides,
    if (usage != null) 'usage': usage!.toJson(),
  };
}

/// `POST /spaces/{id}/pushes`.
final class PushBegin {
  const PushBegin({
    required this.parent,
    required this.parentDigest,
    required this.lockToken,
    required this.manifest,
    this.message = '',
    this.kind = GenerationKind.push,
    this.confirmMassDelete = false,
    this.damaged = const [],
  });

  factory PushBegin.fromJson(Object? j) {
    final m = obj(j, 'push');
    return PushBegin(
      parent: integer(m, 'parent'),
      parentDigest: str(m, 'parentDigest'),
      lockToken: str(m, 'lockToken'),
      manifest: Manifest.fromJson(m['manifest']),
      message: m['message'] as String? ?? '',
      kind: m['kind'] == null ? GenerationKind.push : GenerationKind.parse(m['kind']),
      confirmMassDelete: m['confirmMassDelete'] == true,
      damaged: optListOf(m, 'damaged', DamagedFile.fromJson),
    );
  }

  final int parent;
  final String parentDigest;
  final String lockToken;
  final Manifest manifest;
  final String message;
  final GenerationKind kind;
  final bool confirmMassDelete;

  /// File del manifest trovati danneggiati dal client (B-GEN-11).
  final List<DamagedFile> damaged;

  Map<String, Object?> toJson() => {
    'parent': parent,
    'parentDigest': parentDigest,
    'lockToken': lockToken,
    'message': message,
    'kind': kind.name,
    if (confirmMassDelete) 'confirmMassDelete': true,
    if (damaged.isNotEmpty) 'damaged': [for (final d in damaged) d.toJson()],
    'manifest': manifest.toJson(),
  };
}

/// Risposta a [PushBegin].
final class PushStarted {
  const PushStarted({required this.pushId, required this.missing});

  factory PushStarted.fromJson(Object? j) {
    final m = obj(j, 'push');
    return PushStarted(pushId: str(m, 'pushId'), missing: strings(m, 'missing'));
  }

  final String pushId;

  /// Blob che l'hub non ha e vanno caricati.
  final List<String> missing;

  Map<String, Object?> toJson() => {'pushId': pushId, 'missing': missing};
}

/// Un evento dell'hub.
final class HubEvent {
  const HubEvent({
    required this.seq,
    required this.ts,
    required this.type,
    this.space,
    this.actor,
    this.data = const {},
  });

  factory HubEvent.fromJson(Object? j) {
    final m = obj(j, 'event');
    final d = m['data'];
    return HubEvent(
      seq: integer(m, 'seq'),
      ts: integer(m, 'ts'),
      type: str(m, 'type'),
      space: m['space'] as String?,
      actor: m['actor'] as String?,
      data: d is Map<String, Object?> ? d : const {},
    );
  }

  final int seq;
  final int ts;

  /// Uno dei nomi di [EventType].
  final String type;
  final String? space;
  final String? actor;
  final Map<String, Object?> data;

  Map<String, Object?> toJson() => {
    'seq': seq,
    'ts': ts,
    'type': type,
    if (space != null) 'space': space,
    if (actor != null) 'actor': actor,
    if (data.isNotEmpty) 'data': data,
  };
}

// Helper di decodifica condivisi.

Map<String, Object?> obj(Object? v, String what) =>
    v is Map<String, Object?> ? v : throw FormatException('$what: atteso un oggetto');

String str(Map<String, Object?> m, String k) {
  final v = m[k];
  return v is String ? v : throw FormatException('$k: attesa una stringa');
}

int integer(Map<String, Object?> m, String k) {
  final v = m[k];
  return v is int ? v : throw FormatException('$k: atteso un intero');
}

List<String> strings(Map<String, Object?> m, String k) {
  final v = m[k];
  if (v == null) return const [];
  if (v is! List<Object?>) throw FormatException('$k: attesa una lista');
  return [for (final s in v) s is String ? s : throw FormatException('$k: attese stringhe')];
}

/// Messaggi riservati dei caricamenti automatici della sessione: le app li
/// mostrano tradotti nella lingua di chi legge (ms_l10n `autoMessage`).
abstract final class AutoMessage {
  /// Caricamento finale alla chiusura del server.
  static const sessionEnd = '@session-end';

  /// Modifiche locali rimaste da una sessione precedente, caricate prima di
  /// avviare il server.
  static const recovered = '@recovered';

  /// Stato salvato dopo un crash del server.
  static const afterCrash = '@after-crash';

  static const all = [sessionEnd, recovered, afterCrash];
}
