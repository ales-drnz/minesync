// Stato in memoria dell'hub: descrittore e testa di ogni spazio, lock,
// sessioni di push. Le forme su disco (space.json, lock.json, pushes/*.json)
// sono definite qui accanto alle classi.
import 'dart:collection';
import 'dart:math' show max;

import 'package:ms_protocol/ms_protocol.dart';

import 'clock.dart';
import 'mutex.dart';

/// space.json.
final class SpaceMeta {
  SpaceMeta({
    required this.id,
    required this.name,
    required this.profile,
    required this.createdAt,
    List<String> exclusions = const [],
    Map<String, Object?> overrides = const {},
  }) : exclusions = List.unmodifiable(exclusions),
       overrides = Map.unmodifiable(overrides);

  factory SpaceMeta.fromJson(Object? j) {
    if (j is! Map<String, Object?>) throw const FormatException('space.json: atteso un oggetto');
    final id = j['id'], name = j['name'], created = j['createdAt'];
    if (id is! String || name is! String || created is! int) {
      throw const FormatException('space.json: campi mancanti');
    }
    final ex = j['exclusions'];
    final ov = j['overrides'];
    return SpaceMeta(
      id: id,
      name: name,
      profile: Profile.parse(j['profile']),
      createdAt: created,
      exclusions: ex is List<Object?> ? [for (final e in ex) e is String ? e : '$e'] : const [],
      overrides: ov is Map<String, Object?> ? ov : const {},
    );
  }

  final String id;
  final String name;
  final Profile profile;
  final int createdAt;

  /// Esclusioni proprie dello spazio (oltre a quelle del profilo).
  final List<String> exclusions;

  /// Impostazioni sovrascritte per questo spazio (sezioni sessions, history e
  /// protection, campi parziali).
  final Map<String, Object?> overrides;

  SpaceMeta copyWith({String? name, List<String>? exclusions, Map<String, Object?>? overrides}) =>
      SpaceMeta(
        id: id,
        name: name ?? this.name,
        profile: profile,
        createdAt: createdAt,
        exclusions: exclusions ?? this.exclusions,
        overrides: overrides ?? this.overrides,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'profile': profile.name,
    'createdAt': createdAt,
    'exclusions': exclusions,
    'overrides': overrides,
  };
}

/// Lock di uno spazio. Le scadenze usano l'orologio monotono; l'ora di
/// parete serve solo a mostrare da quando.
final class LockState {
  LockState({
    required this.token,
    required this.memberId,
    required this.name,
    required this.since,
    required this.lastBeat,
    required this.lastBeatMono,
    required this.info,
    this.ip,
  });

  /// Dal lock.json salvato. Dopo un riavvio il tempo monotono riparte: un
  /// lock vivo riprende come appena rinnovato, così chi lo tiene ha un TTL
  /// intero per rifarsi vivo; uno che non rispondeva già prima dello
  /// spegnimento resta così, con il suo ultimo battito e senza un nuovo
  /// evento `stale`.
  factory LockState.fromJson(Object? j, Clock clock, Duration ttl) {
    if (j is! Map<String, Object?>) throw const FormatException('lock.json: atteso un oggetto');
    final token = j['token'], member = j['memberId'], name = j['name'], since = j['since'];
    if (token is! String || member is! String || name is! String || since is! int) {
      throw const FormatException('lock.json: campi mancanti');
    }
    final beat = j['lastBeat'];
    if (j['stale'] == true && beat is int) {
      // silenzio già oltre il TTL: la scadenza resta passata anche sul nuovo
      // orologio monotono
      final silent = max(ttl.inMilliseconds + 1, clock.wallMs() - beat);
      return LockState(
        token: token,
        memberId: member,
        name: name,
        since: since,
        lastBeat: beat,
        lastBeatMono: clock.monoMs() - silent,
        info: LockInfo.fromJson(j['info']),
        ip: j['ip'] is String ? j['ip'] as String : null,
      )..staleNotified = true;
    }
    return LockState(
      token: token,
      memberId: member,
      name: name,
      since: since,
      lastBeat: clock.wallMs(),
      lastBeatMono: clock.monoMs(),
      info: LockInfo.fromJson(j['info']),
      ip: j['ip'] is String ? j['ip'] as String : null,
    );
  }

  final String token;
  final String memberId;

  /// Solo un'etichetta: l'autorità è il token.
  String name;
  final int since;
  int lastBeat;
  int lastBeatMono;
  LockInfo info;

  /// Indirizzo di chi ospita visto sul socket (forma canonica): è l'IP
  /// diretto, la risposta del DNS e l'unico bersaglio del test della porta.
  String? ip;

  /// L'evento `stale` è già stato pubblicato per questo silenzio.
  bool staleNotified = false;

  /// Esito della prova della porta (port_check.dart); solo in memoria.
  PortCheck? portCheck;

  bool isStale(Clock clock, Duration ttl) => clock.monoMs() - lastBeatMono > ttl.inMilliseconds;

  void beat(Clock clock) {
    lastBeat = clock.wallMs();
    lastBeatMono = clock.monoMs();
    staleNotified = false;
  }

  /// Lock di una sessione di gioco.
  bool get isPlay => info.action == 'play';

  /// Vista pubblica (senza token), sempre una copia.
  LockHolder holder(Clock clock, Duration ttl) => LockHolder(
    memberId: memberId,
    name: name,
    since: since,
    lastBeat: lastBeat,
    stale: isStale(clock, ttl),
    // senza l'indirizzo LAN: serve solo al DNS e non esce mai dall'hub
    info: LockInfo.fromJson(info.public().toJson()),
    ip: ip,
    portCheck: portCheck,
  );

  Map<String, Object?> toJson() => {
    'token': token,
    'memberId': memberId,
    'name': name,
    'since': since,
    'lastBeat': lastBeat,
    'info': info.toJson(),
    'ip': ?ip,
    // non risponde già: lo resta dopo un riavvio dell'hub
    if (staleNotified) 'stale': true,
  };
}

/// Una generazione letta da disco, con il push che l'ha creata.
typedef StoredGeneration = ({Generation gen, String? pushId});

/// Stato in memoria di uno spazio.
final class SpaceState {
  SpaceState(this.meta, this.dir);

  SpaceMeta meta;
  final String dir;

  /// Serializza le operazioni che cambiano testa e generazioni.
  final mutex = Mutex();

  /// Serializza le scritture di lock.json.
  final lockIo = Mutex();

  int headN = 0;
  String headDigest = emptyDigest;
  Manifest headManifest = Manifest.empty;
  GenerationSummary? headSummary;

  /// Push che ha creato la testa (per rendere idempotente un commit la cui
  /// risposta è andata persa dopo lo spostamento della testa).
  String? headPushId;

  /// Riassunti delle generazioni presenti, per numero.
  final summaries = SplayTreeMap<int, GenerationSummary>();

  LockState? lock;
  bool deleted = false;

  String get id => meta.id;
  String get generationsDir => '$dir/generations';
  String genPath(int n) => '$generationsDir/$n.json';
}

enum PushStatus { open, committed }

/// Sessione di push (`pushes/<id>.json`).
final class PushSession {
  PushSession({
    required this.id,
    required this.space,
    required this.memberId,
    required this.author,
    required this.lockToken,
    required this.parent,
    required this.parentDigest,
    required this.message,
    required this.kind,
    required this.createdAt,
    required this.lastActivity,
    this.manifest,
    this.status = PushStatus.open,
    this.result,
    this.damaged = const [],
  }) : sizes = manifest == null ? const {} : blobSizes(manifest);

  factory PushSession.fromJson(Object? j, Clock clock) {
    if (j is! Map<String, Object?>) throw const FormatException('push: atteso un oggetto');
    final status = j['status'] == 'committed' ? PushStatus.committed : PushStatus.open;
    String s(String k) => j[k] is String ? j[k]! as String : throw FormatException('push: $k');
    int i(String k) => j[k] is int ? j[k]! as int : throw FormatException('push: $k');
    return PushSession(
      id: s('id'),
      space: s('space'),
      memberId: s('memberId'),
      author: s('author'),
      lockToken: j['lockToken'] as String? ?? '',
      parent: j['parent'] as int? ?? 0,
      parentDigest: j['parentDigest'] as String? ?? '',
      message: j['message'] as String? ?? '',
      kind: j['kind'] == null ? GenerationKind.push : GenerationKind.parse(j['kind']),
      createdAt: i('createdAt'),
      // dopo un riavvio l'inattività riparte da adesso
      lastActivity: clock.monoMs(),
      manifest: status == PushStatus.open ? Manifest.fromJson(j['manifest']) : null,
      status: status,
      result: j['result'] == null ? null : GenerationSummary.fromJson(j['result']),
      damaged: [
        for (final d in (j['damaged'] as List<Object?>? ?? const [])) DamagedFile.fromJson(d),
      ],
    );
  }

  final String id;
  final String space;
  final String memberId;
  final String author;
  final String lockToken;
  final int parent;
  final String parentDigest;
  final String message;
  final GenerationKind kind;
  final int createdAt;

  /// Ultima attività (tempo monotono).
  int lastActivity;

  /// Il manifest proposto; null dopo il commit (sta nella generazione).
  Manifest? manifest;

  /// Dimensione dichiarata di ogni blob del manifest.
  final Map<String, int> sizes;
  PushStatus status;
  GenerationSummary? result;

  /// File segnalati danneggiati dal client (B-GEN-11), salvati nella
  /// generazione al commit.
  final List<DamagedFile> damaged;

  void touch(Clock clock) => lastActivity = clock.monoMs();

  Map<String, Object?> toJson() => {
    'id': id,
    'space': space,
    'memberId': memberId,
    'author': author,
    'lockToken': lockToken,
    'parent': parent,
    'parentDigest': parentDigest,
    'message': message,
    'kind': kind.name,
    'createdAt': createdAt,
    'status': status.name,
    if (manifest != null) 'manifest': manifest!.toJson(),
    if (result != null) 'result': result!.toJson(),
    if (damaged.isNotEmpty) 'damaged': [for (final d in damaged) d.toJson()],
  };
}

/// Dimensione di ogni blob di [m]. Lancia [ApiError] `bad_request` se lo
/// stesso hash è dichiarato con due dimensioni.
Map<String, int> blobSizes(Manifest m) {
  final out = <String, int>{};
  void add(String h, int size, String path) {
    final prev = out[h];
    if (prev != null && prev != size) {
      throw ApiError(
        ErrorCode.badRequest,
        'blob $h declared with two sizes ($prev and $size)',
        details: {'path': path},
      );
    }
    out[h] = size;
  }

  for (final e in m.files.entries) {
    final chunks = e.value.chunks;
    if (chunks == null) {
      add(e.value.h, e.value.size, e.key);
    } else {
      for (final c in chunks) {
        add(c.h, c.size, e.key);
      }
    }
  }
  return out;
}
