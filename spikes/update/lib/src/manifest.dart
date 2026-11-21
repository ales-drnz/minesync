// Manifest di rilascio firmato.
//
// Sull'hub, per ogni piattaforma:
//   update/<platform>/manifest.json      JSON (byte esatti firmati)
//   update/<platform>/manifest.json.sig  firma ed25519 in base64 dei byte sopra
//   update/<platform>/<archive.name>     tar.gz dell'app (o file singolo)
//
// Si verifica la firma sui BYTE ricevuti prima di fare il parse del JSON: non
// serve una forma canonica e il parser non vede mai dati non autenticati.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const manifestSchema = 1;
const appId = 'minesync-desktop';

/// "archive": tar.gz da estrarre in versions/<v>/ (cartella portabile,
/// Windows, macOS). "file": un singolo file che sostituisce sé stesso
/// (AppImage).
enum PackageKind { archive, file }

class ManifestFile {
  final String path; // relativo, separatore '/'
  final int size;
  final String sha256; // hex minuscolo; vuoto per i symlink
  final int mode; // permessi POSIX (ottale 0755 = 493)
  final String? link; // destinazione se symlink (relativa, dentro l'albero)
  ManifestFile(this.path, this.size, this.sha256, this.mode, this.link);

  bool get isLink => link != null;

  Map<String, Object?> toJson() => {
        'path': path,
        if (link == null) 'size': size,
        if (link == null) 'sha256': sha256,
        if (link == null) 'mode': mode.toRadixString(8),
        if (link != null) 'link': link,
      };

  factory ManifestFile.fromJson(Map<String, Object?> j) {
    final link = j['link'] as String?;
    return ManifestFile(
      j['path'] as String,
      link == null ? j['size'] as int : 0,
      link == null ? j['sha256'] as String : '',
      link == null ? int.parse(j['mode'] as String, radix: 8) : 511,
      link,
    );
  }
}

class Manifest {
  final int schema;
  final String app;
  final String version;
  final String platform; // es. linux-x64, windows-x64, macos-arm64
  final PackageKind kind;
  final String archiveName;
  final int archiveSize;
  final String archiveSha256;
  final String entrypoint; // eseguibile relativo alla cartella della versione
  final String? launcher; // launcher incluso nel pacchetto (per aggiornarlo)
  final List<ManifestFile> files;

  Manifest({
    this.schema = manifestSchema,
    this.app = appId,
    required this.version,
    required this.platform,
    required this.kind,
    required this.archiveName,
    required this.archiveSize,
    required this.archiveSha256,
    required this.entrypoint,
    this.launcher,
    this.files = const [],
  });

  Map<String, Object?> toJson() => {
        'schema': schema,
        'app': app,
        'version': version,
        'platform': platform,
        'kind': kind.name,
        'archive': {'name': archiveName, 'size': archiveSize, 'sha256': archiveSha256},
        'entrypoint': entrypoint,
        if (launcher != null) 'launcher': launcher,
        'files': [for (final f in files) f.toJson()],
      };

  Uint8List encode() => Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(toJson())));

  factory Manifest.fromJson(Map<String, Object?> j) {
    final a = j['archive'] as Map<String, Object?>;
    return Manifest(
      schema: j['schema'] as int,
      app: j['app'] as String,
      version: j['version'] as String,
      platform: j['platform'] as String,
      kind: PackageKind.values.byName(j['kind'] as String),
      archiveName: a['name'] as String,
      archiveSize: a['size'] as int,
      archiveSha256: a['sha256'] as String,
      entrypoint: j['entrypoint'] as String,
      launcher: j['launcher'] as String?,
      files: [
        for (final f in (j['files'] as List? ?? const []))
          ManifestFile.fromJson((f as Map).cast<String, Object?>())
      ],
    );
  }
}

class SignatureException implements Exception {
  final String msg;
  SignatureException(this.msg);
  @override
  String toString() => 'firma non valida: $msg';
}

final _ed = Ed25519();

/// Verifica [sigB64] (base64 di 64 byte) su [bytes] con la chiave pubblica
/// [pubB64] (base64 di 32 byte) e solo dopo fa il parse del manifest.
Future<Manifest> verifyManifest(Uint8List bytes, String sigB64, String pubB64) async {
  final Uint8List sig, pub;
  try {
    sig = base64.decode(sigB64.trim());
    pub = base64.decode(pubB64.trim());
  } on FormatException {
    throw SignatureException('base64');
  }
  if (sig.length != 64 || pub.length != 32) throw SignatureException('lunghezza');
  final ok = await _ed.verify(bytes,
      signature: Signature(sig, publicKey: SimplePublicKey(pub, type: KeyPairType.ed25519)));
  if (!ok) throw SignatureException('non corrisponde alla chiave pubblica incorporata');
  final Object? j;
  try {
    j = jsonDecode(utf8.decode(bytes));
  } on FormatException catch (e) {
    throw SignatureException('manifest firmato ma illeggibile: $e');
  }
  final m = Manifest.fromJson((j as Map).cast<String, Object?>());
  if (m.schema != manifestSchema || m.app != appId) {
    throw SignatureException('schema/app inattesi');
  }
  return m;
}

/// Firma [bytes] col seme privato [seedB64] (32 byte). Usato dal tool di firma.
Future<String> signBytes(Uint8List bytes, String seedB64) async {
  final kp = await _ed.newKeyPairFromSeed(base64.decode(seedB64.trim()));
  final s = await _ed.sign(bytes, keyPair: kp);
  return base64.encode(s.bytes);
}

/// Genera (seme privato, chiave pubblica) in base64.
Future<(String, String)> generateKeyPair() async {
  final kp = await _ed.newKeyPair();
  final seed = await kp.extractPrivateKeyBytes();
  final pub = await kp.extractPublicKey();
  return (base64.encode(seed), base64.encode(pub.bytes));
}
