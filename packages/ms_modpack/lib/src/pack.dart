// Il file del modpack di un server: minesync-pack.json nella radice della
// cartella del server, sincronizzato dall'hub come ogni altro file (quindi
// con la storia delle generazioni). Descrive versione di Minecraft, loader e
// ogni mod con hash, lato e sorgente. Formato in docs/design/modpack.md.
//
// Codifica canonica: chiavi in ordine fisso, mod in ordine di percorso,
// rientro di due spazi e "\n" finale. Lo stesso pack dà sempre gli stessi
// byte, quindi il file cambia (e crea una generazione) solo se cambia
// davvero qualcosa.
import 'dart:collection';
import 'dart:convert';

import 'package:ms_protocol/ms_protocol.dart';

/// Nome del file del pack nella radice del server.
const String packFileName = 'minesync-pack.json';

/// Cartella (nella radice del server) dei file solo per i giocatori: le mod
/// solo client e le `client-overrides/` di un `.mrpack`. Il server la ignora.
const String clientOverridesDir = 'client-overrides';

/// Suffisso di una mod spenta: il file resta ma il loader non lo carica.
const String disabledSuffix = '.disabled';

/// Versione del formato del file.
const int packFormat = 1;

final _sha1Re = RegExp(r'^[0-9a-f]{40}$');
final _sha512Re = RegExp(r'^[0-9a-f]{128}$');
final _idRe = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// Vero se [h] è uno SHA-1 esadecimale minuscolo.
bool isSha1(String h) => _sha1Re.hasMatch(h);

/// Vero se [h] è uno SHA-512 esadecimale minuscolo.
bool isSha512(String h) => _sha512Re.hasMatch(h);

/// Dove serve una mod.
enum PackSide {
  client,
  server,
  both;

  /// Va installata sul server.
  bool get onServer => this != client;

  /// Va nel pacchetto per i giocatori.
  bool get onClient => this != server;

  static PackSide parse(Object? v) => values.firstWhere(
    (e) => e.name == v,
    orElse: () => throw FormatException('lato sconosciuto: $v'),
  );
}

/// Da dove viene una mod.
enum PackSource {
  /// Progetto Modrinth: si aggiorna e si riconosce per hash.
  modrinth,

  /// File di CurseForge: solo riferimento (pagina, id), mai aggiornato da
  /// MineSync.
  curseforge,

  /// Jar non riconosciuto o preso da un URL qualsiasi: resta com'è, mai
  /// aggiornato.
  manual;

  static PackSource parse(Object? v) => values.firstWhere(
    (e) => e.name == v,
    orElse: () => throw FormatException('sorgente sconosciuta: $v'),
  );
}

/// Riferimento a un file di CurseForge.
final class CurseForgeRef {
  const CurseForgeRef({this.projectId, this.fileId, this.pageUrl, this.allowDistribution = false});

  factory CurseForgeRef.fromJson(Object? j) {
    final m = _obj(j, 'curseforge');
    final page = _optStr(m, 'pageUrl');
    if (page != null && !isHttpsUrl(page, allowHttp: true)) {
      throw FormatException('curseforge.pageUrl non valido: $page');
    }
    return CurseForgeRef(
      projectId: _optInt(m, 'projectId'),
      fileId: _optInt(m, 'fileId'),
      pageUrl: page,
      allowDistribution: m['allowDistribution'] == true,
    );
  }

  final int? projectId;
  final int? fileId;

  /// Pagina del file o del progetto, per lo scaricamento a mano.
  final String? pageUrl;

  /// L'autore permette ad altre app di scaricarla e ridistribuirla. Se
  /// falso il jar non va mai nel pacchetto per i giocatori: ognuno lo
  /// scarica dalla pagina.
  final bool allowDistribution;

  Map<String, Object?> toJson() => {
    'projectId': ?projectId,
    'fileId': ?fileId,
    'pageUrl': ?pageUrl,
    if (allowDistribution) 'allowDistribution': true,
  };

  @override
  bool operator ==(Object other) =>
      other is CurseForgeRef &&
      other.projectId == projectId &&
      other.fileId == fileId &&
      other.pageUrl == pageUrl &&
      other.allowDistribution == allowDistribution;

  @override
  int get hashCode => Object.hash(projectId, fileId, pageUrl, allowDistribution);
}

/// Vero se [s] è un URL assoluto https (o http con [allowHttp]) con host.
bool isHttpsUrl(String s, {bool allowHttp = false}) {
  final u = Uri.tryParse(s);
  if (u == null || !u.hasAuthority || u.host.isEmpty) return false;
  if (s.codeUnits.any((c) => c <= 0x20 || c == 0x7f)) return false;
  return u.scheme == 'https' || (allowHttp && u.scheme == 'http');
}

/// Controlla il percorso di una mod nell'istanza (`mods/x.jar`): valido per
/// ms_protocol, non dentro le cartelle speciali del pack, senza il suffisso
/// delle mod spente. Null se va bene, altrimenti il motivo.
String? checkModPath(String path) {
  final p = checkPath(path);
  if (p != null) return p.name;
  final lower = path.toLowerCase();
  if (lower == packFileName) return 'packFile';
  if (lower.startsWith('$clientOverridesDir/') ||
      lower.startsWith('overrides/') ||
      lower.startsWith('server-overrides/')) {
    return 'overridesDir';
  }
  if (lower.endsWith(disabledSuffix)) return 'disabledSuffix';
  return null;
}

/// Una mod (o un altro file scaricabile: resource pack, shader) del pack.
final class PackMod {
  PackMod({
    required this.path,
    required this.sha1,
    required this.sha512,
    required this.size,
    this.name,
    this.side = PackSide.both,
    this.optional = false,
    this.source = PackSource.manual,
    this.pinned = false,
    this.disabled = false,
    this.auto = false,
    List<String> downloads = const [],
    this.projectId,
    this.versionId,
    this.versionNumber,
    List<String> requires = const [],
    this.curseforge,
  }) : downloads = List.unmodifiable(downloads),
       requires = List.unmodifiable({...requires}.toList()..sort()) {
    final bad = checkModPath(path);
    if (bad != null) throw FormatException('percorso della mod non valido ($bad): $path');
    if (!isSha1(sha1)) throw FormatException('$path: sha1 non valido');
    if (!isSha512(sha512)) throw FormatException('$path: sha512 non valido');
    if (size < 0) throw FormatException('$path: dimensione negativa');
    for (final d in this.downloads) {
      if (!isHttpsUrl(d)) throw FormatException('$path: URL di download non valido: $d');
    }
    for (final id in [?projectId, ?versionId, ...this.requires]) {
      if (!_idRe.hasMatch(id)) throw FormatException('$path: id non valido: $id');
    }
    if (source == PackSource.modrinth && (projectId == null || versionId == null)) {
      throw FormatException('$path: una mod Modrinth vuole projectId e versionId');
    }
  }

  factory PackMod.fromJson(Object? j) {
    final m = _obj(j, 'mod');
    final cf = m['curseforge'];
    return PackMod(
      path: _str(m, 'path'),
      name: _optStr(m, 'name'),
      sha1: _str(m, 'sha1'),
      sha512: _str(m, 'sha512'),
      size: _int(m, 'size'),
      side: PackSide.parse(m['side'] ?? 'both'),
      optional: m['optional'] == true,
      source: PackSource.parse(m['source'] ?? 'manual'),
      pinned: m['pinned'] == true,
      disabled: m['disabled'] == true,
      auto: m['auto'] == true,
      downloads: _strings(m, 'downloads'),
      projectId: _optStr(m, 'projectId'),
      versionId: _optStr(m, 'versionId'),
      versionNumber: _optStr(m, 'versionNumber'),
      requires: _strings(m, 'requires'),
      curseforge: cf == null ? null : CurseForgeRef.fromJson(cf),
    );
  }

  /// Percorso nell'istanza del gioco, come `files[].path` di un `.mrpack`
  /// (`mods/x.jar`, `resourcepacks/y.zip`).
  final String path;

  /// Nome da mostrare (titolo del progetto), se noto.
  final String? name;
  final String sha1;
  final String sha512;
  final int size;
  final PackSide side;

  /// Facoltativa per i giocatori (ognuno sceglie sul suo PC). Sul server una
  /// mod `both` o `server` si installa sempre.
  final bool optional;
  final PackSource source;

  /// Bloccata alla versione attuale: «aggiorna tutte» la salta.
  final bool pinned;

  /// Spenta: il file resta (con [disabledSuffix]) ma non si carica, e non va
  /// nel pacchetto per i giocatori.
  final bool disabled;

  /// Aggiunta da MineSync come dipendenza obbligatoria di un'altra.
  final bool auto;

  /// URL https da cui scaricare il file (Modrinth: il CDN).
  final List<String> downloads;
  final String? projectId;
  final String? versionId;

  /// Numero di versione leggibile (`6.0.8`).
  final String? versionNumber;

  /// Progetti (id Modrinth) richiesti da questa versione: servono per sapere
  /// chi dipende da chi anche senza rete.
  final List<String> requires;
  final CurseForgeRef? curseforge;

  /// Nome del file.
  String get file => path.substring(path.lastIndexOf('/') + 1);

  /// Dove sta il file nella cartella del server, se accesa: le mod solo
  /// client stanno sotto [clientOverridesDir] perché il server non le
  /// carichi.
  String get location => side == PackSide.client ? '$clientOverridesDir/$path' : path;

  /// Dove sta il file adesso, tenendo conto di [disabled].
  String get diskLocation => disabled ? '$location$disabledSuffix' : location;

  /// Chiave di identità nel pack: il progetto Modrinth se c'è, altrimenti il
  /// percorso (senza maiuscole).
  String get key => projectId != null ? 'mr:$projectId' : 'path:${path.toLowerCase()}';

  PackMod copyWith({
    String? path,
    String? name,
    String? sha1,
    String? sha512,
    int? size,
    PackSide? side,
    bool? optional,
    PackSource? source,
    bool? pinned,
    bool? disabled,
    bool? auto,
    List<String>? downloads,
    String? projectId,
    String? versionId,
    String? versionNumber,
    List<String>? requires,
    CurseForgeRef? curseforge,
  }) => PackMod(
    path: path ?? this.path,
    name: name ?? this.name,
    sha1: sha1 ?? this.sha1,
    sha512: sha512 ?? this.sha512,
    size: size ?? this.size,
    side: side ?? this.side,
    optional: optional ?? this.optional,
    source: source ?? this.source,
    pinned: pinned ?? this.pinned,
    disabled: disabled ?? this.disabled,
    auto: auto ?? this.auto,
    downloads: downloads ?? this.downloads,
    projectId: projectId ?? this.projectId,
    versionId: versionId ?? this.versionId,
    versionNumber: versionNumber ?? this.versionNumber,
    requires: requires ?? this.requires,
    curseforge: curseforge ?? this.curseforge,
  );

  /// Codifica canonica: chiavi in ordine fisso, campi di default omessi.
  Map<String, Object?> toJson() => {
    'path': path,
    'name': ?name,
    'side': side.name,
    if (optional) 'optional': true,
    'source': source.name,
    'projectId': ?projectId,
    'versionId': ?versionId,
    'versionNumber': ?versionNumber,
    'size': size,
    'sha1': sha1,
    'sha512': sha512,
    if (downloads.isNotEmpty) 'downloads': downloads,
    if (requires.isNotEmpty) 'requires': requires,
    if (curseforge != null) 'curseforge': curseforge!.toJson(),
    if (pinned) 'pinned': true,
    if (disabled) 'disabled': true,
    if (auto) 'auto': true,
  };

  @override
  bool operator ==(Object other) =>
      other is PackMod && jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;

  @override
  String toString() => 'PackMod($path, ${source.name}, ${side.name})';
}

/// Il pack di un server, immutabile.
final class Pack {
  Pack._(
    this.name,
    this.mcVersion,
    this.loader,
    this.loaderVersion,
    this._mods,
    this.shared,
    this.updatedAt,
  );

  /// Costruisce e valida: loader non `paper`, versione del loader se non
  /// vanilla, percorsi e posizioni delle mod univoci (senza maiuscole),
  /// pattern di [shared] non vuoti.
  factory Pack({
    String? name,
    required String mcVersion,
    required Loader loader,
    String? loaderVersion,
    Iterable<PackMod> mods = const [],
    Iterable<String> shared = const [],
    int? updatedAt,
  }) {
    if (mcVersion.trim().isEmpty || mcVersion.trim() != mcVersion) {
      throw FormatException('versione di Minecraft non valida: "$mcVersion"');
    }
    if (loader == Loader.paper) throw const FormatException('paper non è un loader di mod');
    if (loader == Loader.vanilla && loaderVersion != null) {
      throw const FormatException('vanilla non ha una versione del loader');
    }
    if (loader != Loader.vanilla && (loaderVersion == null || loaderVersion.trim().isEmpty)) {
      throw FormatException('${loader.name}: manca la versione del loader');
    }
    final byPath = SplayTreeMap<String, PackMod>(comparePaths);
    final locations = <String>{};
    final keys = <String>{};
    for (final m in mods) {
      if (byPath.containsKey(m.path) || !locations.add(caseFoldKey(m.location))) {
        throw FormatException('mod ripetuta: ${m.path}');
      }
      if (!keys.add(m.key)) throw FormatException('progetto ripetuto: ${m.projectId}');
      byPath[m.path] = m;
    }
    final paths = caseCollisions(byPath.keys);
    if (paths.isNotEmpty) throw FormatException('mod ripetuta: ${paths.first.$2}');
    final sh = [
      for (final s in shared)
        if (s.trim().isEmpty) throw const FormatException('pattern vuoto in shared') else s.trim(),
    ];
    return Pack._(
      name,
      mcVersion,
      loader,
      loaderVersion,
      List.unmodifiable(byPath.values),
      List.unmodifiable(sh),
      updatedAt,
    );
  }

  factory Pack.fromJson(Object? j) {
    final m = _obj(j, 'pack');
    final f = m['format'];
    if (f != packFormat) throw FormatException('formato del pack non supportato: $f');
    final mods = m['mods'];
    if (mods != null && mods is! List<Object?>) {
      throw const FormatException('mods: attesa una lista');
    }
    return Pack(
      name: _optStr(m, 'name'),
      mcVersion: _str(m, 'minecraft'),
      loader: Loader.parse(m['loader']),
      loaderVersion: _optStr(m, 'loaderVersion'),
      mods: [for (final x in (mods as List<Object?>?) ?? const []) PackMod.fromJson(x)],
      shared: _strings(m, 'shared'),
      updatedAt: _optInt(m, 'updatedAt'),
    );
  }

  /// Legge il testo di `minesync-pack.json`. [FormatException] se non valido.
  factory Pack.decode(String text) {
    final Object? j;
    try {
      j = jsonDecode(text);
    } on FormatException catch (e) {
      throw FormatException('minesync-pack.json non è JSON: ${e.message}');
    }
    return Pack.fromJson(j);
  }

  /// Nome del pack (di solito quello del server), facoltativo.
  final String? name;
  final String mcVersion;
  final Loader loader;

  /// Null solo per vanilla.
  final String? loaderVersion;
  final List<PackMod> _mods;

  /// Pattern (sintassi delle esclusioni di ms_protocol) dei file del server
  /// che vanno anche ai giocatori, come `overrides/` del `.mrpack`
  /// (es. `config/**`).
  final List<String> shared;

  /// Ultima modifica (ms), se chi scrive la registra. Fa parte dei byte: chi
  /// non vuole generazioni nuove per niente la lascia invariata.
  final int? updatedAt;

  /// Mod in ordine di percorso.
  List<PackMod> get mods => _mods;

  PackMod? byPath(String path) {
    final k = caseFoldKey(path);
    return _mods.where((m) => caseFoldKey(m.path) == k).firstOrNull;
  }

  PackMod? byProject(String projectId) => _mods.where((m) => m.projectId == projectId).firstOrNull;

  PackMod? byKey(String key) => _mods.where((m) => m.key == key).firstOrNull;

  /// La mod che sta in [location] della cartella del server (anche spenta).
  PackMod? byLocation(String location) {
    final k = caseFoldKey(location);
    return _mods
        .where((m) => caseFoldKey(m.location) == k || caseFoldKey(m.diskLocation) == k)
        .firstOrNull;
  }

  /// Le mod attive per un lato.
  Iterable<PackMod> active(PackSide side) => _mods.where(
    (m) =>
        !m.disabled &&
        switch (side) {
          PackSide.client => m.side.onClient,
          PackSide.server => m.side.onServer,
          PackSide.both => true,
        },
  );

  Pack copyWith({
    String? name,
    String? mcVersion,
    Loader? loader,
    String? loaderVersion,
    bool clearLoaderVersion = false,
    Iterable<PackMod>? mods,
    Iterable<String>? shared,
    int? updatedAt,
  }) => Pack(
    name: name ?? this.name,
    mcVersion: mcVersion ?? this.mcVersion,
    loader: loader ?? this.loader,
    loaderVersion: clearLoaderVersion ? null : (loaderVersion ?? this.loaderVersion),
    mods: mods ?? _mods,
    shared: shared ?? this.shared,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  /// Sostituisce (per [PackMod.key]) o aggiunge le mod date.
  Pack withMods(Iterable<PackMod> put) {
    final out = {for (final m in _mods) m.key: m};
    for (final m in put) {
      out[m.key] = m;
    }
    return copyWith(mods: out.values);
  }

  /// Toglie le mod con le chiavi date.
  Pack withoutKeys(Iterable<String> keys) {
    final k = keys.toSet();
    return copyWith(mods: _mods.where((m) => !k.contains(m.key)));
  }

  Map<String, Object?> toJson() => {
    'format': packFormat,
    'name': ?name,
    'minecraft': mcVersion,
    'loader': loader.name,
    'loaderVersion': ?loaderVersion,
    'updatedAt': ?updatedAt,
    if (shared.isNotEmpty) 'shared': shared,
    'mods': [for (final m in _mods) m.toJson()],
  };

  /// Testo canonico del file (UTF-8, "\n" finale).
  String encode() => '${const JsonEncoder.withIndent('  ').convert(toJson())}\n';

  /// Byte canonici del file.
  List<int> encodeBytes() => utf8.encode(encode());

  @override
  bool operator ==(Object other) => other is Pack && other.encode() == encode();

  @override
  int get hashCode => encode().hashCode;
}

/// Che cosa è cambiato tra due pack, per la barra «modifiche da applicare»
/// e per il riepilogo prima di caricare. Le mod si confrontano per
/// [PackMod.key].
final class PackDiff {
  factory PackDiff(Pack from, Pack to) {
    final a = {for (final m in from.mods) m.key: m};
    final b = {for (final m in to.mods) m.key: m};
    final added = <PackMod>[], removed = <PackMod>[];
    final updated = <(PackMod, PackMod)>[], toggled = <(PackMod, PackMod)>[];
    final other = <(PackMod, PackMod)>[];
    for (final m in to.mods) {
      final old = a[m.key];
      if (old == null) {
        added.add(m);
      } else if (old.sha1 != m.sha1 || old.versionId != m.versionId) {
        updated.add((old, m));
      } else if (old.disabled != m.disabled) {
        toggled.add((old, m));
      } else if (old != m) {
        other.add((old, m));
      }
    }
    for (final m in from.mods) {
      if (!b.containsKey(m.key)) removed.add(m);
    }
    return PackDiff._(
      mcVersion: from.mcVersion == to.mcVersion ? null : (from.mcVersion, to.mcVersion),
      loader: from.loader == to.loader && from.loaderVersion == to.loaderVersion
          ? null
          : ((from.loader, from.loaderVersion), (to.loader, to.loaderVersion)),
      added: added,
      removed: removed,
      updated: updated,
      toggled: toggled,
      changed: other,
      sharedChanged: from.shared.join('\n') != to.shared.join('\n'),
    );
  }

  PackDiff._({
    required this.mcVersion,
    required this.loader,
    required this.added,
    required this.removed,
    required this.updated,
    required this.toggled,
    required this.changed,
    required this.sharedChanged,
  });

  /// (prima, dopo) se la versione di Minecraft cambia.
  final (String, String)? mcVersion;

  /// ((loader, versione) prima, dopo) se cambia il loader o la sua versione.
  final ((Loader, String?), (Loader, String?))? loader;
  final List<PackMod> added;
  final List<PackMod> removed;

  /// (prima, dopo): file diverso (versione o hash).
  final List<(PackMod, PackMod)> updated;

  /// (prima, dopo): solo accesa o spenta.
  final List<(PackMod, PackMod)> toggled;

  /// (prima, dopo): altri campi (lato, facoltativa, bloccata, nome, URL).
  final List<(PackMod, PackMod)> changed;
  final bool sharedChanged;

  bool get isEmpty =>
      mcVersion == null &&
      loader == null &&
      added.isEmpty &&
      removed.isEmpty &&
      updated.isEmpty &&
      toggled.isEmpty &&
      changed.isEmpty &&
      !sharedChanged;

  /// Modifiche che toccano i file (scaricare, togliere, rinominare, spostare).
  bool get touchesFiles =>
      added.isNotEmpty ||
      removed.isNotEmpty ||
      updated.isNotEmpty ||
      toggled.isNotEmpty ||
      changed.any((c) => c.$1.location != c.$2.location);
}

/// Un file trovato nella cartella del server (lo calcola lib/io.dart).
final class LocalFile {
  const LocalFile({required this.path, required this.size, required this.sha1, this.sha512});

  /// Percorso relativo alla radice del server, con "/".
  final String path;
  final int size;
  final String sha1;
  final String? sha512;
}

/// Confronto tra il pack e i jar davvero presenti.
final class PackCheck {
  const PackCheck({required this.missing, required this.mismatched, required this.untracked});

  /// Mod del pack il cui file non c'è (in [PackMod.diskLocation]).
  final List<PackMod> missing;

  /// Mod del pack il cui file c'è ma con un altro SHA-1 (sostituito a mano).
  final List<(PackMod, LocalFile)> mismatched;

  /// Jar presenti che il pack non conosce.
  final List<LocalFile> untracked;

  bool get isClean => missing.isEmpty && mismatched.isEmpty && untracked.isEmpty;
}

/// Vero se [path] (relativo alla radice del server) è un file che il pack
/// dovrebbe conoscere: un jar in `mods/` o `client-overrides/mods/` (anche
/// spento), al primo livello.
bool isModLocation(String path) {
  final l = path.toLowerCase();
  final file = l.endsWith(disabledSuffix) ? l.substring(0, l.length - disabledSuffix.length) : l;
  if (!file.endsWith('.jar')) return false;
  final parts = file.split('/');
  return (parts.length == 2 && parts[0] == 'mods') ||
      (parts.length == 3 && parts[0] == clientOverridesDir && parts[1] == 'mods');
}

/// Confronta [pack] con i file [files] della cartella del server (servono
/// almeno quelli per cui [isModLocation] è vero).
PackCheck checkPack(Pack pack, Iterable<LocalFile> files) {
  final byLoc = <String, LocalFile>{for (final f in files) caseFoldKey(f.path): f};
  final missing = <PackMod>[];
  final mismatched = <(PackMod, LocalFile)>[];
  final known = <String>{};
  for (final m in pack.mods) {
    final k = caseFoldKey(m.diskLocation);
    known.add(k);
    final f = byLoc[k];
    if (f == null) {
      missing.add(m);
    } else if (f.sha1 != m.sha1 || f.size != m.size) {
      mismatched.add((m, f));
    }
  }
  final untracked = [
    for (final f in files)
      if (isModLocation(f.path) && !known.contains(caseFoldKey(f.path))) f,
  ]..sort((a, b) => comparePaths(a.path, b.path));
  return PackCheck(missing: missing, mismatched: mismatched, untracked: untracked);
}

/// [p] con sul server anche le mod richieste (pure indirettamente) da una
/// mod che sta sul server: passano da «solo giocatori» a entrambi i lati.
/// Su Modrinth alcune librerie risultano solo client (es. athena-ctm,
/// fusion) ma le mod del server non partono senza: toglierle dal server lo
/// romperebbe.
Pack withServerDependencies(Pack p) {
  final byProject = {
    for (final m in p.mods)
      if (m.projectId != null) m.projectId!: m,
  };
  final needed = <String>{};
  final todo = [
    for (final m in p.mods)
      if (m.side.onServer && !m.disabled) ...m.requires,
  ];
  while (todo.isNotEmpty) {
    final id = todo.removeLast();
    if (!needed.add(id)) continue;
    todo.addAll(byProject[id]?.requires ?? const []);
  }
  final fix = [
    for (final m in p.mods)
      if (m.side == PackSide.client && needed.contains(m.projectId))
        m.copyWith(side: PackSide.both),
  ];
  return fix.isEmpty ? p : p.withMods(fix);
}

/// Una voce `manual` per un jar non riconosciuto: hash dal file, lato scelto
/// dall'admin (di default solo server, il caso più sicuro: un jar sul
/// server non rompe i PC dei giocatori). Il file in `client-overrides/mods/`
/// diventa solo client. Serve lo SHA-512.
PackMod manualEntry(LocalFile f, {PackSide? side, String? name}) {
  final sha512 = f.sha512;
  if (sha512 == null) throw ArgumentError('${f.path}: serve lo SHA-512');
  var loc = f.path;
  final disabled = loc.toLowerCase().endsWith(disabledSuffix);
  if (disabled) loc = loc.substring(0, loc.length - disabledSuffix.length);
  final inClient = loc.toLowerCase().startsWith('$clientOverridesDir/');
  final path = inClient ? loc.substring(clientOverridesDir.length + 1) : loc;
  final s = side ?? (inClient ? PackSide.client : PackSide.server);
  return PackMod(
    path: path,
    name: name,
    sha1: f.sha1,
    sha512: sha512,
    size: f.size,
    side: s,
    source: PackSource.manual,
    disabled: disabled,
  );
}

// ---------------------------------------------------------------- helper JSON

Map<String, Object?> _obj(Object? v, String what) =>
    v is Map<String, Object?> ? v : throw FormatException('$what: atteso un oggetto');

String _str(Map<String, Object?> m, String k) {
  final v = m[k];
  return v is String ? v : throw FormatException('$k: attesa una stringa');
}

String? _optStr(Map<String, Object?> m, String k) {
  final v = m[k];
  if (v == null || v is String) return v as String?;
  throw FormatException('$k: attesa una stringa');
}

int _int(Map<String, Object?> m, String k) {
  final v = m[k];
  return v is int ? v : throw FormatException('$k: atteso un intero');
}

int? _optInt(Map<String, Object?> m, String k) {
  final v = m[k];
  if (v == null || v is int) return v as int?;
  throw FormatException('$k: atteso un intero');
}

List<String> _strings(Map<String, Object?> m, String k) {
  final v = m[k];
  if (v == null) return const [];
  if (v is! List<Object?>) throw FormatException('$k: attesa una lista');
  return [for (final s in v) s is String ? s : throw FormatException('$k: attese stringhe')];
}
