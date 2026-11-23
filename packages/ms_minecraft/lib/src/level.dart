// level.dat → LevelInfo (B-META-01). Campi mancanti o di tipo sbagliato
// restano null: non si inventa niente.
//
// Spawn: il formato classico ha `SpawnX/SpawnY/SpawnZ` interi in `Data`;
// quello recente (Java Edition 1.21.9 e seguenti, documentato nella pagina
// "Java Edition level format" della Minecraft Wiki) ha un compound
// `Data.spawn` con `pos` (int array [x, y, z]), `dimension`, `yaw`, `pitch`.
// Si leggono entrambi; vince il compound se valido.
//
// Seed: `Data.WorldGenSettings.seed` (1.16+), altrimenti `Data.RandomSeed`.
// Dalla 26.1 WorldGenSettings sta in `data/minecraft/world_gen_settings.dat`
// (vedi [parseWorldGenSeed]).
import 'dart:typed_data';

import 'package:ms_protocol/ms_protocol.dart';

import 'nbt.dart';

/// Ticks in un giorno di Minecraft.
const ticksPerDay = 24000;

/// Interpreta `level.dat`. Lancia [FormatException] se non è NBT valido.
LevelInfo parseLevelDat(Uint8List bytes) {
  final root = readNbt(bytes);
  final data = root['Data'] is Map<String, Object?> ? root['Data']! as Map<String, Object?> : root;
  final version = data['Version'];
  final time = _int(data['Time']);
  final diff = _int(data['Difficulty']);
  final gt = _int(data['GameType']);
  final hc = _int(data['hardcore']);
  return LevelInfo(
    name: _str(data['LevelName']),
    version: version is Map<String, Object?> ? _str(version['Name']) : null,
    dataVersion: _int(data['DataVersion']),
    difficulty: diff != null && diff >= 0 && diff < Difficulty.values.length
        ? Difficulty.values[diff]
        : null,
    hardcore: hc == null ? null : hc != 0,
    gameMode: gt != null && gt >= 0 && gt < GameMode.values.length ? GameMode.values[gt] : null,
    day: time == null || time < 0 ? null : time ~/ ticksPerDay,
    timeTicks: time,
    spawn: _spawn(data),
    seed: _seedOf(data),
  );
}

/// Seed da `data/minecraft/world_gen_settings.dat` (26.1+): `seed` nella
/// radice o nel suo compound `data`. null se assente o illeggibile.
String? parseWorldGenSeed(Uint8List bytes) {
  try {
    final root = readNbt(bytes);
    for (final m in [root, root['data'], root['Data']]) {
      if (m is! Map<String, Object?>) continue;
      final s = _int(m['seed']);
      if (s != null) return '$s';
      final w = m['WorldGenSettings'];
      if (w is Map<String, Object?> && _int(w['seed']) != null) return '${_int(w['seed'])}';
    }
  } on FormatException {
    return null;
  }
  return null;
}

String? _seedOf(Map<String, Object?> data) {
  final wgs = data['WorldGenSettings'];
  if (wgs is Map<String, Object?>) {
    final s = _int(wgs['seed']);
    if (s != null) return '$s';
  }
  final r = _int(data['RandomSeed']);
  return r == null ? null : '$r';
}

BlockPos? _spawn(Map<String, Object?> data) {
  final sp = data['spawn'];
  if (sp is Map<String, Object?>) {
    final pos = sp['pos'];
    if (pos is List<Object?>) {
      final l = [for (final v in pos) _int(v)];
      if (l.length == 3 && l.every((v) => v != null)) return BlockPos(l[0]!, l[1]!, l[2]!);
    }
  }
  final x = _int(data['SpawnX']), y = _int(data['SpawnY']), z = _int(data['SpawnZ']);
  if (x != null && y != null && z != null) return BlockPos(x, y, z);
  return null;
}

int? _int(Object? v) => v is int ? v : null;
String? _str(Object? v) => v is String ? v : null;
