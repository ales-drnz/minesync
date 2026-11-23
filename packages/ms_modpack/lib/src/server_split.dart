// Server da un modpack pubblicato solo per i giocatori (es. un pack che su
// Modrinth ha `server_side: unsupported` e nessun server pack): dal
// `.mrpack` si tengono sul server le mod che ci girano e si lasciano ai
// giocatori quelle solo client. Le mod solo client restano nel pack con lato
// `client` (vanno in `client-overrides/mods/`, il server non le carica, il
// pacchetto per i giocatori le contiene). Ordine delle prove per ogni voce:
// `env` dell'indice, lato del progetto su Modrinth, `environment` del
// `fabric.mod.json`/`quilt.mod.json` per i jar negli override; quel che
// resta senza informazioni lo decide l'admin (di base resta sul server).
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:ms_protocol/ms_protocol.dart' show caseFoldKey, comparePaths;

import 'modrinth.dart';
import 'modrinth_models.dart';
import 'mrpack.dart';
import 'pack.dart';

/// Dove finisce una voce.
enum SplitFate {
  /// Installata sul server (e, se `both`, anche dai giocatori).
  server,

  /// Solo per i giocatori: esclusa dal server.
  clientOnly,

  /// Non si sa: decide l'admin (di base sul server).
  unknown,
}

/// Da dove viene la decisione.
enum SplitReason {
  /// `env` di `modrinth.index.json`, o la cartella dell'override.
  packIndex,

  /// `client_side`/`server_side` del progetto su Modrinth.
  modrinth,

  /// `environment` nel `fabric.mod.json` o `quilt.mod.json` del jar.
  jar,

  /// Resource pack o shader: contenuto solo per il client.
  clientContent,

  /// Nessuna informazione.
  none,
}

/// Una voce del pack con il suo destino.
final class SplitEntry {
  const SplitEntry(this.mod, this.fate, this.reason);
  final PackMod mod;
  final SplitFate fate;
  final SplitReason reason;

  String get name => mod.name ?? mod.file;
  String get key => mod.key;

  @override
  String toString() => '${mod.path}: ${fate.name} (${reason.name})';
}

/// La divisione di un import fra server e giocatori.
final class ServerSplit {
  ServerSplit(this.source, List<SplitEntry> entries)
    : entries = List.unmodifiable(
        entries.toList()..sort((a, b) => comparePaths(a.mod.path, b.mod.path)),
      );

  final MrpackImport source;
  final List<SplitEntry> entries;

  List<SplitEntry> _of(SplitFate f) => [
    for (final e in entries)
      if (e.fate == f) e,
  ];

  List<SplitEntry> get onServer => _of(SplitFate.server);
  List<SplitEntry> get clientOnly => _of(SplitFate.clientOnly);
  List<SplitEntry> get unknown => _of(SplitFate.unknown);

  /// Quante voci vanno sul server tenendo fuori le sconosciute [excluded].
  int serverCount(Set<String> excluded) =>
      onServer.length + unknown.where((e) => !excluded.contains(e.key)).length;

  /// Quante restano solo ai giocatori con le sconosciute [excluded] fuori.
  int clientCount(Set<String> excluded) =>
      clientOnly.length + unknown.where((e) => excluded.contains(e.key)).length;

  /// L'import per il server: le voci solo client (e le sconosciute in
  /// [excluded], chiavi [PackMod.key]) diventano lato `client`; i loro jar
  /// negli override passano sotto `client-overrides/`. I nomi trovati su
  /// Modrinth restano nel pack.
  MrpackImport apply({Set<String> excluded = const {}}) {
    final moved = <String>{};
    final mods = <PackMod>[];
    for (final e in entries) {
      final toClient =
          e.fate == SplitFate.clientOnly ||
          (e.fate == SplitFate.unknown && excluded.contains(e.key));
      if (toClient && e.mod.side != PackSide.client) {
        mods.add(e.mod.copyWith(side: PackSide.client));
        moved.add(caseFoldKey(e.mod.path));
      } else {
        mods.add(e.mod);
      }
    }
    final files = [
      for (final f in source.files)
        moved.contains(caseFoldKey(f.path))
            ? PackFileOut('$clientOverridesDir/${f.path}', f.bytes)
            : f,
    ]..sort((a, b) => comparePaths(a.path, b.path));
    return MrpackImport(
      index: source.index,
      pack: source.pack.copyWith(mods: mods),
      files: files,
      warnings: source.warnings,
    );
  }
}

/// `environment` di un jar Fabric/Quilt: `client`, `server`, `*` o null se
/// il jar non lo dice (o non si legge).
String? jarEnvironment(List<int> jar) {
  try {
    final zip = ZipDecoder().decodeBytes(jar);
    final fabric = zip.findFile('fabric.mod.json');
    if (fabric != null && fabric.isFile && fabric.size < (1 << 20)) {
      final j = jsonDecode(utf8.decode(fabric.content, allowMalformed: true));
      if (j is Map<String, Object?> && j['environment'] is String) {
        return j['environment']! as String;
      }
    }
    final quilt = zip.findFile('quilt.mod.json');
    if (quilt != null && quilt.isFile && quilt.size < (1 << 20)) {
      final j = jsonDecode(utf8.decode(quilt.content, allowMalformed: true));
      if (j is Map<String, Object?> &&
          j['minecraft'] is Map<String, Object?> &&
          (j['minecraft']! as Map<String, Object?>)['environment'] is String) {
        return (j['minecraft']! as Map<String, Object?>)['environment']! as String;
      }
      final ql = j is Map<String, Object?> ? j['quilt_loader'] : null;
      if (ql is Map<String, Object?> && ql['minecraft'] is Map<String, Object?>) {
        final env = (ql['minecraft']! as Map<String, Object?>)['environment'];
        if (env is String) return env;
      }
    }
  } on Object {
    // non è un jar leggibile
  }
  return null;
}

bool _clientContent(String path) {
  final l = path.toLowerCase();
  return l.startsWith('resourcepacks/') || l.startsWith('shaderpacks/');
}

/// Divide [imp] fra server e giocatori senza rete. [projects]: progetti
/// Modrinth per id; [projectBySha1]: id del progetto per lo SHA-1 dei file
/// che non hanno un URL di Modrinth (riconosciuti per hash).
ServerSplit splitForServer(
  MrpackImport imp, {
  Map<String, MrProject> projects = const {},
  Map<String, String> projectBySha1 = const {},
}) {
  final withEnv = {
    for (final f in imp.index.files)
      if (f.env != null) caseFoldKey(f.path),
  };
  final bytes = {for (final f in imp.files) caseFoldKey(f.path): f.bytes};
  final out = <SplitEntry>[];
  for (final m0 in imp.pack.mods) {
    final pid = m0.projectId ?? projectBySha1[m0.sha1];
    final pr = pid == null ? null : projects[pid];
    final m = pr != null && m0.name == null && pr.title.isNotEmpty
        ? m0.copyWith(name: pr.title)
        : m0;
    SplitEntry e(SplitFate f, SplitReason r) => SplitEntry(m, f, r);
    if (m.side == PackSide.client) {
      out.add(e(SplitFate.clientOnly, SplitReason.packIndex));
      continue;
    }
    if (m.side == PackSide.server) {
      out.add(e(SplitFate.server, SplitReason.packIndex));
      continue;
    }
    if (pr != null && pr.serverSide == MrEnv.unsupported) {
      out.add(e(SplitFate.clientOnly, SplitReason.modrinth));
      continue;
    }
    final jar = bytes[caseFoldKey(m.location)];
    final jarEnv = jar == null ? null : jarEnvironment(jar);
    if (jarEnv == 'client') {
      out.add(e(SplitFate.clientOnly, SplitReason.jar));
      continue;
    }
    if (withEnv.contains(caseFoldKey(m.path))) {
      out.add(e(SplitFate.server, SplitReason.packIndex));
      continue;
    }
    if (pr != null && pr.serverSide.supported) {
      out.add(e(SplitFate.server, SplitReason.modrinth));
      continue;
    }
    if (jarEnv == 'server' || jarEnv == '*') {
      out.add(e(SplitFate.server, SplitReason.jar));
      continue;
    }
    if (_clientContent(m.path)) {
      out.add(e(SplitFate.clientOnly, SplitReason.clientContent));
      continue;
    }
    out.add(e(SplitFate.unknown, SplitReason.none));
  }
  return ServerSplit(imp, out);
}

/// Come [splitForServer], chiedendo a Modrinth i progetti delle voci (per id
/// dagli URL del CDN, gli altri file per SHA-1). Se Modrinth non risponde la
/// divisione si fa con quel che dice il `.mrpack`.
Future<ServerSplit> resolveServerSplit(MrpackImport imp, ModrinthClient modrinth) async {
  final ids = <String>{for (final m in imp.pack.mods) ?m.projectId};
  final bySha = <String, String>{};
  final projects = <String, MrProject>{};
  try {
    final unknownHashes = [
      for (final m in imp.pack.mods)
        if (m.projectId == null) m.sha1,
    ];
    if (unknownHashes.isNotEmpty) {
      final found = await modrinth.versionFiles(unknownHashes);
      for (final e in found.entries) {
        bySha[e.key] = e.value.projectId;
        ids.add(e.value.projectId);
      }
    }
    final l = ids.toList()..sort();
    for (var i = 0; i < l.length; i += 100) {
      final chunk = l.sublist(i, i + 100 > l.length ? l.length : i + 100);
      for (final p in await modrinth.projects(chunk)) {
        projects[p.id] = p;
      }
    }
  } on ModrinthUnavailable {
    // senza Modrinth: si va con l'indice e i jar
  } on ModrinthException {
    // risposta strana: idem
  }
  return splitForServer(imp, projects: projects, projectBySha1: bySha);
}
