// Servizi del modpack sostituibili nei test: trasporto HTTP verso Modrinth
// e i siti dei loader, cache delle risposte, esecuzione degli installer, e
// gli strumenti del PC per il pacchetto dei giocatori (Prism Launcher,
// launcher ufficiale, cartella Download, apertura dei link). Nei test tutto
// è finto: mai la rete vera, mai processi veri.
import 'dart:io';

import 'package:ms_modpack/io.dart';
import 'package:ms_modpack/ms_modpack.dart';
import 'package:path/path.dart' as p;

import 'pack_browser.dart';

/// Versione dell'app nello User-Agent di Modrinth.
const modpackAppVersion = '0.1.0';

/// Strumenti del PC per il pacchetto dei giocatori.
abstract interface class ClientTools {
  /// Eseguibile di Prism Launcher, o null se non c'è.
  Future<String?> prism();

  /// Apre [mrpack] nella finestra di importazione di Prism.
  Future<void> openInPrism(String exe, String mrpack);

  /// Cartella del launcher ufficiale (`.minecraft`) se esiste, o null.
  String? officialLauncher();

  /// Cartella dove finiscono i file esportati (Download dell'utente).
  String downloads();

  /// Apre [url] nel browser del sistema.
  Future<void> openUrl(String url);
}

/// Strumenti veri: cercano nei percorsi abituali di ogni sistema.
final class IoClientTools implements ClientTools {
  const IoClientTools({this.env = const {}});

  /// Variabili d'ambiente (quelle del processo se vuote).
  final Map<String, String> env;

  Map<String, String> get _env => env.isEmpty ? Platform.environment : env;

  String get _home => _env['HOME'] ?? _env['USERPROFILE'] ?? Directory.current.path;

  @override
  Future<String?> prism() async {
    final candidates = <String>[
      if (Platform.isWindows) ...[
        p.join(_env['LOCALAPPDATA'] ?? '', 'Programs', 'PrismLauncher', 'prismlauncher.exe'),
        p.join(_env['ProgramFiles'] ?? r'C:\Program Files', 'PrismLauncher', 'prismlauncher.exe'),
      ] else if (Platform.isMacOS) ...[
        '/Applications/Prism Launcher.app/Contents/MacOS/prismlauncher',
        p.join(_home, 'Applications', 'Prism Launcher.app', 'Contents', 'MacOS', 'prismlauncher'),
      ] else ...[
        for (final d in (_env['PATH'] ?? '/usr/bin:/usr/local/bin').split(':'))
          if (d.isNotEmpty) p.join(d, 'prismlauncher'),
        '/var/lib/flatpak/exports/bin/org.prismlauncher.PrismLauncher',
        p.join(_home, '.local/share/flatpak/exports/bin/org.prismlauncher.PrismLauncher'),
      ],
    ];
    for (final c in candidates) {
      if (c.isNotEmpty && File(c).existsSync()) return c;
    }
    return null;
  }

  @override
  Future<void> openInPrism(String exe, String mrpack) async {
    // `--import` apre il dialogo di importazione di Prism con il file
    await Process.start(exe, ['--import', mrpack], mode: ProcessStartMode.detached);
  }

  @override
  String? officialLauncher() {
    final dir = Platform.isWindows
        ? p.join(_env['APPDATA'] ?? '', '.minecraft')
        : Platform.isMacOS
        ? p.join(_home, 'Library', 'Application Support', 'minecraft')
        : p.join(_home, '.minecraft');
    return Directory(dir).existsSync() ? dir : null;
  }

  @override
  String downloads() {
    final d = p.join(_home, 'Downloads');
    return Directory(d).existsSync() ? d : _home;
  }

  @override
  Future<void> openUrl(String url) async {
    final u = Uri.tryParse(url);
    if (u == null || (u.scheme != 'https' && u.scheme != 'http')) return;
    final (cmd, args) = Platform.isWindows
        ? ('rundll32', ['url.dll,FileProtocolHandler', url])
        : Platform.isMacOS
        ? ('open', [url])
        : ('xdg-open', [url]);
    await Process.start(cmd, args, mode: ProcessStartMode.detached);
  }
}

/// Le dipendenze del modpack.
final class ModpackEnv {
  ModpackEnv({
    required this.transport,
    ResponseCache? cache,
    this.tools = const IoClientTools(),
    this.runner,
    this.retryEvery = const Duration(seconds: 30),
    Future<void> Function(Duration)? sleep,
    String? iconDir,
    Downloader? downloader,
    this.scanMods = scanModFiles,
  }) : icons = IconCache(transport, userAgent: modrinthUserAgent(modpackAppVersion), dir: iconDir),
       modrinth = ModrinthClient(
         transport: transport,
         userAgent: modrinthUserAgent(modpackAppVersion),
         cache: cache,
         sleep: sleep,
       ),
       downloader =
           downloader ?? Downloader(transport, userAgent: modrinthUserAgent(modpackAppVersion));

  /// I servizi veri: HTTP di dart:io e cache su disco in [configDir].
  factory ModpackEnv.io(String configDir, {Map<String, String> env = const {}}) => ModpackEnv(
    transport: IoHttpTransport(),
    cache: FileResponseCache(p.join(configDir, 'cache', 'modrinth')),
    tools: IoClientTools(env: env),
    iconDir: p.join(configDir, 'cache', 'icons'),
    // i file grandi (modpack, mod, server) si scaricano fuori dal thread della UI
    downloader: Downloader.isolated(userAgent: modrinthUserAgent(modpackAppVersion)),
    scanMods: scanModFilesIsolated,
  );

  final HttpTransport transport;
  final ModrinthClient modrinth;
  final Downloader downloader;

  /// I jar delle mod di una cartella, con gli hash ([scanModFiles]).
  final Future<List<LocalFile>> Function(String root) scanMods;
  final ClientTools tools;

  /// Icone dei progetti di Modrinth (memoria e disco).
  final IconCache icons;

  /// Esecutore degli installer dei loader (null = processi veri).
  final ProcessRunner? runner;

  /// Ogni quanto si riprova Modrinth quando non risponde.
  final Duration retryEvery;

  ServerInstaller installer() => ServerInstaller(downloader, runner: runner);
}
