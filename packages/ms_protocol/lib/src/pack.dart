// Pacchetto per i giocatori: riassunto che l'hub calcola dal file
// minesync-pack.json della HEAD, per la scheda Mod dell'hub web e per l'app.
// I file veri sono GET /spaces/{id}/pack.mrpack e /pack-mods.zip.
import 'json.dart';
import 'models.dart';

/// Una mod del pacchetto che l'hub non può mettere nel file: va scaricata a
/// mano (CurseForge con la distribuzione vietata dall'autore, o un jar
/// aggiunto a mano che non è nella HEAD).
final class PackMissingMod {
  const PackMissingMod({required this.file, required this.source, this.name, this.pageUrl});

  factory PackMissingMod.fromJson(Object? j) {
    final m = obj(j, 'missing');
    return PackMissingMod(
      file: str(m, 'file'),
      source: str(m, 'source'),
      name: optStr(m, 'name'),
      pageUrl: optStr(m, 'pageUrl'),
    );
  }

  /// Nome del jar.
  final String file;

  /// `modrinth`, `curseforge` o `manual`.
  final String source;
  final String? name;

  /// Pagina da cui scaricarla (solo http/https), se nota.
  final String? pageUrl;

  Map<String, Object?> toJson() => {
    'file': file,
    'source': source,
    'name': ?name,
    'pageUrl': ?pageUrl,
  };
}

/// `GET /spaces/{id}/pack`: il pacchetto per i giocatori della HEAD.
final class ClientPack {
  const ClientPack({
    required this.n,
    required this.available,
    this.name,
    this.mcVersion,
    this.loader,
    this.loaderVersion,
    this.mods = 0,
    this.required = 0,
    this.optional = 0,
    this.serverOnly = 0,
    this.manual = 0,
    this.disabled = 0,
    this.missing = const [],
    this.fileName,
    this.size,
    this.modsZipName,
    this.modsZipSize,
  });

  factory ClientPack.fromJson(Object? j) {
    final m = obj(j, 'pack');
    return ClientPack(
      n: integer(m, 'n'),
      available: boolean(m, 'available'),
      name: optStr(m, 'name'),
      mcVersion: optStr(m, 'mcVersion'),
      loader: m['loader'] == null ? null : Loader.parse(m['loader']),
      loaderVersion: optStr(m, 'loaderVersion'),
      mods: optInt(m, 'mods') ?? 0,
      required: optInt(m, 'required') ?? 0,
      optional: optInt(m, 'optional') ?? 0,
      serverOnly: optInt(m, 'serverOnly') ?? 0,
      manual: optInt(m, 'manual') ?? 0,
      disabled: optInt(m, 'disabled') ?? 0,
      missing: optListOf(m, 'missing', PackMissingMod.fromJson),
      fileName: optStr(m, 'fileName'),
      size: optInt(m, 'size'),
      modsZipName: optStr(m, 'modsZipName'),
      modsZipSize: optInt(m, 'modsZipSize'),
    );
  }

  /// Generazione della HEAD da cui è calcolato (0 se lo spazio è vuoto).
  final int n;

  /// Falso se la HEAD non ha `minesync-pack.json` (server vanilla o non
  /// gestito): niente da scaricare, gli altri campi mancano.
  final bool available;
  final String? name;
  final String? mcVersion;
  final Loader? loader;
  final String? loaderVersion;

  /// Mod nel file del pacchetto (attive e spente).
  final int mods;

  /// Attive e obbligatorie sul PC dei giocatori.
  final int required;

  /// Attive e facoltative per i giocatori.
  final int optional;

  /// Attive e solo sul server (non vanno nel pacchetto).
  final int serverOnly;

  /// Aggiunte a mano (sorgente `manual`), qualunque lato.
  final int manual;

  /// Spente: non vanno da nessuna parte.
  final int disabled;

  /// Mod per i giocatori che il file non contiene.
  final List<PackMissingMod> missing;

  /// Nome suggerito del `.mrpack` (es. `Survival-129.mrpack`).
  final String? fileName;

  /// Byte esatti del `.mrpack`.
  final int? size;

  /// Nome e byte dello ZIP con le sole mod per i giocatori; null se nessuna
  /// è nella HEAD.
  final String? modsZipName;
  final int? modsZipSize;

  Map<String, Object?> toJson() => {
    'n': n,
    'available': available,
    'name': ?name,
    'mcVersion': ?mcVersion,
    if (loader != null) 'loader': loader!.name,
    'loaderVersion': ?loaderVersion,
    if (available) ...{
      'mods': mods,
      'required': required,
      'optional': optional,
      'serverOnly': serverOnly,
      'manual': manual,
      'disabled': disabled,
      'missing': [for (final x in missing) x.toJson()],
    },
    'fileName': ?fileName,
    'size': ?size,
    'modsZipName': ?modsZipName,
    'modsZipSize': ?modsZipSize,
  };
}
