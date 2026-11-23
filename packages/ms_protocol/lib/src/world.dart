// Dati del mondo letti dall'hub dai blob della HEAD (level.dat,
// server.properties, mods/, world/stats, ops.json, whitelist.json,
// usercache.json) e statistiche delle sessioni. Tutto in cache per
// generazione; nessun dato da servizi esterni (niente skin Mojang).
import 'json.dart';
import 'models.dart';

/// Difficoltà del mondo.
enum Difficulty {
  peaceful,
  easy,
  normal,
  hard;

  static Difficulty parse(Object? v) => enumOf(values, v, 'difficoltà');
}

/// Modalità di gioco.
enum GameMode {
  survival,
  creative,
  adventure,
  spectator;

  static GameMode parse(Object? v) => enumOf(values, v, 'modalità');
}

/// Coordinate di un blocco.
final class BlockPos {
  const BlockPos(this.x, this.y, this.z);

  factory BlockPos.fromJson(Object? j) {
    final m = obj(j, 'pos');
    return BlockPos(integer(m, 'x'), integer(m, 'y'), integer(m, 'z'));
  }

  final int x;
  final int y;
  final int z;

  Map<String, Object?> toJson() => {'x': x, 'y': y, 'z': z};
}

/// Da `level.dat` (B-META-01). Ogni campo è null se il file non lo ha.
final class LevelInfo {
  const LevelInfo({
    this.name,
    this.version,
    this.dataVersion,
    this.difficulty,
    this.hardcore,
    this.gameMode,
    this.day,
    this.timeTicks,
    this.spawn,
    this.seed,
  });

  factory LevelInfo.fromJson(Object? j) {
    final m = obj(j, 'level');
    return LevelInfo(
      name: optStr(m, 'name'),
      version: optStr(m, 'version'),
      dataVersion: optInt(m, 'dataVersion'),
      difficulty: m['difficulty'] == null ? null : Difficulty.parse(m['difficulty']),
      hardcore: optBool(m, 'hardcore'),
      gameMode: m['gameMode'] == null ? null : GameMode.parse(m['gameMode']),
      day: optInt(m, 'day'),
      timeTicks: optInt(m, 'timeTicks'),
      spawn: m['spawn'] == null ? null : BlockPos.fromJson(m['spawn']),
      seed: optStr(m, 'seed'),
    );
  }

  /// `LevelName`.
  final String? name;

  /// `Version.Name`, es. `1.21.1`.
  final String? version;
  final int? dataVersion;
  final Difficulty? difficulty;
  final bool? hardcore;
  final GameMode? gameMode;

  /// Giorno in gioco: `Time / 24000`.
  final int? day;

  /// Età del mondo in tick (`Time`; 20 tick = 1 s).
  final int? timeTicks;
  final BlockPos? spawn;

  /// Seed a 64 bit come stringa decimale: non entra in un numero JS.
  final String? seed;

  Map<String, Object?> toJson() => {
    if (name != null) 'name': name,
    if (version != null) 'version': version,
    if (dataVersion != null) 'dataVersion': dataVersion,
    if (difficulty != null) 'difficulty': difficulty!.name,
    if (hardcore != null) 'hardcore': hardcore,
    if (gameMode != null) 'gameMode': gameMode!.name,
    if (day != null) 'day': day,
    if (timeTicks != null) 'timeTicks': timeTicks,
    if (spawn != null) 'spawn': spawn!.toJson(),
    if (seed != null) 'seed': seed,
  };
}

/// Da `server.properties` (sola lettura). Campi null se assenti.
final class ServerProperties {
  const ServerProperties({
    this.motd,
    this.maxPlayers,
    this.pvp,
    this.whitelist,
    this.whitelistCount,
    this.viewDistance,
    this.simulationDistance,
    this.port,
    this.onlineMode,
  });

  factory ServerProperties.fromJson(Object? j) {
    final m = obj(j, 'properties');
    return ServerProperties(
      motd: optStr(m, 'motd'),
      maxPlayers: optInt(m, 'maxPlayers'),
      pvp: optBool(m, 'pvp'),
      whitelist: optBool(m, 'whitelist'),
      whitelistCount: optInt(m, 'whitelistCount'),
      viewDistance: optInt(m, 'viewDistance'),
      simulationDistance: optInt(m, 'simulationDistance'),
      port: optInt(m, 'port'),
      onlineMode: optBool(m, 'onlineMode'),
    );
  }

  /// Testo semplice: i codici di formattazione `§x` sono tolti dall'hub.
  final String? motd;
  final int? maxPlayers;
  final bool? pvp;

  /// `white-list`.
  final bool? whitelist;

  /// Voci di `whitelist.json`.
  final int? whitelistCount;
  final int? viewDistance;
  final int? simulationDistance;

  /// `server-port`.
  final int? port;
  final bool? onlineMode;

  Map<String, Object?> toJson() => {
    if (motd != null) 'motd': motd,
    if (maxPlayers != null) 'maxPlayers': maxPlayers,
    if (pvp != null) 'pvp': pvp,
    if (whitelist != null) 'whitelist': whitelist,
    if (whitelistCount != null) 'whitelistCount': whitelistCount,
    if (viewDistance != null) 'viewDistance': viewDistance,
    if (simulationDistance != null) 'simulationDistance': simulationDistance,
    if (port != null) 'port': port,
    if (onlineMode != null) 'onlineMode': onlineMode,
  };
}

/// `GET /spaces/{id}/world`.
final class WorldInfo {
  const WorldInfo({
    required this.n,
    required this.chip,
    this.level,
    this.properties,
    this.modsBytes = 0,
    this.players = 0,
    this.icon = false,
  });

  factory WorldInfo.fromJson(Object? j) {
    final m = obj(j, 'world');
    return WorldInfo(
      n: integer(m, 'n'),
      chip: WorldChip.fromJson(m['chip']),
      level: m['level'] == null ? null : LevelInfo.fromJson(m['level']),
      properties: m['properties'] == null ? null : ServerProperties.fromJson(m['properties']),
      modsBytes: optInt(m, 'modsBytes') ?? 0,
      players: optInt(m, 'players') ?? 0,
      icon: optBool(m, 'icon') ?? false,
    );
  }

  /// Generazione da cui sono letti i dati (la HEAD).
  final int n;
  final WorldChip chip;

  /// null senza `level.dat` leggibile.
  final LevelInfo? level;
  final ServerProperties? properties;
  final int modsBytes;

  /// Giocatori noti (vedi `GET /spaces/{id}/players`).
  final int players;

  /// C'è `server-icon.png` (`GET /spaces/{id}/icon`).
  final bool icon;

  Map<String, Object?> toJson() => {
    'n': n,
    'chip': chip.toJson(),
    if (level != null) 'level': level!.toJson(),
    if (properties != null) 'properties': properties!.toJson(),
    'modsBytes': modsBytes,
    'players': players,
    'icon': icon,
  };
}

/// Un jar in `mods/` (B-META-02, B-META-03).
final class ModInfo {
  const ModInfo({
    required this.file,
    required this.size,
    required this.h,
    this.id,
    this.name,
    this.version,
    this.loader,
    this.mcVersion,
    this.authors = const [],
    this.description,
    this.homepage,
    this.license,
    this.icon = false,
    this.since,
    this.updated,
    this.changed = false,
  });

  factory ModInfo.fromJson(Object? j) {
    final m = obj(j, 'mod');
    return ModInfo(
      file: str(m, 'file'),
      size: integer(m, 'size'),
      h: str(m, 'h'),
      id: optStr(m, 'id'),
      name: optStr(m, 'name'),
      version: optStr(m, 'version'),
      loader: m['loader'] == null ? null : Loader.parse(m['loader']),
      mcVersion: optStr(m, 'mcVersion'),
      authors: strings(m, 'authors'),
      description: optStr(m, 'description'),
      homepage: optStr(m, 'homepage'),
      license: optStr(m, 'license'),
      icon: optBool(m, 'icon') ?? false,
      since: optInt(m, 'since'),
      updated: optInt(m, 'updated'),
      changed: optBool(m, 'changed') ?? false,
    );
  }

  /// Nome del file in `mods/` (è anche l'id nell'URL dell'icona).
  final String file;
  final int size;

  /// SHA-256 del jar.
  final String h;
  final String? id;
  final String? name;
  final String? version;
  final Loader? loader;

  /// Versione di Minecraft dichiarata nelle dipendenze.
  final String? mcVersion;
  final List<String> authors;
  final String? description;

  /// Solo URL `http`/`https` (B-META-05); altro diventa null.
  final String? homepage;
  final String? license;

  /// Il jar ha un'icona PNG (`GET /spaces/{id}/mods/{file}/icon`).
  final bool icon;

  /// Generazione più vecchia (tra quelle conservate) da cui il file c'è
  /// senza interruzioni, e l'ultima in cui il contenuto è cambiato. null se
  /// l'hub non lo ha calcolato.
  final int? since;
  final int? updated;

  /// Aggiunto o cambiato nella HEAD rispetto alla precedente.
  final bool changed;

  /// Il jar non dichiara metadati.
  bool get bare => name == null && version == null && authors.isEmpty;

  Map<String, Object?> toJson() => {
    'file': file,
    'size': size,
    'h': h,
    if (id != null) 'id': id,
    if (name != null) 'name': name,
    if (version != null) 'version': version,
    if (loader != null) 'loader': loader!.name,
    if (mcVersion != null) 'mcVersion': mcVersion,
    if (authors.isNotEmpty) 'authors': authors,
    if (description != null) 'description': description,
    if (homepage != null) 'homepage': homepage,
    if (license != null) 'license': license,
    'icon': icon,
    if (since != null) 'since': since,
    if (updated != null) 'updated': updated,
    if (changed) 'changed': true,
  };
}

/// `GET /spaces/{id}/mods`.
final class ModList {
  const ModList({required this.n, required this.chip, required this.bytes, required this.mods});

  factory ModList.fromJson(Object? j) {
    final m = obj(j, 'mods');
    return ModList(
      n: integer(m, 'n'),
      chip: WorldChip.fromJson(m['chip']),
      bytes: integer(m, 'bytes'),
      mods: listOf(m, 'mods', ModInfo.fromJson),
    );
  }

  final int n;
  final WorldChip chip;

  /// Somma delle dimensioni dei jar.
  final int bytes;

  /// Ordinate per nome (o file se senza nome), senza maiuscole.
  final List<ModInfo> mods;

  Map<String, Object?> toJson() => {
    'n': n,
    'chip': chip.toJson(),
    'bytes': bytes,
    'mods': [for (final x in mods) x.toJson()],
  };
}

/// Un giocatore del mondo.
final class PlayerInfo {
  const PlayerInfo({
    required this.uuid,
    this.name,
    this.op = false,
    this.opLevel,
    this.whitelisted = false,
    this.online = false,
    this.lastSeen,
    this.playTicks = 0,
    this.deaths = 0,
    this.mobKills = 0,
    this.distanceCm = 0,
  });

  factory PlayerInfo.fromJson(Object? j) {
    final m = obj(j, 'player');
    return PlayerInfo(
      uuid: str(m, 'uuid'),
      name: optStr(m, 'name'),
      op: optBool(m, 'op') ?? false,
      opLevel: optInt(m, 'opLevel'),
      whitelisted: optBool(m, 'whitelisted') ?? false,
      online: optBool(m, 'online') ?? false,
      lastSeen: optInt(m, 'lastSeen'),
      playTicks: optInt(m, 'playTicks') ?? 0,
      deaths: optInt(m, 'deaths') ?? 0,
      mobKills: optInt(m, 'mobKills') ?? 0,
      distanceCm: optInt(m, 'distanceCm') ?? 0,
    );
  }

  /// UUID con trattini, minuscolo: il client ne ricava l'avatar.
  final String uuid;

  /// Da usercache.json, ops.json o whitelist.json; null se nessuno lo ha.
  final String? name;
  final bool op;
  final int? opLevel;
  final bool whitelisted;

  /// Nell'elenco `players` del lock vivo (confronto per nome).
  final bool online;

  /// Stima dell'ultimo accesso: `expiresOn` di usercache.json meno un mese.
  final int? lastSeen;

  /// `minecraft:custom` / `minecraft:play_time` (20 tick = 1 s).
  final int playTicks;
  final int deaths;
  final int mobKills;

  /// Somma dei `*_one_cm` di spostamento a piedi (walk, sprint, crouch,
  /// swim, walk_on_water, walk_under_water), in centimetri.
  final int distanceCm;

  Map<String, Object?> toJson() => {
    'uuid': uuid,
    if (name != null) 'name': name,
    'op': op,
    if (opLevel != null) 'opLevel': opLevel,
    'whitelisted': whitelisted,
    'online': online,
    if (lastSeen != null) 'lastSeen': lastSeen,
    'playTicks': playTicks,
    'deaths': deaths,
    'mobKills': mobKills,
    'distanceCm': distanceCm,
  };
}

/// `GET /spaces/{id}/players`.
final class PlayerList {
  const PlayerList({required this.n, required this.ts, required this.players});

  factory PlayerList.fromJson(Object? j) {
    final m = obj(j, 'players');
    return PlayerList(
      n: integer(m, 'n'),
      ts: integer(m, 'ts'),
      players: listOf(m, 'players', PlayerInfo.fromJson),
    );
  }

  /// Generazione letta e sua data.
  final int n;
  final int ts;
  final List<PlayerInfo> players;

  Map<String, Object?> toJson() => {
    'n': n,
    'ts': ts,
    'players': [for (final p in players) p.toJson()],
  };
}

/// Una voce di classifica: ore in gioco (giocatori Minecraft) o di hosting
/// (membri).
final class RankEntry {
  const RankEntry({required this.name, required this.ms, this.memberId});

  factory RankEntry.fromJson(Object? j) {
    final m = obj(j, 'rank');
    return RankEntry(name: str(m, 'name'), ms: integer(m, 'ms'), memberId: optStr(m, 'memberId'));
  }

  final String name;
  final int ms;

  /// Solo per l'hosting.
  final String? memberId;

  Map<String, Object?> toJson() => {
    'name': name,
    'ms': ms,
    if (memberId != null) 'memberId': memberId,
  };
}

/// `GET /spaces/{id}/stats`: dalle sessioni conservate (Admin ›
/// Statistiche), non dall'inizio del mondo.
final class SpaceStats {
  const SpaceStats({
    required this.kept,
    required this.sessions,
    this.play = const [],
    this.hosting = const [],
  });

  factory SpaceStats.fromJson(Object? j) {
    final m = obj(j, 'stats');
    return SpaceStats(
      kept: integer(m, 'kept'),
      sessions: listOf(m, 'sessions', SessionRecord.fromJson),
      play: optListOf(m, 'play', RankEntry.fromJson),
      hosting: optListOf(m, 'hosting', RankEntry.fromJson),
    );
  }

  /// Quante sessioni si conservano al massimo.
  final int kept;

  /// Dalla più recente; quella in corso, se c'è, è la prima.
  final List<SessionRecord> sessions;

  /// Classifiche, dal più alto.
  final List<RankEntry> play;
  final List<RankEntry> hosting;

  Map<String, Object?> toJson() => {
    'kept': kept,
    'sessions': [for (final s in sessions) s.toJson()],
    'play': [for (final r in play) r.toJson()],
    'hosting': [for (final r in hosting) r.toJson()],
  };
}
