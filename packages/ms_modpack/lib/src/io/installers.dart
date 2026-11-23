// Installazione del server (vanilla, Fabric, Quilt, NeoForge, Forge) da
// sorgenti ufficiali: manifest delle versioni di Mojang (piston-meta), meta
// API di Fabric e Quilt, maven di NeoForge e Forge. I download si verificano
// per hash dove la sorgente lo dà (Mojang: SHA-1 del JSON della versione e
// del jar; maven: il file .sha1 accanto). Gli installer di Quilt, NeoForge e
// Forge girano con il Java scelto da chi chiama (ms_minecraft: pickJava con
// requiredJava). L'EULA si scrive solo se [ServerInstallRequest.acceptEula]
// è vero, cioè dopo il clic esplicito dell'utente. Tutto parte da un'azione
// dell'utente; nei test solo falsi.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ms_minecraft/ms_minecraft.dart' show acceptEula;
import 'package:ms_protocol/ms_protocol.dart' show Loader;
import 'package:path/path.dart' as p;

import 'files.dart';

/// Manifest delle versioni di Mojang.
const String mojangManifestUrl = 'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json';
const String fabricMeta = 'https://meta.fabricmc.net/v2';
const String quiltMeta = 'https://meta.quiltmc.org/v3';
const String quiltMaven = 'https://maven.quiltmc.org/repository/release';
const String neoforgeMaven = 'https://maven.neoforged.net/releases';
const String forgeMaven = 'https://maven.minecraftforge.net';

/// Esecuzione di un processo (l'installer): iniettata, nei test un falso.
abstract interface class ProcessRunner {
  /// Esegue e restituisce il codice d'uscita; [onLine] riceve stdout e stderr
  /// riga per riga.
  Future<int> run(
    String executable,
    List<String> args, {
    required String workingDirectory,
    void Function(String line)? onLine,
  });
}

/// [ProcessRunner] con dart:io.
final class IoProcessRunner implements ProcessRunner {
  const IoProcessRunner();

  @override
  Future<int> run(
    String executable,
    List<String> args, {
    required String workingDirectory,
    void Function(String line)? onLine,
  }) async {
    final proc = await Process.start(
      executable,
      args,
      workingDirectory: workingDirectory,
      runInShell: false,
    );
    unawaited(proc.stdin.close().catchError((Object _) {}));
    final lines = [
      proc.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter()),
      proc.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter()),
    ];
    await Future.wait([for (final s in lines) s.forEach((l) => onLine?.call(l))]);
    return proc.exitCode;
  }
}

/// Una versione di Minecraft nel manifest di Mojang.
final class MojangVersion {
  const MojangVersion({
    required this.id,
    required this.type,
    required this.url,
    this.sha1,
    this.releaseTime = 0,
  });

  final String id;

  /// `release`, `snapshot`, `old_beta`, `old_alpha`.
  final String type;
  final String url;
  final String? sha1;
  final int releaseTime;
}

/// L'installer non è andato.
final class InstallFailed implements Exception {
  const InstallFailed(this.step, this.message);

  /// `version`, `download`, `installer`, `java`.
  final String step;
  final String message;
  @override
  String toString() => 'InstallFailed($step): $message';
}

/// Che cosa installare.
final class ServerInstallRequest {
  const ServerInstallRequest({
    required this.dir,
    required this.mcVersion,
    required this.loader,
    this.loaderVersion,
    this.javaPath,
    this.acceptEula = false,
  });

  /// Cartella del server (si crea se manca).
  final String dir;
  final String mcVersion;
  final Loader loader;

  /// Null: l'ultima stabile per [mcVersion].
  final String? loaderVersion;

  /// Java per gli installer (Quilt, NeoForge, Forge): quello scelto con
  /// ms_minecraft. Se manca per questi loader → [InstallFailed] `java` (la UI
  /// mostra il link a Temurin, mai un download automatico).
  final String? javaPath;

  /// L'utente ha premuto «Accetto l'EULA»: solo allora si scrive eula.txt.
  final bool acceptEula;
}

/// Esito.
final class ServerInstallResult {
  const ServerInstallResult({
    required this.loader,
    required this.mcVersion,
    this.loaderVersion,
    required this.launchJar,
    this.javaMajor,
    this.eulaWritten = false,
  });

  final Loader loader;
  final String mcVersion;
  final String? loaderVersion;

  /// File da lanciare relativo alla cartella (jar o, per NeoForge/Forge
  /// recenti, lo script `run.sh`/`run.bat` creato dall'installer).
  final String launchJar;

  /// Java richiesto da Mojang per questa versione, se noto.
  final int? javaMajor;
  final bool eulaWritten;
}

/// Gli installer dei server.
final class ServerInstaller {
  ServerInstaller(this.dl, {ProcessRunner? runner}) : _run = runner ?? const IoProcessRunner();

  final Downloader dl;
  final ProcessRunner _run;

  // ---------------------------------------------------------------- versioni

  /// Versioni del manifest di Mojang, dalla più recente.
  Future<List<MojangVersion>> mojangVersions() async {
    final j = _o(await dl.fetchJson(mojangManifestUrl), 'manifest');
    final vs = j['versions'];
    if (vs is! List<Object?>) throw const InstallFailed('version', 'manifest senza versions');
    return [
      for (final v in vs)
        if (v is Map<String, Object?> && v['id'] is String && v['url'] is String)
          MojangVersion(
            id: v['id']! as String,
            type: v['type'] as String? ?? 'release',
            url: v['url']! as String,
            sha1: v['sha1'] as String?,
            releaseTime:
                DateTime.tryParse(v['releaseTime'] as String? ?? '')?.millisecondsSinceEpoch ?? 0,
          ),
    ];
  }

  /// Ultima release di Minecraft.
  Future<String> latestRelease() async {
    final j = _o(await dl.fetchJson(mojangManifestUrl), 'manifest');
    final l = j['latest'];
    if (l is Map<String, Object?> && l['release'] is String) return l['release']! as String;
    throw const InstallFailed('version', 'manifest senza latest.release');
  }

  /// Versioni del loader per [mcVersion], dalla più recente; `stable` se la
  /// sorgente lo dice.
  Future<List<(String, bool)>> loaderVersions(Loader loader, String mcVersion) async {
    switch (loader) {
      case Loader.fabric || Loader.quilt:
        final base = loader == Loader.fabric ? fabricMeta : quiltMeta;
        final j = await dl.fetchJson('$base/versions/loader/${Uri.encodeComponent(mcVersion)}');
        if (j is! List<Object?>) return const [];
        return [
          for (final e in j)
            if (e is Map<String, Object?> && e['loader'] is Map<String, Object?>)
              if ((e['loader']! as Map<String, Object?>)['version'] case final String v)
                (
                  v,
                  (e['loader']! as Map<String, Object?>)['stable'] != false && !v.contains('beta'),
                ),
        ];
      case Loader.neoforge:
        final j = _o(
          await dl.fetchJson(
            'https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/neoforge',
          ),
          'neoforge',
        );
        final all = (j['versions'] as List<Object?>? ?? const []).whereType<String>();
        final prefix = neoforgePrefix(mcVersion);
        if (prefix == null) return const [];
        return [
          for (final v in all.toList().reversed)
            if (v.startsWith(prefix)) (v, !v.contains('beta')),
        ];
      case Loader.forge:
        final j = _o(
          await dl.fetchJson(
            'https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json',
          ),
          'forge',
        );
        final promos = j['promos'];
        if (promos is! Map<String, Object?>) return const [];
        return [
          if (promos['$mcVersion-recommended'] case final String v) (v, true),
          if (promos['$mcVersion-latest'] case final String v)
            if (v != promos['$mcVersion-recommended']) (v, false),
        ];
      case Loader.vanilla || Loader.paper:
        return const [];
    }
  }

  // ---------------------------------------------------------------- install

  /// Installa il server richiesto. Il server vanilla (`server.jar`, verificato
  /// con lo SHA-1 di Mojang) c'è sempre: Fabric lo usa accanto al suo
  /// launcher, gli installer di Quilt/Forge/NeoForge lo trovano già lì.
  Future<ServerInstallResult> install(
    ServerInstallRequest r, {
    void Function(String line)? onLine,
  }) async {
    if (r.loader == Loader.paper) throw const InstallFailed('version', 'paper non supportato');
    await Directory(r.dir).create(recursive: true);
    final javaMajor = await _vanilla(r.dir, r.mcVersion);
    String? lv = r.loaderVersion;
    if (r.loader != Loader.vanilla && lv == null) {
      final vs = await loaderVersions(r.loader, r.mcVersion);
      lv = (vs.where((v) => v.$2).firstOrNull ?? vs.firstOrNull)?.$1;
      if (lv == null) {
        throw InstallFailed('version', '${r.loader.name}: nessuna versione per ${r.mcVersion}');
      }
    }
    final launch = switch (r.loader) {
      Loader.vanilla || Loader.paper => 'server.jar',
      Loader.fabric => await _fabric(r.dir, r.mcVersion, lv!),
      Loader.quilt => await _quilt(r, lv!, onLine),
      Loader.neoforge => await _neoforge(r, lv!, onLine),
      Loader.forge => await _forge(r, lv!, onLine),
    };
    if (r.acceptEula) await acceptEula(r.dir);
    return ServerInstallResult(
      loader: r.loader,
      mcVersion: r.mcVersion,
      loaderVersion: r.loader == Loader.vanilla ? null : lv,
      launchJar: launch,
      javaMajor: javaMajor,
      eulaWritten: r.acceptEula,
    );
  }

  /// `server.jar` di Mojang; restituisce il Java richiesto.
  Future<int?> _vanilla(String dir, String mc) async {
    final v = (await mojangVersions()).where((v) => v.id == mc).firstOrNull;
    if (v == null) throw InstallFailed('version', 'Minecraft $mc non esiste');
    final j = _o(await dl.fetchJson(v.url, sha1: v.sha1), 'version');
    final downloads = j['downloads'];
    final server = downloads is Map<String, Object?> ? downloads['server'] : null;
    if (server is! Map<String, Object?> || server['url'] is! String) {
      throw InstallFailed('version', 'Minecraft $mc non ha un server');
    }
    await dl.download(
      [server['url']! as String],
      p.join(dir, 'server.jar'),
      sha1: server['sha1'] as String?,
      size: server['size'] as int?,
    );
    final jv = j['javaVersion'];
    return jv is Map<String, Object?> && jv['majorVersion'] is int
        ? jv['majorVersion']! as int
        : null;
  }

  /// Launcher del server Fabric: `fabric-server-launch.jar` (il nome che
  /// ms_minecraft riconosce). La meta API non dà hash: si registra quello
  /// ottenuto.
  Future<String> _fabric(String dir, String mc, String loader) async {
    final inst = await dl.fetchJson('$fabricMeta/versions/installer');
    final installer = inst is List<Object?>
        ? inst
              .whereType<Map<String, Object?>>()
              .where((e) => e['stable'] == true && e['version'] is String)
              .map((e) => e['version']! as String)
              .firstOrNull
        : null;
    if (installer == null) throw const InstallFailed('version', 'nessun installer Fabric');
    final url =
        '$fabricMeta/versions/loader/${Uri.encodeComponent(mc)}/'
        '${Uri.encodeComponent(loader)}/${Uri.encodeComponent(installer)}/server/jar';
    await dl.download([url], p.join(dir, 'fabric-server-launch.jar'));
    return 'fabric-server-launch.jar';
  }

  Future<String> _quilt(
    ServerInstallRequest r,
    String loader,
    void Function(String)? onLine,
  ) async {
    final java = _java(r);
    final inst = await dl.fetchJson('$quiltMeta/versions/installer');
    final v = inst is List<Object?>
        ? inst
              .whereType<Map<String, Object?>>()
              .map((e) => e['version'])
              .whereType<String>()
              .firstOrNull
        : null;
    if (v == null) throw const InstallFailed('version', 'nessun installer Quilt');
    final base = '$quiltMaven/org/quiltmc/quilt-installer/$v/quilt-installer-$v.jar';
    final jar = await _installerJar(r.dir, base, 'quilt-installer.jar');
    try {
      await _exec(
        java,
        ['-jar', jar, 'install', 'server', r.mcVersion, loader, '--install-dir=${r.dir}'],
        r.dir,
        onLine,
      );
    } finally {
      await File(jar).delete().catchError((Object _) => File(jar));
    }
    return 'quilt-server-launch.jar';
  }

  Future<String> _neoforge(
    ServerInstallRequest r,
    String version,
    void Function(String)? onLine,
  ) async {
    final java = _java(r);
    final url = '$neoforgeMaven/net/neoforged/neoforge/$version/neoforge-$version-installer.jar';
    final jar = await _installerJar(r.dir, url, 'neoforge-installer.jar');
    try {
      await _exec(java, ['-jar', jar, '--installServer', r.dir], r.dir, onLine);
    } finally {
      await File(jar).delete().catchError((Object _) => File(jar));
      await File('$jar.log').delete().catchError((Object _) => File(jar));
    }
    return Platform.isWindows ? 'run.bat' : 'run.sh';
  }

  Future<String> _forge(
    ServerInstallRequest r,
    String version,
    void Function(String)? onLine,
  ) async {
    final java = _java(r);
    final full = '${r.mcVersion}-$version';
    final url = '$forgeMaven/net/minecraftforge/forge/$full/forge-$full-installer.jar';
    final jar = await _installerJar(r.dir, url, 'forge-installer.jar');
    try {
      await _exec(java, ['-jar', jar, '--installServer', r.dir], r.dir, onLine);
    } finally {
      await File(jar).delete().catchError((Object _) => File(jar));
      await File('$jar.log').delete().catchError((Object _) => File(jar));
    }
    return Platform.isWindows ? 'run.bat' : 'run.sh';
  }

  String _java(ServerInstallRequest r) {
    final j = r.javaPath;
    if (j == null || j.isEmpty) throw const InstallFailed('java', 'serve Java per l\'installer');
    return j;
  }

  /// Scarica un installer dal maven, verificato con il `.sha1` accanto se il
  /// maven lo pubblica.
  Future<String> _installerJar(String dir, String url, String name) async {
    String? sha1;
    try {
      final b = await dl.fetch('$url.sha1', max: 256);
      final s = utf8.decode(b, allowMalformed: true).trim().split(RegExp(r'\s+')).first;
      if (RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(s)) sha1 = s.toLowerCase();
    } on DownloadFailed {
      sha1 = null; // il maven non lo pubblica: si scarica senza verifica
    }
    final dest = p.join(dir, '$modpackTmpDir-$name');
    await dl.download([url], dest, sha1: sha1);
    return dest;
  }

  Future<void> _exec(
    String java,
    List<String> args,
    String dir,
    void Function(String)? onLine,
  ) async {
    final code = await _run.run(java, args, workingDirectory: dir, onLine: onLine);
    if (code != 0) throw InstallFailed('installer', 'uscito con il codice $code');
  }

  static Map<String, Object?> _o(Object? j, String what) =>
      j is Map<String, Object?> ? j : throw InstallFailed('version', '$what: risposta non valida');
}

/// Prefisso delle versioni di NeoForge per una versione di Minecraft:
/// `1.21.1` → `21.1.`, `1.20.4` → `20.4.`, `1.21` → `21.0.`; numerazione per
/// anno `26.1` → `26.1.0.`, `26.1.2` → `26.1.2.`. Null se non riconoscibile
/// (NeoForge esiste da 1.20.2).
String? neoforgePrefix(String mc) {
  final f = mc.split('.');
  if (f.any((s) => int.tryParse(s) == null)) return null;
  final n = f.map(int.parse).toList();
  if (n[0] == 1 && n.length >= 2) {
    if (n[1] < 20) return null;
    return '${n[1]}.${n.length >= 3 ? n[2] : 0}.';
  }
  if (n[0] >= 26 && n.length >= 2) return '${n[0]}.${n[1]}.${n.length >= 3 ? n[2] : 0}.';
  return null;
}
