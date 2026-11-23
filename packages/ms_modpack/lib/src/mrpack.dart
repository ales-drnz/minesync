// Il formato .mrpack di Modrinth (versione 1, https://support.modrinth.com/
// en/articles/8802351-modrinth-modpack-format-mrpack): uno ZIP con
// `modrinth.index.json`, `overrides/`, `client-overrides/` e
// `server-overrides/`. Qui: il modello dell'indice, l'import verso un
// [Pack] (con la validazione dei percorsi di ms_protocol) e l'export del
// pacchetto per i giocatori come piano puro, scritto poi da chi ha i byte
// (lib/io.dart, o l'hub in streaming dai blob).
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:ms_protocol/ms_protocol.dart';

import 'modrinth_models.dart';
import 'pack.dart';

/// Nome dell'indice dentro il `.mrpack`.
const String mrpackIndexName = 'modrinth.index.json';

/// Host da cui un `.mrpack` può far scaricare i file (regola del formato:
/// i launcher rifiutano gli altri).
const Set<String> mrpackAllowedHosts = {
  'cdn.modrinth.com',
  'github.com',
  'raw.githubusercontent.com',
  'gitlab.com',
};

/// Tetto all'indice.
const int mrpackIndexMax = 16 << 20;

/// Un problema di un `.mrpack`.
final class MrpackError implements Exception {
  const MrpackError(this.reason, {this.path});

  /// Codice breve: `badZip`, `noIndex`, `badIndex`, `badPath`, `tooLarge`,
  /// `unsupportedGame`, `unsupportedFormat`, `badLoader`.
  final String reason;
  final String? path;

  @override
  String toString() => 'MrpackError($reason${path == null ? '' : ': $path'})';
}

/// Ambiente di un file (`env`).
final class MrpackEnv {
  const MrpackEnv(this.client, this.server);
  final MrEnv client;
  final MrEnv server;
}

/// Una voce di `files`.
final class MrpackFile {
  const MrpackFile({
    required this.path,
    required this.sha1,
    required this.sha512,
    required this.size,
    required this.downloads,
    this.env,
  });

  factory MrpackFile.fromJson(Object? j) {
    final m = _obj(j, 'file');
    final h = _obj(m['hashes'], 'hashes');
    final path = _str(m, 'path');
    final sha1 = _str(h, 'sha1').toLowerCase(), sha512 = _str(h, 'sha512').toLowerCase();
    if (!isSha1(sha1) || !isSha512(sha512)) {
      throw MrpackError('badIndex', path: path);
    }
    final env = m['env'];
    final downloads = m['downloads'];
    if (downloads is! List<Object?> || downloads.any((d) => d is! String)) {
      throw MrpackError('badIndex', path: path);
    }
    final size = m['fileSize'];
    if (size is! int || size < 0) throw MrpackError('badIndex', path: path);
    return MrpackFile(
      path: path,
      sha1: sha1,
      sha512: sha512,
      size: size,
      downloads: downloads.cast<String>(),
      env: env is Map<String, Object?>
          ? MrpackEnv(MrEnv.parse(env['client']), MrEnv.parse(env['server']))
          : null,
    );
  }

  final String path;
  final String sha1;
  final String sha512;
  final int size;
  final List<String> downloads;
  final MrpackEnv? env;

  Map<String, Object?> toJson() => {
    'path': path,
    'hashes': {'sha1': sha1, 'sha512': sha512},
    if (env != null) 'env': {'client': env!.client.name, 'server': env!.server.name},
    'downloads': downloads,
    'fileSize': size,
  };
}

/// Chiavi di `dependencies` per loader.
const Map<Loader, String> mrpackLoaderKeys = {
  Loader.fabric: 'fabric-loader',
  Loader.quilt: 'quilt-loader',
  Loader.forge: 'forge',
  Loader.neoforge: 'neoforge',
};

/// `modrinth.index.json`.
final class MrpackIndex {
  const MrpackIndex({
    required this.versionId,
    required this.name,
    required this.files,
    required this.dependencies,
    this.summary,
  });

  factory MrpackIndex.fromJson(Object? j) {
    final m = _obj(j, 'index');
    if (m['formatVersion'] != 1) throw const MrpackError('unsupportedFormat');
    if (m['game'] != 'minecraft') throw const MrpackError('unsupportedGame');
    final files = m['files'];
    if (files is! List<Object?>) throw const MrpackError('badIndex');
    final deps = _obj(m['dependencies'], 'dependencies');
    return MrpackIndex(
      versionId: _str(m, 'versionId'),
      name: _str(m, 'name'),
      summary: m['summary'] is String ? m['summary']! as String : null,
      files: [for (final f in files) MrpackFile.fromJson(f)],
      dependencies: {
        for (final e in deps.entries)
          e.key: e.value is String ? e.value! as String : throw const MrpackError('badIndex'),
      },
    );
  }

  final String versionId;
  final String name;
  final String? summary;
  final List<MrpackFile> files;

  /// `minecraft`, `fabric-loader`, `quilt-loader`, `forge`, `neoforge`.
  final Map<String, String> dependencies;

  String? get mcVersion => dependencies['minecraft'];

  /// Il loader dichiarato (vanilla se nessuno). [MrpackError] se ce n'è più
  /// di uno.
  (Loader, String?) get loader {
    final found = [
      for (final e in mrpackLoaderKeys.entries)
        if (dependencies[e.value] case final v?) (e.key, v),
    ];
    if (found.length > 1) throw const MrpackError('badLoader');
    return found.isEmpty ? (Loader.vanilla, null) : found.first;
  }

  Map<String, Object?> toJson() => {
    'formatVersion': 1,
    'game': 'minecraft',
    'versionId': versionId,
    'name': name,
    'summary': ?summary,
    'files': [for (final f in files) f.toJson()],
    'dependencies': dependencies,
  };

  /// Byte dell'indice (JSON con rientro, ordine fisso).
  Uint8List encode() =>
      Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(toJson())));
}

// ---------------------------------------------------------------- sorgenti dagli URL

final _cdnRe = RegExp(r'^/data/([A-Za-z0-9]{1,64})/versions/([A-Za-z0-9]{1,64})/[^/]+$');

/// Progetto e versione Modrinth da un URL del CDN
/// (`https://cdn.modrinth.com/data/<progetto>/versions/<versione>/<file>`).
(String, String)? modrinthIdsFromUrl(String url) {
  final u = Uri.tryParse(url);
  if (u == null || u.host != 'cdn.modrinth.com') return null;
  final m = _cdnRe.firstMatch(u.path);
  return m == null ? null : (m[1]!, m[2]!);
}

bool _isCurseForgeCdn(String url) {
  final h = Uri.tryParse(url)?.host ?? '';
  return h == 'edge.forgecdn.net' || h == 'mediafilez.forgecdn.net';
}

/// Lato e facoltativa da `env` (senza `env`: tutti e due, obbligatoria).
(PackSide, bool) sideFromMrpackEnv(MrpackEnv? env) {
  if (env == null) return (PackSide.both, false);
  final c = env.client != MrEnv.unsupported, s = env.server != MrEnv.unsupported;
  if (c && s) return (PackSide.both, env.client == MrEnv.optional);
  if (c) return (PackSide.client, env.client == MrEnv.optional);
  if (s) return (PackSide.server, false);
  // né client né server: non dovrebbe esistere; meglio sul server
  return (PackSide.server, false);
}

// ---------------------------------------------------------------- import

/// Un file da scrivere nella cartella del server.
final class PackFileOut {
  const PackFileOut(this.path, this.bytes);

  /// Percorso relativo alla radice del server.
  final String path;
  final Uint8List bytes;
}

/// Il risultato dell'import di un `.mrpack`.
final class MrpackImport {
  const MrpackImport({
    required this.index,
    required this.pack,
    required this.files,
    this.warnings = const [],
  });

  final MrpackIndex index;

  /// Il pack del nuovo server. Le mod da scaricare sono in [Pack.mods] con
  /// i loro URL e hash; i jar dentro gli override diventano voci `manual`.
  final Pack pack;

  /// File degli override, già al loro posto nella cartella del server:
  /// `overrides/` e `server-overrides/` nella radice (i secondi vincono),
  /// `client-overrides/` sotto [clientOverridesDir].
  final List<PackFileOut> files;

  /// Avvisi (in inglese, per i log): file ignorati.
  final List<String> warnings;
}

String _checkInPath(String p) {
  final bad = checkPath(p);
  if (bad != null) throw MrpackError('badPath', path: p);
  if (p.toLowerCase() == packFileName) throw MrpackError('badPath', path: p);
  return p;
}

/// Legge un `.mrpack` ([bytes]) e lo trasforma in pack e file del server.
/// Rifiuta ([MrpackError]) percorsi non validi (`..`, assoluti, riservati:
/// le stesse regole dei manifest), un indice mancante o rotto, più di
/// [maxBytes] decompressi. Gli hash dei file da scaricare si verificano al
/// download.
MrpackImport readMrpack(Uint8List bytes, {int maxBytes = 1 << 30, String? name}) {
  final Archive zip;
  if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4b) throw const MrpackError('badZip');
  try {
    zip = ZipDecoder().decodeBytes(bytes);
  } on Object {
    throw const MrpackError('badZip');
  }
  var total = 0;
  for (final f in zip.files) {
    if (f.isFile) total += f.size;
    if (total > maxBytes) throw const MrpackError('tooLarge');
  }
  final idx = zip.findFile(mrpackIndexName);
  if (idx == null || !idx.isFile) throw const MrpackError('noIndex');
  if (idx.size > mrpackIndexMax) throw const MrpackError('tooLarge', path: mrpackIndexName);
  final MrpackIndex index;
  try {
    index = MrpackIndex.fromJson(jsonDecode(utf8.decode(idx.content)));
  } on MrpackError {
    rethrow;
  } on FormatException {
    throw const MrpackError('badIndex');
  }
  final mc = index.mcVersion;
  if (mc == null || mc.isEmpty) throw const MrpackError('badIndex', path: 'dependencies.minecraft');
  final (loader, loaderVersion) = index.loader;

  final warnings = <String>[];
  // override: prima overrides/, poi server-overrides/ che li sostituisce
  final out = <String, PackFileOut>{};
  final shared = <String>{};
  final jars = <String, (Uint8List, PackSide)>{};
  for (final (prefix, dest, side) in const [
    ('overrides/', '', PackSide.both),
    ('server-overrides/', '', PackSide.server),
    ('client-overrides/', '$clientOverridesDir/', PackSide.client),
  ]) {
    for (final f in zip.files) {
      final n = f.name.replaceAll(r'\', '/');
      if (!n.startsWith(prefix)) continue;
      if (!f.isFile) continue;
      final rel = _checkInPath(n.substring(prefix.length));
      final target = _checkInPath('$dest$rel');
      if (rel.toLowerCase().startsWith('$clientOverridesDir/') && side != PackSide.client) {
        throw MrpackError('badPath', path: n);
      }
      final data = f.content;
      if (isModLocation(target)) {
        jars[target.toLowerCase()] = (data, side);
      }
      out[target.toLowerCase()] = PackFileOut(target, data);
      if (side == PackSide.both && !isModLocation(target)) {
        final top = rel.split('/');
        shared.add(top.length == 1 ? top.first : '${top.first}/**');
      }
    }
  }
  for (final f in zip.files) {
    final n = f.name.replaceAll(r'\', '/');
    if (n == mrpackIndexName || !f.isFile) continue;
    if (n.startsWith('overrides/') ||
        n.startsWith('server-overrides/') ||
        n.startsWith('client-overrides/')) {
      continue;
    }
    warnings.add('ignored: $n');
  }

  final mods = <PackMod>[];
  final paths = <String>{};
  final projects = <String>{};
  for (final f in index.files) {
    final bad = checkModPath(f.path);
    if (bad != null) throw MrpackError('badPath', path: f.path);
    if (!paths.add(caseFoldKey(f.path))) throw MrpackError('badIndex', path: f.path);
    final https = [
      for (final d in f.downloads)
        if (isHttpsUrl(d)) d,
    ];
    if (https.isEmpty) throw MrpackError('badIndex', path: f.path);
    final (side, optional) = sideFromMrpackEnv(f.env);
    var ids = https.map(modrinthIdsFromUrl).nonNulls.firstOrNull;
    // due file dello stesso progetto: il secondo resta un file con URL
    if (ids != null && !projects.add(ids.$1)) {
      warnings.add('second file of project ${ids.$1}: kept as a plain download');
      ids = null;
    }
    final cf = https.any(_isCurseForgeCdn);
    mods.add(
      PackMod(
        path: f.path,
        sha1: f.sha1,
        sha512: f.sha512,
        size: f.size,
        side: side,
        optional: optional,
        source: ids != null
            ? PackSource.modrinth
            : (cf ? PackSource.curseforge : PackSource.manual),
        projectId: ids?.$1,
        versionId: ids?.$2,
        downloads: https,
        // un URL diretto del CDN di CurseForge vuol dire distribuzione permessa
        curseforge: cf && ids == null ? const CurseForgeRef(allowDistribution: true) : null,
      ),
    );
  }
  // jar negli override: voci manuali con gli hash calcolati qui
  for (final e in jars.entries) {
    final (data, side) = e.value;
    final target = out[e.key]!.path;
    final instPath = side == PackSide.client
        ? target.substring(clientOverridesDir.length + 1)
        : target;
    if (!paths.add(caseFoldKey(instPath))) {
      warnings.add('override duplicates a listed file: $instPath');
      continue;
    }
    mods.add(
      PackMod(
        path: instPath,
        sha1: crypto.sha1.convert(data).toString(),
        sha512: crypto.sha512.convert(data).toString(),
        size: data.length,
        side: side,
        source: PackSource.manual,
      ),
    );
  }
  // le mod solo client si scaricano al loro posto (client-overrides/mods/)
  final Pack pack;
  try {
    pack = Pack(
      name: name ?? index.name,
      mcVersion: mc,
      loader: loader,
      loaderVersion: loaderVersion,
      mods: mods,
      shared: shared.toList()..sort(),
    );
  } on FormatException catch (e) {
    throw MrpackError('badIndex', path: e.message);
  }
  final files = out.values.toList()..sort((a, b) => comparePaths(a.path, b.path));
  return MrpackImport(index: index, pack: pack, files: files, warnings: warnings);
}

// ---------------------------------------------------------------- export

/// Una voce di override del pacchetto: il file [serverPath] della cartella
/// del server va in [zipPath].
final class PackZipEntry {
  const PackZipEntry(this.zipPath, this.serverPath);
  final String zipPath;
  final String serverPath;

  @override
  String toString() => '$serverPath → $zipPath';
}

/// Il piano del pacchetto per i giocatori.
final class ClientPackPlan {
  const ClientPackPlan({
    required this.pack,
    required this.index,
    required this.overrides,
    required this.missing,
    required this.modsZip,
  });

  final Pack pack;
  final MrpackIndex index;

  /// File da copiare dalla cartella del server dentro il `.mrpack`.
  final List<PackZipEntry> overrides;

  /// Mod per i giocatori che il pacchetto non può contenere.
  final List<PackMissingMod> missing;

  /// Le voci dello ZIP «solo le mod» (`mods/x.jar` ← posizione nel server).
  final List<PackZipEntry> modsZip;

  /// Il riassunto per l'API dell'hub (senza le dimensioni dei file, che
  /// conosce chi li scrive).
  ClientPack summary({
    required int n,
    String? fileName,
    int? size,
    String? modsZipName,
    int? modsZipSize,
  }) {
    final mods = pack.mods;
    return ClientPack(
      n: n,
      available: true,
      name: pack.name,
      mcVersion: pack.mcVersion,
      loader: pack.loader,
      loaderVersion: pack.loaderVersion,
      mods: mods.length,
      required: mods.where((m) => !m.disabled && m.side.onClient && !m.optional).length,
      optional: mods.where((m) => !m.disabled && m.side.onClient && m.optional).length,
      serverOnly: mods.where((m) => !m.disabled && m.side == PackSide.server).length,
      manual: mods.where((m) => m.source == PackSource.manual).length,
      disabled: mods.where((m) => m.disabled).length,
      missing: missing,
      fileName: fileName,
      size: size,
      modsZipName: modsZipName,
      modsZipSize: modsZipSize,
    );
  }
}

/// Le dipendenze dell'indice per il pack.
Map<String, String> mrpackDependencies(Pack p) => {
  'minecraft': p.mcVersion,
  // la versione del loader c'è sempre tranne che per vanilla (senza chiave)
  ?mrpackLoaderKeys[p.loader]: p.loaderVersion ?? '',
};

/// Pianifica il pacchetto per i giocatori di [pack] dai file [serverFiles]
/// (percorsi della cartella del server, cioè della generazione):
/// - mod attive lato client: per URL se ne hanno uno su un host ammesso,
///   altrimenti il jar dal server come override (`overrides/` se serve a
///   tutti e due, `client-overrides/` se solo client); una mod CurseForge
///   con la distribuzione vietata, o un jar che manca, va in `missing`;
/// - file che combaciano con [Pack.shared] → `overrides/`;
/// - file sotto `client-overrides/` (che non siano mod del pack) →
///   `client-overrides/`.
/// [chosenOptional] (chiavi [PackMod.key]): sul PC di un giocatore, le
/// facoltative scelte (diventano obbligatorie) e le altre fuori; null (hub)
/// le tiene tutte come facoltative.
ClientPackPlan planClientPack(
  Pack pack,
  Iterable<String> serverFiles, {
  required String versionId,
  String? name,
  Set<String>? chosenOptional,
  Set<String> allowedHosts = mrpackAllowedHosts,
}) {
  final present = {for (final f in serverFiles) caseFoldKey(f): f};
  final files = <MrpackFile>[];
  final overrides = <PackZipEntry>[];
  final missing = <PackMissingMod>[];
  final modsZip = <PackZipEntry>[];
  final modLocations = <String>{
    for (final m in pack.mods) ...[caseFoldKey(m.location), caseFoldKey(m.diskLocation)],
  };
  for (final m in pack.mods) {
    if (m.disabled || !m.side.onClient) continue;
    if (m.optional && chosenOptional != null && !chosenOptional.contains(m.key)) continue;
    final optional = m.optional && chosenOptional == null;
    final cfBlocked =
        m.source == PackSource.curseforge && !(m.curseforge?.allowDistribution ?? false);
    final serverPath = present[caseFoldKey(m.location)];
    if (serverPath != null && !cfBlocked) modsZip.add(PackZipEntry(m.path, serverPath));
    final urls = [
      for (final d in m.downloads)
        if (allowedHosts.contains(Uri.parse(d).host)) d,
    ];
    if (urls.isNotEmpty && !cfBlocked) {
      files.add(
        MrpackFile(
          path: m.path,
          sha1: m.sha1,
          sha512: m.sha512,
          size: m.size,
          downloads: urls,
          env: MrpackEnv(
            optional ? MrEnv.optional : MrEnv.required,
            m.side.onServer ? MrEnv.required : MrEnv.unsupported,
          ),
        ),
      );
    } else if (serverPath != null && !cfBlocked) {
      overrides.add(
        PackZipEntry(
          m.side == PackSide.client ? 'client-overrides/${m.path}' : 'overrides/${m.path}',
          serverPath,
        ),
      );
    } else {
      missing.add(
        PackMissingMod(
          file: m.file,
          source: m.source.name,
          name: m.name,
          pageUrl:
              m.curseforge?.pageUrl ??
              (m.projectId != null ? 'https://modrinth.com/project/${m.projectId}' : null),
        ),
      );
    }
  }
  final shared = pack.shared.isEmpty ? null : Exclusions(pack.shared);
  final sorted = present.values.toList()..sort(comparePaths);
  for (final f in sorted) {
    final k = caseFoldKey(f);
    if (k == packFileName || modLocations.contains(k)) continue;
    if (k.startsWith('$clientOverridesDir/')) {
      // le mod spente o non del pack in client-overrides/mods/ restano fuori
      if (isModLocation(f)) continue;
      overrides.add(
        PackZipEntry('client-overrides/${f.substring(clientOverridesDir.length + 1)}', f),
      );
      continue;
    }
    if (shared == null || isModLocation(f)) continue;
    final hit = shared.firstMatch(f);
    if (hit != null && !systemExclusions.contains(hit)) {
      overrides.add(PackZipEntry('overrides/$f', f));
    }
  }
  overrides.sort((a, b) => comparePaths(a.zipPath, b.zipPath));
  modsZip.sort((a, b) => comparePaths(a.zipPath, b.zipPath));
  final index = MrpackIndex(
    versionId: versionId,
    name: name ?? pack.name ?? 'MineSync',
    summary: 'MineSync',
    files: files,
    dependencies: mrpackDependencies(pack),
  );
  return ClientPackPlan(
    pack: pack,
    index: index,
    overrides: overrides,
    missing: missing,
    modsZip: modsZip,
  );
}

/// Scrive il `.mrpack` del piano in memoria; [read] dà i byte di un file del
/// server (null se manca: [StateError]).
Uint8List writeMrpack(ClientPackPlan plan, Uint8List? Function(String serverPath) read) {
  final a = Archive()..add(ArchiveFile.bytes(mrpackIndexName, plan.index.encode()));
  for (final e in plan.overrides) {
    final b = read(e.serverPath);
    if (b == null) throw StateError('file mancante: ${e.serverPath}');
    a.add(ArchiveFile.bytes(e.zipPath, b));
  }
  return ZipEncoder().encodeBytes(a);
}

// ---------------------------------------------------------------- helper

Map<String, Object?> _obj(Object? v, String what) =>
    v is Map<String, Object?> ? v : throw MrpackError('badIndex', path: what);

String _str(Map<String, Object?> m, String k) {
  final v = m[k];
  return v is String ? v : throw MrpackError('badIndex', path: k);
}
