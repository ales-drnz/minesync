// Download dell'app desktop serviti da MINESYNC_DL (/dl) e loro elenco
// (`GET /api/v1/dl`).
import 'admin.dart' show UpdateChannel;
import 'json.dart';
import 'models.dart' show obj, str, integer;

/// Sistema operativo di un file scaricabile.
enum DlOs {
  windows,
  macos,
  linux;

  static DlOs parse(Object? v) => enumOf(values, v, 'sistema');
}

/// Un file in cima a MINESYNC_DL.
final class DlFile {
  const DlFile({
    required this.name,
    required this.os,
    required this.size,
    this.arch,
    this.version,
    this.sha256,
  });

  factory DlFile.fromJson(Object? j) {
    final m = obj(j, 'file');
    return DlFile(
      name: str(m, 'name'),
      os: DlOs.parse(m['os']),
      size: integer(m, 'size'),
      arch: optStr(m, 'arch'),
      version: optStr(m, 'version'),
      sha256: optStr(m, 'sha256'),
    );
  }

  /// Nome del file: si scarica da `/dl/<name>`.
  final String name;
  final DlOs os;
  final int size;

  /// `x64`, `arm64` o `universal`; null se il nome non lo dice.
  final String? arch;

  /// Versione letta dal nome del file.
  final String? version;

  /// Da SHA256SUMS, se c'è.
  final String? sha256;

  Map<String, Object?> toJson() => {
    'name': name,
    'os': os.name,
    'size': size,
    if (arch != null) 'arch': arch,
    if (version != null) 'version': version,
    if (sha256 != null) 'sha256': sha256,
  };
}

/// `GET /api/v1/dl`.
final class DlListing {
  const DlListing({required this.files, this.updates = const [], this.signedSums = false});

  factory DlListing.fromJson(Object? j) {
    final m = obj(j, 'dl');
    return DlListing(
      files: listOf(m, 'files', DlFile.fromJson),
      updates: optListOf(m, 'updates', UpdateChannel.fromJson),
      signedSums: optBool(m, 'signedSums') ?? false,
    );
  }

  /// Ordinati per sistema e poi per nome. Mai SHA256SUMS(.sig) né update/.
  final List<DlFile> files;

  /// Piattaforme con l'aggiornamento automatico (`/dl/update/<platform>/`).
  final List<UpdateChannel> updates;

  /// SHA256SUMS ha la sua firma SHA256SUMS.sig.
  final bool signedSums;

  Map<String, Object?> toJson() => {
    'files': [for (final f in files) f.toJson()],
    if (updates.isNotEmpty) 'updates': [for (final u in updates) u.toJson()],
    'signedSums': signedSums,
  };
}
