// Rilevamento di una cartella server Minecraft: come si avvia, quale loader,
// quale versione di Minecraft. Legge soltanto: non esegue NULLA della
// cartella, che è sincronizzata dall'hub e quindi controllata da chiunque
// possa pushare sullo spazio (vedi java.dart).
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'jar_peek.dart';

/// Sistema operativo per cui si rileva e si costruisce l'avvio. Parametro
/// esplicito perché i test devono poter simulare un host diverso.
enum HostOs {
  linux,
  macos,
  windows;

  static HostOs get current => Platform.isWindows
      ? HostOs.windows
      : Platform.isMacOS
      ? HostOs.macos
      : HostOs.linux;

  /// Estensioni degli script di avvio eseguibili su questo sistema.
  List<String> get scriptExtensions => switch (this) {
    HostOs.linux => const ['.sh'],
    HostOs.macos => const ['.sh', '.command'],
    HostOs.windows => const ['.bat', '.cmd', '.ps1'],
  };
}

/// Come si avvia un server.
sealed class LaunchTarget {
  const LaunchTarget();
}

/// Tipo di script di avvio.
enum ScriptKind { posix, batch, powershell }

/// Avvio tramite lo script del pack (run.sh, ServerStart.sh, start.bat…).
final class ScriptLaunch extends LaunchTarget {
  const ScriptLaunch(
    this.path, {
    this.args = const [],
    this.kind = ScriptKind.posix,
    this.executable = false,
    this.bashOnly = false,
    this.crlf = false,
    this.setsHeap = false,
    this.hardcodedJava,
  });

  /// Percorso assoluto dello script.
  final String path;

  /// Argomenti da passare allo script.
  final List<String> args;
  final ScriptKind kind;

  /// Ha il bit di esecuzione (solo POSIX): si lancia direttamente, così
  /// vale lo shebang.
  final bool executable;

  /// Usa sintassi bash ([[ ]], array, pipefail): `sh` (dash) lo romperebbe.
  final bool bashOnly;

  /// Fine riga Windows in uno script POSIX: sh/bash daranno errori come
  /// «$'\r': command not found». La UI può avvisare.
  final bool crlf;

  /// Lo script imposta da sé la memoria (-Xmx).
  final bool setsHeap;

  /// Percorso di java scritto a mano nello script (es.
  /// `/usr/lib/jvm/java-17/bin/java`), se c'è: verrà usato quello e non il
  /// runtime scelto, perché lo script non si tocca.
  final String? hardcodedJava;
}

/// Avvio diretto di un jar che sa partire da solo (`java -jar x.jar nogui`):
/// Fabric/Quilt launcher, vanilla, Paper, Forge fino alla 1.16.
final class JarLaunch extends LaunchTarget {
  const JarLaunch(this.jarPath, {this.extraArgs = const []});

  /// Percorso assoluto del jar.
  final String jarPath;

  /// Argomenti JVM aggiuntivi, prima di `-jar`.
  final List<String> extraArgs;
}

/// Avvio tramite i file di argomenti di Forge/NeoForge 1.17+ (`java
/// @user_jvm_args.txt @libraries/…/unix_args.txt nogui`), quando manca uno
/// script per questo sistema (pack preparato su un altro OS).
final class ArgsFileLaunch extends LaunchTarget {
  const ArgsFileLaunch(this.argsFile, {this.jvmArgsFile});

  /// File di argomenti del loader, relativo alla cartella di lavoro, con `/`.
  final String argsFile;

  /// `user_jvm_args.txt` se presente, relativo alla cartella di lavoro.
  final String? jvmArgsFile;
}

/// Fotografia di una cartella server.
final class ServerLayout {
  const ServerLayout({
    required this.workDir,
    required this.label,
    this.launch,
    this.mcVersion,
    this.loader,
    this.loaderVersion,
    this.declaredJava,
    this.scripts = const [],
    this.empty = false,
  });

  /// Cartella da cui avviare il server (può essere una sottocartella della
  /// radice collegata, vedi B-SESSION-23).
  final String workDir;

  /// Come avviarlo, null se non si sa.
  final LaunchTarget? launch;

  /// Versione di Minecraft (es. `1.20.1`), best effort.
  final String? mcVersion;

  /// forge | neoforge | fabric | quilt | vanilla, null se ignoto.
  final String? loader;

  /// Versione del loader, best effort.
  final String? loaderVersion;

  /// Major di Java dichiarato da version.json nel server jar: lo scrive
  /// Mojang, vale più di qualunque tabella.
  final int? declaredJava;

  /// Tutti gli script candidati trovati, in ordine di preferenza.
  final List<String> scripts;

  /// Breve descrizione dell'avvio: nome dello script o del jar, `?`.
  final String label;

  /// Cartella vuota: il server non è ancora stato scaricato (B-SESSION-24).
  final bool empty;

  /// Major di Java richiesto: quello dichiarato, altrimenti la tabella.
  int get requiredJavaMajor => declaredJava ?? requiredJava(mcVersion);
}

// Stem degli script di avvio davvero usati nei server pack, in ordine di
// preferenza. Confronto case-insensitive: su Linux esistono ServerStart.sh,
// StartServer.sh e START.SH.
const _scriptStems = [
  'serverstart', 'server-start', 'server_start', 'startserver', 'start-server', //
  'start_server', 'launchserver', 'launch-server', 'run', 'run_server', 'runserver',
  'start', 'launch', 'server',
];

// Jar che partono da soli con `java -jar`, in ordine di preferenza.
final _launcherJars = [
  RegExp(r'^fabric-server-launch\.jar$'),
  RegExp(r'^quilt-server-launch\.jar$'),
  RegExp(r'^forge-.*-universal\.jar$'),
  RegExp(r'^forge-.*\.jar$'),
  RegExp(r'^minecraft_server.*\.jar$'),
  RegExp(r'^server\.jar$'),
  RegExp(r'^paper.*\.jar$'),
  RegExp(r'^purpur.*\.jar$'),
  RegExp(r'^spigot.*\.jar$'),
];

// Tracce della versione di Minecraft nei nomi dei jar in radice: l'unica
// nei pack Forge 1.12-1.16, dove sbagliare versione vuol dire lanciare con
// Java 21 un server che esiste solo per Java 8.
final _jarVersion = [
  RegExp(r'fabric-server-mc\.(1\.\d+(?:\.\d+)?)-loader'),
  RegExp(r'^forge-(1\.\d+(?:\.\d+)?)-'),
  RegExp(r'^minecraft_server\.(1\.\d+(?:\.\d+)?)\.jar$'),
  RegExp(r'^server-(1\.\d+(?:\.\d+)?)\.jar$'),
  RegExp(r'^(?:paper|purpur|spigot)[-_](1\.\d+(?:\.\d+)?)'),
];

final _mcVersionRe = RegExp(r'^1\.\d{1,2}(?:\.\d{1,2})?$');

bool _looksLikeMc(String? s) => s != null && _mcVersionRe.hasMatch(s);

/// Le cartelle di stato di MineSync non contano come contenuto del server.
bool _isOwnState(String name) => name.startsWith('.minesync');

/// Contenuto della radice letto una volta sola.
final class _Listing {
  _Listing(this.dir) {
    try {
      for (final e in Directory(dir).listSync(followLinks: false)) {
        final name = p.basename(e.path);
        if (_isOwnState(name)) continue;
        any = true;
        if (e is File || (e is Link && FileSystemEntity.isFileSync(e.path))) files.add(name);
      }
    } on FileSystemException {
      // cartella mancante o illeggibile: vuota
    }
    files.sort();
  }

  final String dir;
  final List<String> files = [];
  bool any = false;

  bool has(String name) => files.contains(name);

  /// Jar in radice, installer e sorgenti esclusi.
  Iterable<String> get jars => files.where((n) {
    final low = n.toLowerCase();
    return low.endsWith('.jar') && !low.contains('installer') && !low.contains('-sources');
  });
}

/// Fotografa la cartella server [root] (B-SESSION-22 … B-SESSION-25).
ServerLayout detectServer(String root, {HostOs? os}) {
  final host = os ?? HostOs.current;
  final dir = _descendToServerRoot(p.normalize(p.absolute(root)), host);
  final ls = _Listing(dir);
  if (!ls.any) return ServerLayout(workDir: dir, label: '?', empty: true);

  final scripts = _findScripts(ls, host);
  final script = _pickScript(scripts);
  final loader = _detectLoader(ls);
  var mc = mcVersionFromLibraries(dir) ?? _versionFromVersionsDir(dir) ?? _versionFromJarNames(ls);
  int? declared;
  final fromJar = _versionFromServerJar(dir);
  if (fromJar != null) {
    // version.json è la fonte autorevole
    mc = fromJar.id;
    declared = fromJar.java;
  }
  mc ??= _versionFromPackManifest(dir);

  LaunchTarget? launch;
  String label = '?';
  if (script != null) {
    launch = _scriptLaunch(script, host);
    label = p.basename(script);
  } else if (_findArgsFile(dir, host) case final args?) {
    launch = ArgsFileLaunch(
      args,
      jvmArgsFile: ls.has('user_jvm_args.txt') ? 'user_jvm_args.txt' : null,
    );
    label = p.posix.basename(args);
  } else if (_findLauncherJar(ls) case final jar?) {
    launch = JarLaunch(p.join(dir, jar));
    label = jar;
  }

  return ServerLayout(
    workDir: dir,
    launch: launch,
    mcVersion: mc,
    loader: loader,
    loaderVersion: _loaderVersionFromJars(ls) ?? _loaderVersionFromLibraries(dir, loader),
    declaredJava: declared,
    scripts: scripts,
    label: label,
  );
}

// Gli zip dei server pack avvolgono quasi sempre tutto in una cartella
// ("Modpack-Server/…"): estratti così, in radice non c'è niente da avviare.
// Si scende di UN livello, solo se la sottocartella è l'unica cosa presente.
String _descendToServerRoot(String dir, HostOs os) {
  if (_isServerRoot(dir, os)) return dir;
  final subs = <String>[];
  try {
    for (final e in Directory(dir).listSync(followLinks: false)) {
      final name = p.basename(e.path);
      if (_isOwnState(name)) continue;
      if (e is Directory) {
        if (!name.startsWith('.')) subs.add(name);
      } else {
        return dir; // ci sono file in radice: è questa la cartella buona
      }
    }
  } on FileSystemException {
    return dir;
  }
  if (subs.length != 1) return dir; // ambiguo: meglio non indovinare
  final cand = p.join(dir, subs.single);
  return _isServerRoot(cand, os) ? cand : dir;
}

bool _isServerRoot(String dir, HostOs os) {
  for (final marker in ['server.properties', 'eula.txt', 'mods', 'world', 'libraries']) {
    if (FileSystemEntity.typeSync(p.join(dir, marker)) != FileSystemEntityType.notFound) {
      return true;
    }
  }
  final ls = _Listing(dir);
  return _findScripts(ls, os).isNotEmpty || _findLauncherJar(ls) != null;
}

List<String> _findScripts(_Listing ls, HostOs os) {
  final found = <(String, int)>[];
  for (final name in ls.files) {
    final low = name.toLowerCase();
    for (final ext in os.scriptExtensions) {
      if (!low.endsWith(ext)) continue;
      final rank = _scriptStems.indexOf(low.substring(0, low.length - ext.length));
      if (rank >= 0) found.add((p.join(ls.dir, name), rank));
      break;
    }
  }
  found.sort((a, b) => a.$2 != b.$2 ? a.$2 - b.$2 : a.$1.compareTo(b.$1));
  return [for (final f in found) f.$1];
}

// A parità di ordine vince lo script che imposta la memoria: i pack
// spediscono spesso sia il run.sh dell'installer (heap di default, 1/4 della
// RAM: un pack da 400 mod ci muore) sia lo script dell'autore con -Xmx.
String? _pickScript(List<String> cands) {
  if (cands.isEmpty) return null;
  for (final c in cands) {
    if (_readSmall(c)?.contains('-Xmx') ?? false) return c;
  }
  return cands.first;
}

String? _readSmall(String path) {
  try {
    final f = File(path);
    if (f.lengthSync() > 512 * 1024) return null;
    return utf8.decode(f.readAsBytesSync(), allowMalformed: true);
  } on FileSystemException {
    return null;
  }
}

final _bashMarkers = ['[[', 'set -o pipefail', '=(', 'pushd', 'function '];
final _quotedJava = RegExp(r'''["']([^"'\n]*[/\\]bin[/\\]javaw?(?:\.exe)?)["']''');
final _bareJava = RegExp(
  r'''(?:^|[\s;&|(=])([^\s"';&|()=]*[/\\]bin[/\\]javaw?(?:\.exe)?)(?=\s|$)''',
);

ScriptLaunch _scriptLaunch(String path, HostOs os) {
  final text = _readSmall(path) ?? '';
  final ext = p.extension(path).toLowerCase();
  final kind = switch (ext) {
    '.bat' || '.cmd' => ScriptKind.batch,
    '.ps1' => ScriptKind.powershell,
    _ => ScriptKind.posix,
  };
  var executable = false;
  if (kind == ScriptKind.posix && os != HostOs.windows) {
    try {
      executable = File(path).statSync().mode & 0x49 != 0; // 0o111
    } on FileSystemException {
      executable = false;
    }
  }
  final firstLine = text.split('\n').first;
  return ScriptLaunch(
    path,
    kind: kind,
    executable: executable,
    bashOnly: firstLine.contains('bash') || _bashMarkers.any(text.contains),
    crlf: kind == ScriptKind.posix && text.contains('\r\n'),
    setsHeap: text.contains('-Xmx'),
    hardcodedJava: _hardcodedJava(text),
  );
}

/// Un java scritto con il percorso nello script, escluse le righe di
/// commento e i percorsi costruiti da variabili ($JAVA_HOME, %JAVA_HOME%),
/// che invece rispettano il runtime scelto.
String? _hardcodedJava(String text) {
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    final low = line.toLowerCase();
    if (line.startsWith('#') || line.startsWith('::') || low.startsWith('rem ')) continue;
    for (final m in [..._quotedJava.allMatches(line), ..._bareJava.allMatches(line)]) {
      final path = m.group(1)!;
      if (path.contains(r'$') || path.contains('%')) continue;
      return path;
    }
  }
  return null;
}

// File di argomenti di Forge/NeoForge 1.17+ installati in libraries/.
String? _findArgsFile(String dir, HostOs os) {
  final name = os == HostOs.windows ? 'win_args.txt' : 'unix_args.txt';
  for (final base in const [
    ['net', 'neoforged', 'neoforge'],
    ['net', 'neoforged', 'forge'],
    ['net', 'minecraftforge', 'forge'],
  ]) {
    final libs = p.joinAll([dir, 'libraries', ...base]);
    final v = _lastSubdir(libs);
    if (v == null) continue;
    if (File(p.join(libs, v, name)).existsSync()) {
      return ['libraries', ...base, v, name].join('/');
    }
  }
  return null;
}

String? _findLauncherJar(_Listing ls) {
  final jars = ls.jars.toList();
  for (final re in _launcherJars) {
    for (final n in jars) {
      if (re.hasMatch(n.toLowerCase())) return n;
    }
  }
  return null;
}

String? _detectLoader(_Listing ls) {
  final libs = p.join(ls.dir, 'libraries');
  String? loader;
  for (final (sub, name) in const [
    (['net', 'neoforged'], 'neoforge'),
    (['net', 'minecraftforge'], 'forge'),
    (['org', 'quiltmc'], 'quilt'), // Quilt pubblica su org.quiltmc
    (['net', 'fabricmc'], 'fabric'),
  ]) {
    if (Directory(p.joinAll([libs, ...sub])).existsSync()) {
      loader = name;
      break;
    }
  }
  // un server Quilt installa anche le librerie Fabric: il jar toglie il dubbio
  if (ls.has('quilt-server-launch.jar')) return 'quilt';
  if (loader == null && ls.has('fabric-server-launch.jar')) return 'fabric';
  if (loader == null) {
    final f = _forgeJar(ls);
    if (f != null) loader = f.neo ? 'neoforge' : 'forge';
  }
  if (loader == null && ls.has('server.properties')) loader = 'vanilla';
  return loader;
}

({String name, bool neo})? _forgeJar(_Listing ls) {
  for (final n in ls.jars) {
    final low = n.toLowerCase();
    if (low.startsWith('neoforge-')) return (name: n, neo: true);
    if (low.startsWith('forge-')) return (name: n, neo: false);
  }
  return null;
}

// forge-<mc>-<loader>[-universal].jar ; neoforge-<loader>.jar
String? _loaderVersionFromJars(_Listing ls) {
  final f = _forgeJar(ls);
  if (f == null) return null;
  final parts = p.withoutExtension(f.name).split('-');
  if (f.neo && parts.length >= 2) return parts[1];
  if (!f.neo && parts.length >= 3) return parts[2];
  return null;
}

/// Versione del loader Fabric o Quilt dalle librerie installate
/// (`net/fabricmc/fabric-loader/<ver>`, `org/quiltmc/quilt-loader/<ver>`):
/// i server Fabric non hanno un jar con la versione nel nome.
String? _loaderVersionFromLibraries(String root, String? loader) {
  final segs = switch (loader) {
    'fabric' => const ['net', 'fabricmc', 'fabric-loader'],
    'quilt' => const ['org', 'quiltmc', 'quilt-loader'],
    _ => null,
  };
  if (segs == null) return null;
  return _lastSubdir(p.joinAll([root, 'libraries', ...segs]));
}

/// Versione di Minecraft dalle librerie installate (B-SESSION-25):
/// `net/minecraft/server/<mc>-…`, Forge `forge/<mc>-<ver>`, NeoForge
/// `20.4.x` → `1.20.4`, Fabric `intermediary/<mc>`, Quilt `hashed/<mc>`.
String? mcVersionFromLibraries(String root) {
  String? last(List<String> segs) => _lastSubdir(p.joinAll([root, 'libraries', ...segs]));

  // le librerie del server vanilla valgono per ogni loader
  final vanilla = last(['net', 'minecraft', 'server'])?.split('-').first;
  if (_looksLikeMc(vanilla)) return vanilla;
  final forge = last(['net', 'minecraftforge', 'forge'])?.split('-').first;
  if (_looksLikeMc(forge)) return forge;
  // NeoForge 1.20.1 sta sotto net/neoforged/forge come "1.20.1-47.1.x"…
  final neoOld = last(['net', 'neoforged', 'forge'])?.split('-').first;
  if (_looksLikeMc(neoOld)) return neoOld;
  // …dalla 1.20.2 sotto net/neoforged/neoforge come "21.1.79" → "1.21.1"
  final neo = last(['net', 'neoforged', 'neoforge']);
  if (neo != null) {
    final parts = neo.split('.');
    final major = int.tryParse(parts.first);
    if (parts.length >= 2 && major != null && major >= 20 && major < 25) {
      final minor = int.tryParse(parts[1]);
      if (minor != null) return minor == 0 ? '1.$major' : '1.$major.$minor';
    }
  }
  for (final segs in const [
    ['net', 'fabricmc', 'intermediary'],
    ['org', 'quiltmc', 'hashed'],
  ]) {
    final v = last(segs);
    if (_looksLikeMc(v)) return v;
  }
  return null;
}

String? _versionFromVersionsDir(String dir) {
  final v = _lastSubdir(p.join(dir, 'versions'));
  return _looksLikeMc(v) ? v : null;
}

String? _versionFromJarNames(_Listing ls) {
  for (final name in ls.jars) {
    final n = name.toLowerCase();
    for (final re in _jarVersion) {
      final m = re.firstMatch(n);
      if (m != null) return m.group(1);
    }
  }
  return null;
}

({String id, int? java})? _versionFromServerJar(String dir) {
  final cands = <String>[];
  final v = _lastSubdir(p.join(dir, 'versions'));
  if (v != null) {
    cands.addAll([
      p.join(dir, 'versions', v, 'server-$v.jar'),
      p.join(dir, 'versions', v, 'server.jar'),
    ]);
  }
  cands.addAll([p.join(dir, 'server.jar'), p.join(dir, 'minecraft_server.jar')]);
  for (final jar in cands) {
    if (!File(jar).existsSync()) continue;
    final bytes = readJarEntry(jar, 'version.json');
    if (bytes == null) continue;
    try {
      final j = jsonDecode(utf8.decode(bytes));
      if (j is! Map<String, Object?>) continue;
      final id = (j['id'] ?? j['name']);
      if (id is! String || id.isEmpty) continue;
      final jv = j['java_version'] ?? (j['javaVersion'] as Map<String, Object?>?)?['majorVersion'];
      return (id: id, java: jv is int && jv > 0 ? jv : null);
    } on Object {
      continue;
    }
  }
  return null;
}

// Manifest del pack distribuito (CurseForge, Modrinth): l'unica fonte prima
// del primo avvio, quando libraries/ non esiste ancora.
String? _versionFromPackManifest(String dir) {
  Object? read(String name) {
    try {
      return jsonDecode(File(p.join(dir, name)).readAsStringSync());
    } on Object {
      return null;
    }
  }

  final cf = read('manifest.json');
  if (cf is Map<String, Object?>) {
    final mc = cf['minecraft'];
    if (mc is Map<String, Object?> &&
        mc['version'] is String &&
        _looksLikeMc(mc['version'] as String)) {
      return mc['version'] as String;
    }
  }
  final mr = read('modrinth.index.json');
  if (mr is Map<String, Object?>) {
    final deps = mr['dependencies'];
    if (deps is Map<String, Object?> &&
        deps['minecraft'] is String &&
        _looksLikeMc(deps['minecraft'] as String)) {
      return deps['minecraft'] as String;
    }
  }
  return null;
}

// La sottocartella "più alta" in ordine di versione: in ordine alfabetico,
// su un pack aggiornato sul posto con 1.20.1 e 1.21.1 vinceva 1.20.1 e si
// imponeva Java 17 a un server 1.21.
String? _lastSubdir(String dir) {
  String? best;
  try {
    for (final e in Directory(dir).listSync(followLinks: false)) {
      if (e is! Directory) continue;
      final name = p.basename(e.path);
      if (best == null || compareVersions(name, best) > 0) best = name;
    }
  } on FileSystemException {
    return null;
  }
  return best;
}

/// Confronta due stringhe di versione numero per numero.
int compareVersions(String a, String b) {
  final as = _nums(a), bs = _nums(b);
  for (var i = 0; i < as.length || i < bs.length; i++) {
    final x = i < as.length ? as[i] : 0;
    final y = i < bs.length ? bs[i] : 0;
    if (x != y) return x > y ? 1 : -1;
  }
  return a.compareTo(b);
}

final _digits = RegExp(r'\d+');

List<int> _nums(String s) => [for (final m in _digits.allMatches(s)) int.parse(m.group(0)!)];

int _leadingInt(String s) {
  final m = RegExp(r'^\d+').firstMatch(s);
  return m == null ? 0 : int.parse(m.group(0)!);
}

/// Major di Java richiesto da una versione di Minecraft (B-SESSION-26):
/// fino a 1.16.5 → 8; 1.17 … 1.20.4 → 17 (Mojang chiedeva il 16 per la 1.17,
/// ma è fuori supporto e il 17 la esegue); da 1.20.5 → 21. Ignota o non
/// `1.x` → 0.
int requiredJava(String? mcVersion) {
  if (mcVersion == null) return 0;
  final f = mcVersion.trim().split('.');
  if (f.length < 2) return 0;
  // Numerazione per anno (26.1, 26.2…): dalla 26.1 serve Java 25.
  final year = int.tryParse(f[0]);
  if (year != null && year >= 26) return 25;
  if (f[0] != '1') return 0;
  final minor = int.tryParse(f[1]);
  if (minor == null) return 0;
  final patch = f.length >= 3 ? _leadingInt(f[2]) : 0;
  if (minor <= 16) return 8;
  if (minor < 20) return 17;
  if (minor == 20) return patch <= 4 ? 17 : 21;
  return 21;
}

/// Major di una stringa di versione Java (B-SESSION-27): `1.8.0_x` → 8,
/// `17.0.9` → 17, `21.0.1+12` → 21, `24-ea` → 24; non riconoscibile → 0.
int javaMajor(String versionString) {
  final parts = versionString.trim().split('.');
  if (parts[0] == '1' && parts.length > 1) return _leadingInt(parts[1]);
  return _leadingInt(parts[0]);
}
