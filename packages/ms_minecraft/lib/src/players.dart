// Giocatori di un mondo dai file JSON del server: statistiche
// (`<mondo>/stats/<uuid>.json`), `usercache.json`, `ops.json`,
// `whitelist.json`. Input non fidato: un file illeggibile vale vuoto.
import 'dart:convert';
import 'dart:typed_data';

/// Statistiche di un giocatore.
typedef PlayerStats = ({int playTicks, int deaths, int mobKills, int distanceCm});

/// Statistiche di spostamento "a piedi" sommate in `distanceCm`.
const walkStats = [
  'minecraft:walk_one_cm',
  'minecraft:sprint_one_cm',
  'minecraft:crouch_one_cm',
  'minecraft:swim_one_cm',
  'minecraft:walk_on_water_one_cm',
  'minecraft:walk_under_water_one_cm',
];

Object? _decode(Uint8List b) {
  try {
    var s = utf8.decode(b, allowMalformed: true);
    if (s.startsWith('﻿')) s = s.substring(1);
    return jsonDecode(s);
  } on FormatException {
    return null;
  }
}

/// `stats/<uuid>.json`: `minecraft:custom` → `play_time` (o il vecchio
/// `play_one_minute`, sempre in tick), `deaths`, `mob_kills` e la somma di
/// [walkStats]. null se il file non è un oggetto di statistiche.
PlayerStats? parsePlayerStats(Uint8List bytes) {
  final j = _decode(bytes);
  if (j is! Map<String, Object?>) return null;
  final stats = j['stats'];
  if (stats is! Map<String, Object?>) return null;
  final c = stats['minecraft:custom'];
  final m = c is Map<String, Object?> ? c : const <String, Object?>{};
  int v(String k) {
    final x = m[k];
    return x is int && x > 0 ? x : 0;
  }

  final play = v('minecraft:play_time');
  var dist = 0;
  for (final k in walkStats) {
    dist += v(k);
  }
  return (
    playTicks: play > 0 ? play : v('minecraft:play_one_minute'),
    deaths: v('minecraft:deaths'),
    mobKills: v('minecraft:mob_kills'),
    distanceCm: dist,
  );
}

/// Una voce di usercache.json, ops.json o whitelist.json.
typedef PlayerEntry = ({String uuid, String? name, int? level, int? expiresOn});

final _uuidRe = RegExp(r'^[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}$');

/// UUID in forma canonica (minuscolo, con trattini) o null se non lo è.
String? normalizeUuid(String? s) {
  if (s == null) return null;
  final t = s.trim().toLowerCase();
  if (!_uuidRe.hasMatch(t)) return null;
  final h = t.replaceAll('-', '');
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// Elenco di giocatori (array di `{uuid, name, level?, expiresOn?}`); le
/// voci senza uuid valido si saltano.
List<PlayerEntry> parsePlayerEntries(Uint8List bytes) {
  final j = _decode(bytes);
  if (j is! List<Object?>) return const [];
  final out = <PlayerEntry>[];
  for (final e in j) {
    if (e is! Map<String, Object?>) continue;
    final u = normalizeUuid(e['uuid'] is String ? e['uuid']! as String : null);
    if (u == null) continue;
    final name = e['name'];
    final level = e['level'];
    final exp = e['expiresOn'];
    out.add((
      uuid: u,
      name: name is String && name.trim().isNotEmpty ? name.trim() : null,
      level: level is int ? level : null,
      expiresOn: exp is String ? parseMinecraftDate(exp) : null,
    ));
  }
  return out;
}

final _dateRe = RegExp(r'^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2}) ([+-])(\d{2})(\d{2})$');

/// Data di usercache.json (`2026-12-22 10:00:00 +0000`) in ms dall'epoch.
int? parseMinecraftDate(String s) {
  final m = _dateRe.firstMatch(s.trim());
  if (m == null) return null;
  final g = [for (var i = 1; i <= 6; i++) int.parse(m[i]!)];
  final utc = DateTime.utc(g[0], g[1], g[2], g[3], g[4], g[5]);
  final off = (int.parse(m[8]!) * 60 + int.parse(m[9]!)) * (m[7] == '-' ? -1 : 1);
  return utc.millisecondsSinceEpoch - off * 60000;
}

/// Stima dell'ultimo accesso da `expiresOn` di usercache.json: Minecraft
/// lo fissa a un mese dopo l'ultimo accesso.
int lastSeenFromExpiry(int expiresOnMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(expiresOnMs, isUtc: true);
  return DateTime.utc(
    d.year,
    d.month - 1,
    d.day,
    d.hour,
    d.minute,
    d.second,
    d.millisecond,
  ).millisecondsSinceEpoch;
}
