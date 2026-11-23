// Runtime Java: ricerca, verifica e scelta.
//
// Modello di fiducia: la cartella del server è sincronizzata dall'hub,
// quindi chiunque possa pushare sullo spazio ne controlla il contenuto.
// Premere Play significa fidarsi dei membri dello spazio: lo script, le mod
// e l'eventuale runtime incluso nel pack vengono eseguiti. Prima del Play
// MineSync non esegue NULLA che stia dentro la cartella (B-SESSION-28): un
// java lì dentro viene riportato come trovato ma non verificato, con la
// versione letta dal file `release` del runtime, che è testo.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'detect.dart';

/// Un runtime Java trovato.
final class JavaRuntime {
  const JavaRuntime({
    required this.path,
    required this.major,
    required this.version,
    this.insideServer = false,
    this.verified = false,
    this.bits = 0,
  });

  /// Percorso dell'eseguibile java.
  final String path;

  /// Major (8, 17, 21…), 0 se ignoto.
  final int major;

  /// Stringa di versione completa, vuota se ignota.
  final String version;

  /// Sta dentro la cartella sincronizzata del server.
  final bool insideServer;

  /// La versione viene da `java -version` eseguito davvero.
  final bool verified;

  /// 64 o 32 bit, 0 se ignoto. Una JVM a 32 bit non regge un -Xmx grande.
  final int bits;

  /// Cartella home del runtime (quella sopra `bin`).
  String get home => p.dirname(p.dirname(path));

  @override
  String toString() =>
      'JavaRuntime($path, $major, "$version"${insideServer ? ', inside' : ''}'
      '${verified ? ', verified' : ''})';
}

/// Attesa massima di un `java -version`: un runtime rotto o lento non deve
/// bloccare il rilevamento.
const Duration javaProbeTimeout = Duration(seconds: 3);

final _versionRe = RegExp(r'version "([^"]+)"');

/// Esegue `<path> -version` e ne ricava la versione. Null se non parte, non
/// risponde entro [timeout] o non stampa una versione. NON controlla dove
/// sta il runtime: per quelli dentro la cartella del server va chiamata
/// solo dopo il Play.
Future<JavaRuntime?> probeJava(
  String path, {
  Duration timeout = javaProbeTimeout,
  bool insideServer = false,
}) async {
  final Process proc;
  try {
    proc = await Process.start(path, const ['-version'], runInShell: false);
  } on ProcessException {
    return null;
  }
  unawaited(proc.stdin.close().catchError((Object _) {}));
  final out = StringBuffer();
  final done = Future.wait([
    proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).forEach(out.write),
    proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).forEach(out.write),
  ]);
  final int code;
  try {
    code = await proc.exitCode.timeout(timeout);
    await done.timeout(timeout);
  } on TimeoutException {
    proc.kill(ProcessSignal.sigkill);
    return null;
  }
  if (code != 0) return null;
  final txt = out.toString();
  final m = _versionRe.firstMatch(txt);
  if (m == null) return null;
  final v = m.group(1)!;
  final major = javaMajor(v);
  if (major == 0) return null;
  var bits = 0;
  if (txt.contains('64-Bit')) {
    bits = 64;
  } else if (txt.contains('32-Bit') || txt.contains('Client VM')) {
    bits = 32;
  }
  return JavaRuntime(
    path: path,
    major: major,
    version: v,
    insideServer: insideServer,
    verified: true,
    bits: bits,
  );
}

/// [path] sta dentro [dir] o coincide con essa, su percorsi normalizzati:
/// `dir + "x"` non è dentro `dir` (B-SESSION-29).
bool isInside(String path, String dir) {
  if (path.isEmpty || dir.isEmpty) return false;
  final cp = p.canonicalize(path);
  final cd = p.canonicalize(dir);
  return cp == cd || p.isWithin(cd, cp);
}

/// Cerca i runtime Java: quelli inclusi nel pack dentro [serverRoot], poi
/// JAVA_HOME, PATH e le cartelle d'installazione tipiche del sistema
/// (Temurin/Adoptium, Zulu, Oracle, Microsoft, Corretto, /usr/lib/jvm,
/// /Library/Java/JavaVirtualMachines, i runtime dei launcher Minecraft…).
///
/// Esegue `java -version` SOLO sui runtime fuori dalla cartella del server
/// (B-SESSION-28). [env] sostituisce l'ambiente del processo (i test lo
/// usano per isolarsi); con [includeInstallDirs] falso si guardano solo pack,
/// JAVA_HOME e PATH. Risultato: prima i runtime del pack, poi per major
/// decrescente.
Future<List<JavaRuntime>> findJavaRuntimes({
  String? serverRoot,
  Map<String, String>? env,
  bool includeInstallDirs = true,
  Duration timeout = javaProbeTimeout,
}) async {
  final environment = env ?? Platform.environment;
  final os = HostOs.current;
  final exe = os == HostOs.windows ? 'java.exe' : 'java';
  final root = serverRoot == null || serverRoot.isEmpty
      ? null
      : p.normalize(p.absolute(serverRoot));

  final cands = <String>[
    if (root != null) ..._bundledJavas(root),
    if (_envValue(environment, 'JAVA_HOME', os) case final jh? when jh.isNotEmpty)
      p.join(jh, 'bin', exe),
    for (final dir in (_envValue(environment, 'PATH', os) ?? '').split(
      os == HostOs.windows ? ';' : ':',
    ))
      if (dir.isNotEmpty) p.join(dir, exe),
    if (includeInstallDirs) ..._installDirJavas(environment, os, exe),
  ];

  // deduplica sul percorso reale: i symlink di sistema (/usr/lib/jvm/default,
  // /etc/alternatives) puntano a runtime già in lista
  final seen = <String>{};
  final unique = <({String path, bool inside})>[];
  for (final c in cands) {
    if (!File(c).existsSync()) continue;
    // senza permesso di esecuzione non parte (capita con i runtime inclusi
    // nei pack copiati da Windows o da archivi zip): meglio non proporlo
    if (os != HostOs.windows && !_executable(c)) continue;
    // su macOS /usr/bin/java è uno stub che, senza un JDK, apre la finestra
    // "installa Java": i JDK veri si trovano comunque nelle loro cartelle
    if (os == HostOs.macos && c == '/usr/bin/java') continue;
    String real;
    try {
      real = File(c).resolveSymbolicLinksSync();
    } on FileSystemException {
      real = c;
    }
    final key = os == HostOs.windows ? real.toLowerCase() : real;
    if (!seen.add(key)) continue;
    final inside = root != null && (isInside(c, root) || isInside(real, root));
    unique.add((path: c, inside: inside));
  }

  final results = await Future.wait([
    for (final c in unique)
      c.inside ? Future.value(_unverified(c.path)) : probeJava(c.path, timeout: timeout),
  ]);

  final out = <JavaRuntime>[];
  final seenVersion = <String>{};
  for (final j in results) {
    if (j == null) continue;
    if (j.verified && !seenVersion.add('${j.version}/${j.bits}')) continue;
    out.add(j);
  }
  final order = {for (var i = 0; i < out.length; i++) out[i]: i};
  out.sort((a, b) {
    if (a.insideServer != b.insideServer) return a.insideServer ? -1 : 1;
    if (a.major != b.major) return b.major - a.major;
    return order[a]! - order[b]!;
  });
  return out;
}

String? _envValue(Map<String, String> env, String key, HostOs os) {
  if (os != HostOs.windows) return env[key];
  for (final e in env.entries) {
    if (e.key.toUpperCase() == key) return e.value;
  }
  return null;
}

/// Runtime incluso nel pack: mai eseguito, versione dal file `release`.
JavaRuntime _unverified(String path) {
  final home = p.dirname(p.dirname(path));
  var version = '';
  try {
    final release = File(p.join(home, 'release'));
    if (release.existsSync() && release.lengthSync() < 64 * 1024) {
      final m = RegExp(
        r'^JAVA_VERSION="?([^"\r\n]+)"?',
        multiLine: true,
      ).firstMatch(release.readAsStringSync());
      if (m != null) version = m.group(1)!;
    }
  } on FileSystemException {
    version = '';
  }
  return JavaRuntime(path: path, major: javaMajor(version), version: version, insideServer: true);
}

/// Vero se [path] ha almeno un bit di esecuzione (POSIX).
bool _executable(String path) {
  try {
    return FileStat.statSync(path).mode & 0x49 != 0; // 0o111
  } on FileSystemException {
    return false;
  }
}

// Molti pack includono un runtime: se la macchina non ha Java di sistema è
// l'unico modo di partire.
List<String> _bundledJavas(String root) {
  final out = <String>[];
  final dirPatterns = [
    ['runtime*'],
    ['jre*'],
    ['jdk*'],
    ['java*'],
    ['*', 'jre*'],
    ['*', 'jdk*'],
  ];
  final subs = [
    ['bin', 'java'],
    ['bin', 'java.exe'],
    ['Contents', 'Home', 'bin', 'java'],
  ];
  for (final d in dirPatterns) {
    for (final s in subs) {
      out.addAll(_glob(root, [...d, ...s]));
    }
  }
  return out;
}

List<String> _installDirJavas(Map<String, String> env, HostOs os, String exe) {
  final out = <String>[];
  void add(String? base, String rel) {
    if (base == null || base.isEmpty) return;
    out.addAll(_glob(base, rel.split('/')));
  }

  switch (os) {
    case HostOs.windows:
      final roots = [
        for (final k in ['ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432'])
          _envValue(env, k.toUpperCase(), os),
      ];
      const vendors = [
        'Eclipse Adoptium/*', 'Java/*', 'Microsoft/jdk-*', 'Zulu/*', 'Amazon Corretto/*', //
        'BellSoft/*', 'Eclipse Foundation/*', 'AdoptOpenJDK/*', 'Semeru/*', 'GraalVM/*',
        'SapMachine/*',
      ];
      for (final r in roots) {
        for (final v in vendors) {
          add(r, '$v/bin/$exe');
        }
      }
      final user = _envValue(env, 'USERPROFILE', os);
      final local = _envValue(env, 'LOCALAPPDATA', os);
      final roaming = _envValue(env, 'APPDATA', os);
      add(user, '.jdks/*/bin/$exe');
      // runtime dei launcher: sul PC di un giocatore il Java giusto c'è quasi
      // sempre, ma è quello del launcher, non un JDK di sistema
      for (final r in [local, roaming]) {
        add(r, '.minecraft/runtime/*/windows-x64/*/bin/$exe');
        add(
          r,
          'Packages/Microsoft.4297127D64EC6_8wekyb3d8bbwe/LocalCache/Local/runtime/*/windows-x64/*/bin/$exe',
        );
        add(r, 'PrismLauncher/java/*/bin/$exe');
        add(r, 'ATLauncher/runtimes/*/bin/$exe');
      }
    case HostOs.macos:
      add('/', 'Library/Java/JavaVirtualMachines/*/Contents/Home/bin/java');
      add('/', 'opt/homebrew/opt/openjdk*/bin/java');
      add('/', 'usr/local/opt/openjdk*/bin/java');
      final home = env['HOME'];
      add(home, 'Library/Java/JavaVirtualMachines/*/Contents/Home/bin/java');
      add(
        home,
        'Library/Application Support/minecraft/runtime/*/mac-os*/*/jre.bundle/Contents/Home/bin/java',
      );
      add(home, 'Library/Application Support/PrismLauncher/java/*/bin/java');
      add(home, '.sdkman/candidates/java/*/bin/java');
      add(home, '.jdks/*/bin/java');
    case HostOs.linux:
      add('/', 'usr/lib/jvm/*/bin/java');
      add('/', 'usr/lib/jvm/*/jre/bin/java');
      add('/', 'usr/lib64/jvm/*/bin/java');
      add('/', 'usr/java/*/bin/java');
      add('/', 'opt/java/*/bin/java');
      add('/', 'opt/*/bin/java');
      final home = env['HOME'];
      add(home, '.minecraft/runtime/*/linux/*/bin/java');
      add(home, '.local/share/PrismLauncher/java/*/bin/java');
      add(home, '.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher/java/*/bin/java');
      add(home, '.local/share/atlauncher/runtimes/*/bin/java');
      add(home, '.sdkman/candidates/java/*/bin/java');
      add(home, '.jdks/*/bin/java');
      add(home, '.gradle/jdks/*/bin/java');
  }
  return out;
}

/// Espansione minima: `*` dentro un segmento, nessuna ricorsione.
List<String> _glob(String base, List<String> segments) {
  var current = [base];
  for (var i = 0; i < segments.length; i++) {
    final seg = segments[i];
    final last = i == segments.length - 1;
    final next = <String>[];
    for (final dir in current) {
      if (!seg.contains('*')) {
        final cand = p.join(dir, seg);
        final type = FileSystemEntity.typeSync(cand);
        if (last
            ? type == FileSystemEntityType.file || type == FileSystemEntityType.link
            : type == FileSystemEntityType.directory || type == FileSystemEntityType.link) {
          next.add(cand);
        }
        continue;
      }
      final re = RegExp('^${seg.split('*').map(RegExp.escape).join('.*')}\$', caseSensitive: false);
      try {
        final names = [
          for (final e in Directory(dir).listSync(followLinks: true))
            if (e is Directory && re.hasMatch(p.basename(e.path))) e.path,
        ]..sort();
        next.addAll(names);
      } on FileSystemException {
        continue;
      }
    }
    current = next;
    if (current.isEmpty) break;
  }
  return current;
}

/// Sceglie il runtime per un server che vuole il major [required] (0 =
/// ignoto) (B-SESSION-29): quello esatto, altrimenti il più vicino fra i più
/// nuovi (di solito funzionano), solo in ultima istanza uno più vecchio (va
/// in UnsupportedClassVersionError all'istante: il chiamante confronti il
/// major e avvisi). Un runtime a 32 bit è penalizzato; a pari merito vince
/// quello del pack, poi l'ordine della lista. Null se la lista è vuota.
JavaRuntime? pickJava(List<JavaRuntime> found, int required) {
  int rank(JavaRuntime j) {
    var r = 0;
    if (required <= 0) {
      r = j.major > 0 ? 100 - j.major.clamp(0, 99) : 200;
      if (j.insideServer) r = 0;
    } else if (j.major == 0) {
      r = 500; // versione ignota: meglio di uno sicuramente troppo vecchio
    } else if (j.major == required) {
      r = 0;
    } else if (j.major > required) {
      r = 10 + (j.major - required);
    } else {
      r = 1000 + (required - j.major);
    }
    if (j.bits == 32) r += 300;
    return r;
  }

  JavaRuntime? best;
  var bestRank = 0;
  for (final j in found) {
    final r = rank(j);
    if (best == null || r < bestRank || (r == bestRank && j.insideServer && !best.insideServer)) {
      best = j;
      bestRank = r;
    }
  }
  return best;
}
