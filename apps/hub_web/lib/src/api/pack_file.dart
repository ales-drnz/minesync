// Il file minesync-pack.json della HEAD visto dalla web UI: solo quello che
// serve alla scheda Mod (lato, facoltativa, spenta, sorgente di ogni mod).
// Lettura tollerante: un campo che manca prende il default del formato
// (docs/design/modpack.md); un file illeggibile vale come assente.
import 'dart:convert';

/// Nome del file del pack nella radice del server.
const packFileName = 'minesync-pack.json';

/// Una mod del pack.
final class PackEntry {
  const PackEntry({
    required this.path,
    this.name,
    this.side = 'both',
    this.optional = false,
    this.disabled = false,
    this.source = 'manual',
    this.version,
    this.size = 0,
  });

  /// Percorso nell'istanza (`mods/x.jar`).
  final String path;
  final String? name;

  /// `client`, `server` o `both`.
  final String side;
  final bool optional;
  final bool disabled;

  /// `modrinth`, `curseforge` o `manual`.
  final String source;
  final String? version;
  final int size;

  /// Nome del jar.
  String get file => path.substring(path.lastIndexOf('/') + 1);
  bool get onClient => side != 'server';
}

/// Il pack: versione, loader e mod.
final class PackFile {
  const PackFile({
    required this.mcVersion,
    required this.loader,
    this.loaderVersion,
    this.mods = const [],
  });

  final String mcVersion;
  final String loader;
  final String? loaderVersion;
  final List<PackEntry> mods;

  /// Mod per nome del jar (minuscolo).
  Map<String, PackEntry> get byFile => {for (final m in mods) m.file.toLowerCase(): m};

  /// Il pack da JSON già decodificato, o null se non è un pack valido.
  static PackFile? fromJson(Object? j) {
    if (j is! Map<String, Object?> || j['format'] != 1) return null;
    final mc = j['minecraft'], loader = j['loader'];
    if (mc is! String || loader is! String) return null;
    final list = j['mods'];
    return PackFile(
      mcVersion: mc,
      loader: loader,
      loaderVersion: j['loaderVersion'] is String ? j['loaderVersion']! as String : null,
      mods: [
        if (list is List<Object?>)
          for (final m in list)
            if (m is Map<String, Object?> && m['path'] is String)
              PackEntry(
                path: m['path']! as String,
                name: m['name'] is String ? m['name']! as String : null,
                side: m['side'] is String ? m['side']! as String : 'both',
                optional: m['optional'] == true,
                disabled: m['disabled'] == true,
                source: m['source'] is String ? m['source']! as String : 'manual',
                version: m['versionNumber'] is String ? m['versionNumber']! as String : null,
                size: m['size'] is int ? m['size']! as int : 0,
              ),
      ],
    );
  }

  static PackFile? tryParse(String text) {
    try {
      return fromJson(jsonDecode(text));
    } on FormatException {
      return null;
    }
  }
}
