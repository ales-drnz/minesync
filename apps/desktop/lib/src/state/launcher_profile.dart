// Profilo MineSync nel launcher ufficiale di Minecraft: una voce in
// `launcher_profiles.json` con una cartella di gioco tutta sua
// (`<.minecraft>/minesync/<server>`), la versione del loader in
// `versions/<id>/<id>.json` (Fabric e Quilt) e le mod lato giocatore copiate
// in quella cartella. Prima di toccare il file se ne fa una copia accanto.
// Gli altri profili e le altre chiavi del file restano come sono.
import 'dart:convert';
import 'dart:io';

import 'package:ms_modpack/io.dart';
import 'package:ms_modpack/ms_modpack.dart';
import 'package:path/path.dart' as p;

/// Nome del file dei profili del launcher ufficiale.
const launcherProfilesFile = 'launcher_profiles.json';

/// File, nella cartella di gioco del profilo, con i file messi da MineSync
/// (per togliere quelli che il pacchetto nuovo non ha più).
const launcherPlacedFile = '.minesync-files.json';

/// Perché il profilo non si può creare.
final class LauncherProfileError implements Exception {
  const LauncherProfileError(this.reason, [this.detail]);

  /// `noLauncher` (cartella o file dei profili mancanti), `badProfiles`
  /// (file illeggibile), `unsupportedLoader` (Forge e NeoForge: serve il loro
  /// installer), `download` (versione del loader o mod).
  final String reason;
  final Object? detail;

  @override
  String toString() => 'LauncherProfileError($reason${detail == null ? '' : ': $detail'})';
}

/// Cosa ha scritto [createLauncherProfile].
final class LauncherProfileResult {
  const LauncherProfileResult({
    required this.profileKey,
    required this.versionId,
    required this.gameDir,
    required this.backup,
    required this.files,
  });

  /// Chiave in `profiles` (`minesync-<server>`).
  final String profileKey;

  /// `lastVersionId` del profilo.
  final String versionId;
  final String gameDir;

  /// Copia del file dei profili fatta prima di cambiarlo.
  final String backup;

  /// File messi nella cartella di gioco.
  final int files;
}

/// Id della versione del launcher per il loader del pack (quello che
/// scrivono gli installer ufficiali di Fabric e Quilt).
String launcherVersionId(Pack pack) => switch (pack.loader) {
  Loader.vanilla => pack.mcVersion,
  Loader.fabric => 'fabric-loader-${pack.loaderVersion}-${pack.mcVersion}',
  Loader.quilt => 'quilt-loader-${pack.loaderVersion}-${pack.mcVersion}',
  _ => throw const LauncherProfileError('unsupportedLoader'),
};

/// URL del JSON di versione del loader per il launcher (null per vanilla:
/// il launcher la scarica da sé).
String? launcherVersionJsonUrl(Pack pack) {
  final mc = Uri.encodeComponent(pack.mcVersion);
  final lv = Uri.encodeComponent(pack.loaderVersion ?? '');
  return switch (pack.loader) {
    Loader.vanilla => null,
    Loader.fabric => 'https://meta.fabricmc.net/v2/versions/loader/$mc/$lv/profile/json',
    Loader.quilt => 'https://meta.quiltmc.org/v3/versions/loader/$mc/$lv/profile/json',
    _ => throw const LauncherProfileError('unsupportedLoader'),
  };
}

/// Crea o aggiorna il profilo `minesync-<spaceId>` nel launcher in
/// [launcherDir]: copia di sicurezza del file dei profili, JSON del loader,
/// mod del pacchetto in `<launcherDir>/minesync/<spaceId>`.
/// [plan] è il pacchetto per i giocatori; [serverRoot] la cartella del server
/// da cui si copiano gli override.
Future<LauncherProfileResult> createLauncherProfile({
  required String launcherDir,
  required String spaceId,
  required String displayName,
  required ClientPackPlan plan,
  required String serverRoot,
  required Downloader dl,
  required DateTime now,
}) async {
  final profiles = File(p.join(launcherDir, launcherProfilesFile));
  if (!profiles.existsSync()) throw const LauncherProfileError('noLauncher');
  final pack = plan.pack;
  final versionId = launcherVersionId(pack);
  final Map<String, Object?> json;
  try {
    final j = jsonDecode(await profiles.readAsString());
    if (j is! Map<String, Object?>) throw const FormatException('non è un oggetto');
    json = j;
  } on FormatException catch (e) {
    throw LauncherProfileError('badProfiles', e);
  }

  // 1. versione del loader (prima di toccare qualunque file del launcher)
  final url = launcherVersionJsonUrl(pack);
  List<int>? versionJson;
  if (url != null) {
    try {
      final v = await dl.fetchJson(url);
      if (v is! Map<String, Object?>) throw const FormatException('JSON non valido');
      versionJson = utf8.encode(jsonEncode({...v, 'id': versionId}));
    } on Object catch (e) {
      throw LauncherProfileError('download', e);
    }
  }

  // 2. mod nella cartella di gioco, scaricate e verificate in una cartella
  // temporanea; poi si sostituiscono quelle messe la volta prima
  final gameDir = p.join(launcherDir, 'minesync', spaceId);
  final tmp = Directory(p.join(gameDir, modpackTmpDir));
  await tmp.create(recursive: true);
  final ready = <(String, String)>[]; // (temporaneo, relativo)
  try {
    for (final (i, f) in plan.index.files.indexed) {
      final dest = p.join(tmp.path, '$i');
      await dl.download(f.downloads, dest, sha1: f.sha1, sha512: f.sha512, size: f.size);
      ready.add((dest, f.path));
    }
    for (final (i, e) in plan.overrides.indexed) {
      // overrides/x e client-overrides/x finiscono in x
      final rel = e.zipPath.substring(e.zipPath.indexOf('/') + 1);
      final dest = p.join(tmp.path, 'o$i');
      await File(insideRoot(serverRoot, e.serverPath)).copy(dest);
      ready.add((dest, rel));
    }
  } on Object catch (e) {
    await tmp.delete(recursive: true).catchError((Object _) => tmp);
    throw LauncherProfileError('download', e);
  }
  final placedFile = File(p.join(gameDir, launcherPlacedFile));
  final before = <String>{};
  if (placedFile.existsSync()) {
    try {
      before.addAll(
        (jsonDecode(placedFile.readAsStringSync()) as List<Object?>).whereType<String>(),
      );
    } on Object {
      // file rovinato: non si toglie niente
    }
  }
  final placed = {for (final r in ready) r.$2};
  for (final rel in before.difference(placed)) {
    final f = File(insideRoot(gameDir, rel));
    if (f.existsSync()) await f.delete();
  }
  for (final (src, rel) in ready) {
    final to = insideRoot(gameDir, rel);
    await Directory(p.dirname(to)).create(recursive: true);
    await File(src).rename(to);
  }
  await tmp.delete(recursive: true).catchError((Object _) => tmp);
  await writeFileAtomic(placedFile.path, utf8.encode(jsonEncode(placed.toList()..sort())));

  // 3. JSON della versione del loader
  if (versionJson != null) {
    await writeFileAtomic(
      p.join(launcherDir, 'versions', versionId, '$versionId.json'),
      versionJson,
    );
  }

  // 4. copia di sicurezza e profilo
  final stamp = now.toUtc().toIso8601String().replaceAll(RegExp('[^0-9]'), '').substring(0, 14);
  final backup = '${profiles.path}.minesync-$stamp.bak';
  await profiles.copy(backup);
  final key = 'minesync-$spaceId';
  final all = json['profiles'] is Map<String, Object?>
      ? Map<String, Object?>.of(json['profiles']! as Map<String, Object?>)
      : <String, Object?>{};
  final old = all[key] is Map<String, Object?>
      ? all[key]! as Map<String, Object?>
      : const <String, Object?>{};
  final iso = now.toUtc().toIso8601String();
  all[key] = {
    ...old,
    'name': 'MineSync ($displayName)',
    'type': 'custom',
    'icon': old['icon'] ?? 'Grass',
    'lastVersionId': versionId,
    'gameDir': gameDir,
    'created': old['created'] ?? iso,
    'lastUsed': old['lastUsed'] ?? iso,
  };
  json['profiles'] = all;
  await writeFileAtomic(
    profiles.path,
    utf8.encode('${const JsonEncoder.withIndent('  ').convert(json)}\n'),
  );
  return LauncherProfileResult(
    profileKey: key,
    versionId: versionId,
    gameDir: gameDir,
    backup: backup,
    files: ready.length,
  );
}
