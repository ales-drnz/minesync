// Metadati del mondo ricavati da file e percorsi, senza leggere il disco:
// server.properties → ServerProperties, riassunto WorldChip dai percorsi
// presenti, nome della cartella del mondo. Servono all'hub (che lavora sui
// manifest) e all'app desktop.
import 'package:ms_protocol/ms_protocol.dart';

import 'detect.dart' show compareVersions;

/// Cartella del mondo: `level-name` di server.properties, `world` se manca.
/// Un valore che non è un percorso relativo semplice vale `world`.
String levelFolder(Map<String, String> props) {
  final v = props['level-name']?.trim() ?? '';
  if (v.isEmpty ||
      v.startsWith('/') ||
      v.contains('\\') ||
      v.split('/').any((s) => s.isEmpty || s == '.' || s == '..')) {
    return 'world';
  }
  return v;
}

final _formatting = RegExp('§.?', dotAll: true);

/// Toglie i codici di formattazione `§x` di Minecraft.
String stripFormatting(String s) => s.replaceAll(_formatting, '');

/// Il sottoinsieme di server.properties che l'hub mostra. Le chiavi assenti
/// o non valide restano null.
ServerProperties serverPropertiesInfo(Map<String, String> props, {int? whitelistCount}) {
  int? i(String k) => int.tryParse(props[k]?.trim() ?? '');
  bool? b(String k) => switch (props[k]?.trim().toLowerCase()) {
    'true' => true,
    'false' => false,
    _ => null,
  };
  final port = i('server-port');
  final motd = props['motd'];
  return ServerProperties(
    motd: motd == null ? null : stripFormatting(motd),
    maxPlayers: i('max-players'),
    pvp: b('pvp'),
    whitelist: b('white-list'),
    whitelistCount: whitelistCount,
    viewDistance: i('view-distance'),
    simulationDistance: i('simulation-distance'),
    port: port != null && port > 0 && port < 65536 ? port : null,
    onlineMode: b('online-mode'),
  );
}

/// Riassunto del server dai percorsi dei file (con `/`): loader e sua
/// versione dalle librerie, versione di Minecraft da [mcVersion] (di norma
/// `Version.Name` di level.dat) o dalle librerie vanilla, mod = jar in
/// `mods/`. [levelDir] è la cartella del mondo.
WorldChip chipFromPaths(Iterable<String> paths, {String? mcVersion, String levelDir = 'world'}) {
  final top = <String>{};
  final libs = <String, Set<String>>{}; // gruppo/artefatto → versioni
  var mods = 0;
  var level = false;
  for (final path in paths) {
    final segs = path.split('/');
    if (segs.length == 1) top.add(path.toLowerCase());
    if (segs.length == 2 && segs[0] == 'mods' && segs[1].toLowerCase().endsWith('.jar')) mods++;
    if (segs[0] == '.fabric') top.add('.fabric/');
    if (path == '$levelDir/level.dat') level = true;
    if (segs.length >= 5 && segs[0] == 'libraries') {
      // libraries/<gruppo…>/<artefatto>/<versione>/<file>
      final key = segs.sublist(1, segs.length - 2).join('/');
      (libs[key] ??= {}).add(segs[segs.length - 2]);
    }
  }
  bool hasLib(String prefix) => libs.keys.any((k) => k == prefix || k.startsWith('$prefix/'));
  String? newest(String artifact) {
    final vs = libs[artifact];
    if (vs == null || vs.isEmpty) return null;
    return vs.reduce((a, b) => compareVersions(a, b) >= 0 ? a : b);
  }

  String? afterDash(String? v) {
    if (v == null) return null;
    final i = v.indexOf('-');
    return i < 0 ? v : v.substring(i + 1);
  }

  Loader? loader;
  String? loaderVersion;
  // Quilt installa anche le librerie Fabric: il suo jar di avvio viene prima
  if (top.contains('quilt-server-launch.jar') || hasLib('org/quiltmc')) {
    loader = Loader.quilt;
    loaderVersion = newest('org/quiltmc/quilt-loader');
  } else if (top.contains('fabric-server-launch.jar') ||
      top.contains('.fabric/') ||
      hasLib('net/fabricmc/fabric-loader')) {
    loader = Loader.fabric;
    loaderVersion = newest('net/fabricmc/fabric-loader');
  } else if (hasLib('net/neoforged')) {
    loader = Loader.neoforge;
    // dalla 1.20.2 net/neoforged/neoforge/<ver>; la 1.20.1 net/neoforged/forge/<mc>-<ver>
    loaderVersion = newest('net/neoforged/neoforge') ?? afterDash(newest('net/neoforged/forge'));
  } else if (hasLib('net/minecraftforge')) {
    loader = Loader.forge;
    loaderVersion = afterDash(newest('net/minecraftforge/forge'));
  } else {
    final paper = top.where((n) => n.startsWith('paper') && n.endsWith('.jar')).toList()..sort();
    if (paper.isNotEmpty) {
      loader = Loader.paper;
      // paper-<mc>-<build>.jar
      final parts = paper.last.substring(0, paper.last.length - 4).split('-');
      if (parts.length >= 3) loaderVersion = parts.last;
    } else if (level || top.contains('server.jar')) {
      loader = Loader.vanilla;
    }
  }
  var mc = mcVersion;
  if (mc == null || mc.isEmpty) {
    final v = newest('net/minecraft/server');
    mc = v?.split('-').first;
  }
  return WorldChip(mcVersion: mc, loader: loader, loaderVersion: loaderVersion, mods: mods);
}
