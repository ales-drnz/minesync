// Modelli delle risposte dell'API v2 di Modrinth (https://docs.modrinth.com):
// solo i campi che servono a MineSync. Decodifica tollerante sui campi
// descrittivi (un valore nuovo di un enum diventa `unknown`), stretta su
// quelli che servono a scaricare e verificare (id, URL, hash, dimensione).
import 'pack.dart';

/// `client_side` / `server_side` di un progetto.
enum MrEnv {
  required,
  optional,
  unsupported,
  unknown;

  static MrEnv parse(Object? v) => values.firstWhere((e) => e.name == v, orElse: () => unknown);

  bool get supported => this == required || this == optional;
}

/// Lato e «facoltativa per i giocatori» dai due campi di Modrinth:
/// - solo client → client (facoltativa se `client_side` è optional);
/// - solo server → server;
/// - tutti e due → both (facoltativa per i giocatori se `client_side` è
///   optional: il server la carica comunque);
/// - nessuna informazione → both (l'admin può cambiarlo).
(PackSide, bool) sideFromEnv(MrEnv client, MrEnv server) {
  final c = client.supported, s = server.supported;
  if (c && !s && server == MrEnv.unsupported) return (PackSide.client, client == MrEnv.optional);
  if (s && !c && client == MrEnv.unsupported) return (PackSide.server, false);
  if (c && s) return (PackSide.both, client == MrEnv.optional);
  if (c) return (PackSide.both, client == MrEnv.optional);
  if (s) return (PackSide.both, false);
  return (PackSide.both, false);
}

/// Tipo di una versione.
enum MrVersionType {
  release,
  beta,
  alpha;

  static MrVersionType parse(Object? v) =>
      values.firstWhere((e) => e.name == v, orElse: () => alpha);
}

/// Tipo di una dipendenza.
enum MrDependencyType {
  required,
  optional,
  incompatible,
  embedded;

  static MrDependencyType parse(Object? v) =>
      values.firstWhere((e) => e.name == v, orElse: () => optional);
}

/// Un progetto (`GET /project/{id}`).
final class MrProject {
  const MrProject({
    required this.id,
    required this.slug,
    required this.title,
    this.description = '',
    this.projectType = 'mod',
    this.clientSide = MrEnv.unknown,
    this.serverSide = MrEnv.unknown,
    this.categories = const [],
    this.loaders = const [],
    this.gameVersions = const [],
    this.downloads = 0,
    this.iconUrl,
    this.license,
    this.sourceUrl,
    this.body = '',
    this.issuesUrl,
    this.wikiUrl,
    this.discordUrl,
    this.updated = 0,
  });

  factory MrProject.fromJson(Object? j) {
    final m = _obj(j, 'project');
    final lic = m['license'];
    return MrProject(
      id: _id(m, 'id'),
      slug: _optStr(m, 'slug') ?? _id(m, 'id'),
      title: _optStr(m, 'title') ?? '',
      description: _optStr(m, 'description') ?? '',
      projectType: _optStr(m, 'project_type') ?? 'mod',
      clientSide: MrEnv.parse(m['client_side']),
      serverSide: MrEnv.parse(m['server_side']),
      categories: _strings(m, 'categories'),
      loaders: _strings(m, 'loaders'),
      gameVersions: _strings(m, 'game_versions'),
      downloads: _optInt(m, 'downloads') ?? 0,
      iconUrl: _url(m['icon_url']),
      license: lic is Map<String, Object?> ? _optStr(lic, 'id') : null,
      sourceUrl: _url(m['source_url']),
      body: _optStr(m, 'body') ?? '',
      issuesUrl: _url(m['issues_url']),
      wikiUrl: _url(m['wiki_url']),
      discordUrl: _url(m['discord_url']),
      updated: _date(m['updated']),
    );
  }

  final String id;
  final String slug;
  final String title;
  final String description;
  final String projectType;
  final MrEnv clientSide;
  final MrEnv serverSide;
  final List<String> categories;
  final List<String> loaders;
  final List<String> gameVersions;
  final int downloads;
  final String? iconUrl;

  /// Id SPDX della licenza.
  final String? license;
  final String? sourceUrl;

  /// Descrizione lunga in Markdown (può contenere HTML: chi la mostra la
  /// tratta come testo, vedi [plainMarkdown]).
  final String body;
  final String? issuesUrl;
  final String? wikiUrl;
  final String? discordUrl;

  /// Ultimo aggiornamento (ms dall'epoca, 0 se non noto).
  final int updated;

  /// Pagina del progetto su Modrinth.
  String get pageUrl => 'https://modrinth.com/$projectType/$slug';

  (PackSide, bool) get side => sideFromEnv(clientSide, serverSide);
}

/// Un risultato della ricerca (`GET /search`).
final class MrSearchHit {
  const MrSearchHit({
    required this.projectId,
    required this.slug,
    required this.title,
    this.description = '',
    this.author = '',
    this.projectType = 'mod',
    this.categories = const [],
    this.gameVersions = const [],
    this.downloads = 0,
    this.iconUrl,
    this.clientSide = MrEnv.unknown,
    this.serverSide = MrEnv.unknown,
    this.latestVersion,
    this.license,
    this.dateModified = 0,
  });

  factory MrSearchHit.fromJson(Object? j) {
    final m = _obj(j, 'hit');
    return MrSearchHit(
      projectId: _id(m, 'project_id'),
      slug: _optStr(m, 'slug') ?? _id(m, 'project_id'),
      title: _optStr(m, 'title') ?? '',
      description: _optStr(m, 'description') ?? '',
      author: _optStr(m, 'author') ?? '',
      projectType: _optStr(m, 'project_type') ?? 'mod',
      categories: _strings(m, 'categories'),
      gameVersions: _strings(m, 'versions'),
      downloads: _optInt(m, 'downloads') ?? 0,
      iconUrl: _url(m['icon_url']),
      clientSide: MrEnv.parse(m['client_side']),
      serverSide: MrEnv.parse(m['server_side']),
      latestVersion: _optStr(m, 'latest_version'),
      license: _optStr(m, 'license'),
      dateModified: _date(m['date_modified']),
    );
  }

  final String projectId;
  final String slug;
  final String title;
  final String description;
  final String author;
  final String projectType;

  /// Categorie, compresi i loader (`fabric`, `neoforge`…).
  final List<String> categories;
  final List<String> gameVersions;
  final int downloads;
  final String? iconUrl;
  final MrEnv clientSide;
  final MrEnv serverSide;
  final String? latestVersion;
  final String? license;

  /// Ultima modifica (ms dall'epoca, 0 se non nota).
  final int dateModified;

  String get pageUrl => 'https://modrinth.com/$projectType/$slug';

  (PackSide, bool) get side => sideFromEnv(clientSide, serverSide);
}

/// Una pagina di risultati.
final class MrSearchResult {
  const MrSearchResult({required this.hits, this.offset = 0, this.limit = 0, this.total = 0});

  factory MrSearchResult.fromJson(Object? j) {
    final m = _obj(j, 'search');
    final hits = m['hits'];
    if (hits is! List<Object?>) throw const FormatException('hits: attesa una lista');
    return MrSearchResult(
      hits: [for (final h in hits) MrSearchHit.fromJson(h)],
      offset: _optInt(m, 'offset') ?? 0,
      limit: _optInt(m, 'limit') ?? 0,
      total: _optInt(m, 'total_hits') ?? hits.length,
    );
  }

  final List<MrSearchHit> hits;
  final int offset;
  final int limit;
  final int total;
}

/// Un file di una versione.
final class MrFile {
  const MrFile({
    required this.url,
    required this.filename,
    required this.size,
    required this.sha1,
    required this.sha512,
    this.primary = false,
  });

  factory MrFile.fromJson(Object? j) {
    final m = _obj(j, 'file');
    final h = _obj(m['hashes'], 'hashes');
    final url = _str(m, 'url');
    if (!isHttpsUrl(url)) throw FormatException('url non valido: $url');
    final sha1 = _str(h, 'sha1').toLowerCase(), sha512 = _str(h, 'sha512').toLowerCase();
    if (!isSha1(sha1) || !isSha512(sha512)) throw const FormatException('hash non validi');
    final name = _str(m, 'filename');
    if (name.isEmpty || name.contains('/') || name.contains(r'\')) {
      throw FormatException('nome del file non valido: $name');
    }
    return MrFile(
      url: url,
      filename: name,
      size: _optInt(m, 'size') ?? 0,
      sha1: sha1,
      sha512: sha512,
      primary: m['primary'] == true,
    );
  }

  final String url;
  final String filename;
  final int size;
  final String sha1;
  final String sha512;
  final bool primary;
}

/// Una dipendenza di una versione.
final class MrDependency {
  const MrDependency({required this.type, this.projectId, this.versionId, this.fileName});

  factory MrDependency.fromJson(Object? j) {
    final m = _obj(j, 'dependency');
    return MrDependency(
      type: MrDependencyType.parse(m['dependency_type']),
      projectId: _optStr(m, 'project_id'),
      versionId: _optStr(m, 'version_id'),
      fileName: _optStr(m, 'file_name'),
    );
  }

  final MrDependencyType type;
  final String? projectId;

  /// Versione precisa richiesta, se l'autore l'ha indicata.
  final String? versionId;
  final String? fileName;
}

/// Una versione di un progetto.
final class MrVersion {
  const MrVersion({
    required this.id,
    required this.projectId,
    required this.versionNumber,
    required this.files,
    this.name = '',
    this.versionType = MrVersionType.release,
    this.gameVersions = const [],
    this.loaders = const [],
    this.featured = false,
    this.datePublished = 0,
    this.dependencies = const [],
    this.changelog,
  });

  factory MrVersion.fromJson(Object? j) {
    final m = _obj(j, 'version');
    final files = m['files'];
    if (files is! List<Object?>) throw const FormatException('files: attesa una lista');
    final deps = m['dependencies'];
    final date = _optStr(m, 'date_published');
    return MrVersion(
      id: _id(m, 'id'),
      projectId: _id(m, 'project_id'),
      versionNumber: _optStr(m, 'version_number') ?? '',
      name: _optStr(m, 'name') ?? '',
      versionType: MrVersionType.parse(m['version_type']),
      gameVersions: _strings(m, 'game_versions'),
      loaders: _strings(m, 'loaders'),
      featured: m['featured'] == true,
      datePublished: date == null
          ? 0
          : (DateTime.tryParse(date)?.millisecondsSinceEpoch ??
                (throw FormatException('date_published non valida: $date'))),
      files: [for (final f in files) MrFile.fromJson(f)],
      dependencies: deps is List<Object?> ? [for (final d in deps) MrDependency.fromJson(d)] : [],
      changelog: _optStr(m, 'changelog'),
    );
  }

  final String id;
  final String projectId;
  final String versionNumber;
  final String name;
  final MrVersionType versionType;
  final List<String> gameVersions;
  final List<String> loaders;
  final bool featured;

  /// ms dall'epoca.
  final int datePublished;
  final List<MrFile> files;
  final List<MrDependency> dependencies;
  final String? changelog;

  /// Il file principale (quello `primary`, altrimenti il primo).
  MrFile? get primaryFile => files.where((f) => f.primary).firstOrNull ?? files.firstOrNull;

  Iterable<MrDependency> ofType(MrDependencyType t) => dependencies.where((d) => d.type == t);
}

/// Una versione del gioco (`GET /tag/game_version`).
final class MrGameVersion {
  const MrGameVersion({
    required this.version,
    required this.versionType,
    this.date = 0,
    this.major = false,
  });

  factory MrGameVersion.fromJson(Object? j) {
    final m = _obj(j, 'game_version');
    final d = _optStr(m, 'date');
    return MrGameVersion(
      version: _str(m, 'version'),
      versionType: _optStr(m, 'version_type') ?? 'release',
      date: d == null ? 0 : (DateTime.tryParse(d)?.millisecondsSinceEpoch ?? 0),
      major: m['major'] == true,
    );
  }

  final String version;

  /// `release`, `snapshot`, `alpha` o `beta`.
  final String versionType;
  final int date;
  final bool major;
}

// ---------------------------------------------------------------- helper

final _idRe = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

Map<String, Object?> _obj(Object? v, String what) =>
    v is Map<String, Object?> ? v : throw FormatException('$what: atteso un oggetto');

String _str(Map<String, Object?> m, String k) {
  final v = m[k];
  return v is String ? v : throw FormatException('$k: attesa una stringa');
}

String _id(Map<String, Object?> m, String k) {
  final v = _str(m, k);
  return _idRe.hasMatch(v) ? v : throw FormatException('$k: id non valido');
}

String? _optStr(Map<String, Object?> m, String k) {
  final v = m[k];
  return v is String ? v : null;
}

int? _optInt(Map<String, Object?> m, String k) {
  final v = m[k];
  return v is int ? v : null;
}

List<String> _strings(Map<String, Object?> m, String k) {
  final v = m[k];
  if (v is! List<Object?>) return const [];
  return [for (final s in v) ?(s is String ? s : null)];
}

int _date(Object? v) => v is String ? (DateTime.tryParse(v)?.millisecondsSinceEpoch ?? 0) : 0;

String? _url(Object? v) => v is String && isHttpsUrl(v, allowHttp: true) ? v : null;
