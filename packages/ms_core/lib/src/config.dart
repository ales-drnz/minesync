// Configurazione dell'app su questo PC: hub, server collegati a cartelle e
// preferenze locali. Un file JSON nella cartella di configurazione del
// sistema operativo, scritto in modo atomico.
import 'dart:convert';
import 'dart:io';

import 'atomic.dart';

/// Cartella di configurazione di MineSync per questo utente.
String configDir(Map<String, String> env) {
  final override = env['MINESYNC_CONFIG_DIR'];
  if (override != null && override.isNotEmpty) return override;
  if (Platform.isWindows) {
    return '${env['APPDATA'] ?? '${env['USERPROFILE']}\\AppData\\Roaming'}\\MineSync';
  }
  final home = env['HOME'] ?? '.';
  if (Platform.isMacOS) return '$home/Library/Application Support/MineSync';
  final xdg = env['XDG_CONFIG_HOME'];
  return '${xdg != null && xdg.isNotEmpty ? xdg : '$home/.config'}/minesync';
}

final class AppConfig {
  AppConfig({this.hub, Map<String, String>? links, this.lang, Map<String, Object?>? prefs})
    : links = links ?? <String, String>{},
      prefs = prefs ?? <String, Object?>{};

  /// Legge la configurazione; un file assente dà una configurazione vuota,
  /// uno illeggibile è un errore (meglio fermarsi che dimenticare i link).
  static AppConfig load(String dir) {
    final f = File('$dir${Platform.pathSeparator}config.json');
    if (!f.existsSync()) return AppConfig();
    final j = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
    final links = (j['links'] as Map<String, Object?>?) ?? const {};
    return AppConfig(
      hub: j['hub'] as String?,
      links: {for (final e in links.entries) e.key: e.value! as String},
      lang: j['lang'] as String?,
      prefs: (j['prefs'] as Map<String, Object?>?) ?? {},
    );
  }

  String? hub;

  /// Server (id dello spazio) → cartella locale assoluta.
  final Map<String, String> links;
  String? lang;

  /// Preferenze locali dell'app (tema, banda, per server…): valori JSON.
  final Map<String, Object?> prefs;

  Future<void> save(String dir) async {
    Directory(dir).createSync(recursive: true);
    await writeAtomic(
      '$dir${Platform.pathSeparator}config.json',
      utf8.encode(
        const JsonEncoder.withIndent('  ').convert({
          'v': 1,
          'hub': ?hub,
          'links': links,
          'lang': ?lang,
          if (prefs.isNotEmpty) 'prefs': prefs,
        }),
      ),
    );
  }
}
