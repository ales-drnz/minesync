// Dati del mondo nella HEAD di uno spazio: level.dat, server.properties,
// giocatori, mod e icone, letti dai blob dello store. Una generazione è
// immutabile, quindi il risultato si tiene per (spazio, digest): in memoria
// (LRU piccola) e su disco sotto cache/world/<spazio>/<digest>.json, così un
// riavvio non rilegge tutti i jar. Un digest nuovo invalida da solo.
//
// Il calcolo gira nell'isolate dell'hub con I/O asincrono, un solo calcolo
// per chiave alla volta; il solo level.dat grande si decodifica in un
// isolate a parte (Isolate.run) per non fermare il ciclo degli eventi.
// Ogni file ha un tetto di dimensione; i jar si leggono ad accesso casuale
// (directory centrale e poche voci), mai interi.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ms_minecraft/ms_minecraft.dart';
import 'package:ms_protocol/ms_protocol.dart';

import '../jsonfile.dart';
import '../store.dart';
import 'blob_source.dart';

/// Tetti di lettura.
const _maxLevelDat = 16 << 20;
const _maxSmallFile = 4 << 20;
const _maxStatsFile = 1 << 20;
const _maxStatsFiles = 5000;
const _maxMods = 2000;
const _maxIcon = 512 << 10;
const _maxHistory = 100;
// 2: fabric.mod.json con a capo grezzi nelle stringhe ora si legge
const _cacheVersion = 2;

/// Un'icona PNG pronta da servire.
typedef Icon = ({Uint8List bytes, String etag});

/// Il calcolo per una generazione.
final class _Snap {
  _Snap({
    required this.n,
    required this.ts,
    required this.digest,
    required this.chip,
    required this.level,
    required this.properties,
    required this.modsBytes,
    required this.iconHash,
    required this.players,
    required this.mods,
    required this.modIcons,
  });

  factory _Snap.fromJson(Object? j) {
    final m = j! as Map<String, Object?>;
    if (m['v'] != _cacheVersion) throw const FormatException('cache: versione diversa');
    return _Snap(
      n: m['n']! as int,
      ts: m['ts']! as int,
      digest: m['digest']! as String,
      chip: WorldChip.fromJson(m['chip']),
      level: m['level'] == null ? null : LevelInfo.fromJson(m['level']),
      properties: m['properties'] == null ? null : ServerProperties.fromJson(m['properties']),
      modsBytes: m['modsBytes']! as int,
      iconHash: m['iconHash'] as String?,
      players: [for (final p in m['players']! as List<Object?>) PlayerInfo.fromJson(p)],
      mods: [for (final x in m['mods']! as List<Object?>) ModInfo.fromJson(x)],
      modIcons: (m['modIcons']! as Map<String, Object?>).cast<String, String>(),
    );
  }

  final int n;
  final int ts;
  final String digest;
  final WorldChip chip;
  final LevelInfo? level;
  final ServerProperties? properties;
  final int modsBytes;

  /// Blob di server-icon.png, se è un PNG accettabile.
  final String? iconHash;

  /// Senza `online` (dipende dal lock vivo, si calcola a ogni richiesta).
  final List<PlayerInfo> players;
  final List<ModInfo> mods;

  /// File del jar → percorso dell'icona dentro il jar.
  final Map<String, String> modIcons;

  Map<String, Object?> toJson() => {
    'v': _cacheVersion,
    'n': n,
    'ts': ts,
    'digest': digest,
    'chip': chip.toJson(),
    if (level != null) 'level': level!.toJson(),
    if (properties != null) 'properties': properties!.toJson(),
    'modsBytes': modsBytes,
    'iconHash': ?iconHash,
    'players': [for (final p in players) p.toJson()],
    'mods': [for (final x in mods) x.toJson()],
    'modIcons': modIcons,
  };
}

/// Metadati del mondo per gli spazi dell'hub.
final class WorldMeta {
  WorldMeta(this._store, {int cacheEntries = 32, void Function(String)? log})
    : _max = cacheEntries,
      _log = log ?? ((m) => stderr.writeln(m));

  final HubStore _store;
  final int _max;
  final void Function(String) _log;
  final _lru = <String, _Snap>{};
  final _running = <String, Future<_Snap>>{};
  final _icons = <String, Icon>{};

  bool _closed = false;

  String get cacheDir => '${_store.root}/cache/world';

  /// Aspetta i calcoli in corso; dopo non ne parte nessuno in sottofondo.
  Future<void> close() async {
    _closed = true;
    await Future.wait([for (final f in _running.values) f.then<void>((_) {}, onError: (_) {})]);
  }

  // ---------------------------------------------------------------- API

  /// `GET /spaces/{id}/world`.
  Future<WorldInfo> world(String space) async {
    final s = await _current(space);
    if (s == null) return const WorldInfo(n: 0, chip: WorldChip());
    return WorldInfo(
      n: s.n,
      chip: s.chip,
      level: s.level,
      properties: s.properties,
      modsBytes: s.modsBytes,
      players: s.players.length,
      icon: s.iconHash != null,
    );
  }

  /// `GET /spaces/{id}/players`: `online` dal lock vivo, per nome.
  Future<PlayerList> players(String space) async {
    final s = await _current(space);
    if (s == null) return const PlayerList(n: 0, ts: 0, players: []);
    final lock = _store.lockSnapshot(space);
    final online = lock == null || lock.stale
        ? const <String>{}
        : {for (final p in lock.info.players) p.toLowerCase()};
    return PlayerList(
      n: s.n,
      ts: s.ts,
      players: [
        for (final p in s.players)
          if (p.name != null && online.contains(p.name!.toLowerCase()))
            PlayerInfo.fromJson({...p.toJson(), 'online': true})
          else
            p,
      ],
    );
  }

  /// `GET /spaces/{id}/mods`.
  Future<ModList> mods(String space) async {
    final s = await _current(space);
    if (s == null) return const ModList(n: 0, chip: WorldChip(), bytes: 0, mods: []);
    return ModList(n: s.n, chip: s.chip, bytes: s.modsBytes, mods: s.mods);
  }

  /// `server-icon.png` della HEAD, se è un PNG accettabile.
  Future<Icon?> icon(String space) async {
    final s = await _current(space);
    final h = s?.iconHash;
    if (h == null) return null;
    final key = 'srv/$h';
    final hit = _icons.remove(key);
    if (hit != null) return _icons[key] = hit;
    final g = await _store.generation(space, null);
    final e = g.manifest['server-icon.png'];
    if (e == null || e.h != h) return null;
    final b = await readManifestFile(_store.blobs, e, max: _maxIcon);
    if (b == null || !isPng(b)) return null;
    return _remember(key, (bytes: b, etag: h));
  }

  /// L'icona della mod [file] (nome del jar in `mods/`).
  Future<Icon?> modIcon(String space, String file) async {
    final s = await _current(space);
    final path = s?.modIcons[file];
    if (s == null || path == null) return null;
    final mod = s.mods.firstWhere((m) => m.file == file);
    final key = 'mod/${mod.h}/$path';
    final hit = _icons.remove(key);
    if (hit != null) return _icons[key] = hit;
    final g = await _store.generation(space, null);
    final e = g.manifest['mods/$file'];
    if (e == null || e.h != mod.h) return null;
    try {
      final jar = await ZipArchive.open(ManifestFileSource(_store.blobs, e));
      final b = jar == null ? null : await readModIcon(jar, path, max: _maxIcon);
      return b == null ? null : _remember(key, (bytes: b, etag: mod.h));
    } on FileSystemException {
      return null;
    }
  }

  /// Riassunto per le card: dalla cache, senza aspettare. Se manca avvia il
  /// calcolo in sottofondo e intanto restituisce null.
  WorldChip? chip(String space, String digest) {
    if (digest == emptyDigest) return null;
    final key = '$space/$digest';
    final hit = _lru[key];
    if (hit != null) return hit.chip;
    if (!_closed && !_running.containsKey(key)) {
      unawaited(
        _current(space).then<void>((_) {}, onError: (Object e) => _log('hub: mondo di $space: $e')),
      );
    }
    return null;
  }

  /// Dimentica uno spazio cancellato (memoria e cache su disco).
  Future<void> forget(String space) async {
    _lru.removeWhere((k, _) => k.startsWith('$space/'));
    try {
      await Directory('$cacheDir/$space').delete(recursive: true);
    } on FileSystemException {
      // già assente
    }
  }

  // ---------------------------------------------------------------- cache

  Icon _remember(String key, Icon v) {
    _icons[key] = v;
    while (_icons.length > 16) {
      _icons.remove(_icons.keys.first);
    }
    return v;
  }

  /// Il calcolo per la HEAD attuale di [space]; null se lo spazio non ha
  /// ancora generazioni. `not_found` se lo spazio non esiste.
  Future<_Snap?> _current(String space) async {
    final head = await _store.generation(space, null);
    if (head.n == 0) return null;
    final key = '$space/${head.digest}';
    final hit = _lru.remove(key);
    if (hit != null) return _lru[key] = hit;
    final run = _running[key] ??= _load(space, head).whenComplete(() {
      // senza graffe whenComplete aspetterebbe il future rimosso: se stesso
      _running.remove(key);
    });
    final s = await run;
    _lru.remove(key);
    _lru[key] = s;
    while (_lru.length > _max) {
      _lru.remove(_lru.keys.first);
    }
    return s;
  }

  Future<_Snap> _load(String space, Generation head) async {
    final path = '$cacheDir/$space/${head.digest}.json';
    final cached = await tryReadJsonFile(path);
    if (cached != null) {
      try {
        return _Snap.fromJson(cached);
      } on Object {
        // cache vecchia o rovinata: si ricalcola
      }
    }
    final s = await _compute(space, head);
    try {
      final dir = Directory('$cacheDir/$space');
      await dir.create(recursive: true);
      await writeJsonAtomic(path, s.toJson());
      // le generazioni vecchie non servono più
      await for (final f in dir.list()) {
        if (f is File && f.path != path && f.path.endsWith('.json')) await f.delete();
      }
    } on FileSystemException catch (e) {
      _log('hub: cache del mondo di $space non scritta: $e');
    }
    return s;
  }

  // ---------------------------------------------------------------- calcolo

  Future<Uint8List?> _file(Manifest m, String path, int max) =>
      readManifestFile(_store.blobs, m[path], max: max);

  Future<_Snap> _compute(String space, Generation head) async {
    final m = head.manifest;
    final blobs = _store.blobs;
    final propsBytes = await _file(m, 'server.properties', _maxSmallFile);
    final props = propsBytes == null
        ? const <String, String>{}
        : parseProperties(utf8.decode(propsBytes, allowMalformed: true));
    final levelDir = levelFolder(props);

    Future<List<PlayerEntry>> entries(String p) async {
      final b = await _file(m, p, _maxSmallFile);
      return b == null ? const [] : parsePlayerEntries(b);
    }

    final whitelist = await entries('whitelist.json');
    final ops = await entries('ops.json');
    final cache = await entries('usercache.json');

    final level = await _level(m, levelDir);
    final chip = chipFromPaths(m.files.keys, mcVersion: level?.version, levelDir: levelDir);

    String? iconHash;
    final ie = m['server-icon.png'];
    if (ie != null && ie.size <= _maxIcon) {
      final b = await readManifestFile(blobs, ie, max: _maxIcon);
      if (b != null && isPng(b)) iconHash = ie.h;
    }

    // giocatori: unione di stats/, ops.json e whitelist.json
    final stats = <String, PlayerStats>{};
    final prefix = '$levelDir/stats/';
    for (final e in m.files.entries) {
      if (stats.length >= _maxStatsFiles) break;
      final p = e.key;
      if (!p.startsWith(prefix) || !p.endsWith('.json')) continue;
      final u = normalizeUuid(p.substring(prefix.length, p.length - 5));
      if (u == null) continue;
      final b = await readManifestFile(blobs, e.value, max: _maxStatsFile);
      final s = b == null ? null : parsePlayerStats(b);
      stats[u] = s ?? (playTicks: 0, deaths: 0, mobKills: 0, distanceCm: 0);
    }
    final names = <String, String>{};
    final lastSeen = <String, int>{};
    for (final e in [...whitelist, ...ops, ...cache]) {
      if (e.name != null) names[e.uuid] = e.name!; // usercache vince, poi ops
      if (e.expiresOn != null) lastSeen[e.uuid] = lastSeenFromExpiry(e.expiresOn!);
    }
    final opOf = {for (final o in ops) o.uuid: o};
    final wl = {for (final w in whitelist) w.uuid};
    final uuids = {...stats.keys, ...opOf.keys, ...wl};
    final players = [
      for (final u in uuids)
        PlayerInfo(
          uuid: u,
          name: names[u],
          op: opOf.containsKey(u),
          opLevel: opOf[u]?.level,
          whitelisted: wl.contains(u),
          lastSeen: lastSeen[u],
          playTicks: stats[u]?.playTicks ?? 0,
          deaths: stats[u]?.deaths ?? 0,
          mobKills: stats[u]?.mobKills ?? 0,
          distanceCm: stats[u]?.distanceCm ?? 0,
        ),
    ]..sort((a, b) => b.playTicks.compareTo(a.playTicks));

    final mods = await _mods(space, head);
    return _Snap(
      n: head.n,
      ts: head.summary.ts,
      digest: head.digest,
      chip: chip,
      level: level,
      properties: propsBytes == null
          ? null
          : serverPropertiesInfo(
              props,
              whitelistCount: whitelist.isEmpty && m['whitelist.json'] == null
                  ? null
                  : whitelist.length,
            ),
      modsBytes: mods.$1.fold(0, (a, x) => a + x.size),
      iconHash: iconHash,
      players: players,
      mods: mods.$1,
      modIcons: mods.$2,
    );
  }

  Future<LevelInfo?> _level(Manifest m, String levelDir) async {
    final b = await _file(m, '$levelDir/level.dat', _maxLevelDat);
    if (b == null) return null;
    LevelInfo l;
    try {
      // un level.dat grande (registri delle mod) si decodifica a parte
      l = b.length > (256 << 10) ? await Isolate.run(() => parseLevelDat(b)) : parseLevelDat(b);
    } on Object {
      return null;
    }
    if (l.seed != null) return l;
    final wg = await _file(m, '$levelDir/data/minecraft/world_gen_settings.dat', _maxSmallFile);
    final seed = wg == null ? null : parseWorldGenSeed(wg);
    if (seed == null) return l;
    return LevelInfo.fromJson({...l.toJson(), 'seed': seed});
  }

  /// Mod della HEAD e percorsi delle loro icone valide.
  Future<(List<ModInfo>, Map<String, String>)> _mods(String space, Generation head) async {
    final jars = [
      for (final e in head.manifest.files.entries)
        if (e.key.startsWith('mods/') &&
            !e.key.substring(5).contains('/') &&
            e.key.toLowerCase().endsWith('.jar'))
          (file: e.key.substring(5), entry: e.value),
    ];
    if (jars.isEmpty) return (const <ModInfo>[], const <String, String>{});
    if (jars.length > _maxMods) jars.removeRange(_maxMods, jars.length);

    // changed: rispetto alla generazione precedente; since/updated sulle
    // generazioni conservate, dalla più recente all'indietro
    final parent = await _gen(space, head.summary.parent);
    final older = <(int, Manifest)>[];
    final hist = _store.history(space, before: head.n, limit: _maxHistory);
    for (final j in hist['generations']! as List<Object?>) {
      final g = GenerationSummary.fromJson(j);
      final x = g.n == head.summary.parent ? parent : await _gen(space, g.n);
      if (x != null) older.add((g.n, x.manifest));
    }

    final out = <ModInfo>[];
    final icons = <String, String>{};
    for (final j in jars) {
      final path = 'mods/${j.file}';
      var since = head.n, updated = head.n;
      var same = true;
      for (final (n, om) in older) {
        final e = om[path];
        if (e == null) break;
        since = n;
        if (same && e.h == j.entry.h) {
          updated = n;
        } else {
          same = false;
        }
      }
      final pe = parent?.manifest[path];
      final changed = parent == null ? head.summary.parent == 0 : (pe == null || pe.h != j.entry.h);

      ModMeta? meta;
      var icon = false;
      try {
        final jar = await ZipArchive.open(ManifestFileSource(_store.blobs, j.entry));
        if (jar != null) {
          meta = await readModMeta(jar);
          final ip = meta?.iconPath;
          if (ip != null && await readModIcon(jar, ip, max: _maxIcon) != null) {
            icon = true;
            icons[j.file] = ip;
          }
        }
      } on FileSystemException {
        meta = null;
      }
      out.add(
        ModInfo(
          file: j.file,
          size: j.entry.size,
          h: j.entry.h,
          id: meta?.id,
          name: meta?.name,
          version: meta?.version,
          loader: meta?.loader,
          mcVersion: meta?.mcVersion,
          authors: meta?.authors ?? const [],
          description: meta?.description,
          homepage: meta?.homepage,
          license: meta?.license,
          icon: icon,
          since: since,
          updated: updated,
          changed: changed,
        ),
      );
    }
    out.sort((a, b) {
      final c = (a.name ?? a.file).toLowerCase().compareTo((b.name ?? b.file).toLowerCase());
      return c != 0 ? c : a.file.compareTo(b.file);
    });
    return (out, icons);
  }

  Future<Generation?> _gen(String space, int n) async {
    if (n <= 0) return null;
    try {
      return await _store.generation(space, n);
    } on ApiError {
      return null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }
}
