// Download dell'app desktop e file dell'aggiornamento automatico, da
// MINESYNC_DL.
//
//   <dl>/<file>                              installer e pacchetti (elencati)
//   <dl>/SHA256SUMS, SHA256SUMS.sig          somme e loro firma (non elencati)
//   <dl>/update/<platform>/manifest.json     come li legge apps/launcher
//   <dl>/update/<platform>/manifest.json.sig   (UpdateHub, base <hub>/dl/)
//   <dl>/update/<platform>/<archive.name>
//
// Fuori da /api/v1 ma con le stesse guardie (Host e intestazioni le mette il
// server, l'identità si chiede qui: 401 senza); solo GET/HEAD, Range
// supportato. Si servono solo nomi `[A-Za-z0-9._+-]+` senza punto iniziale,
// file regolari il cui percorso reale resta dentro la cartella: tutto il
// resto è 404.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ms_protocol/ms_protocol.dart';

final _name = RegExp(r'^[A-Za-z0-9._+-]+$');

/// Nome servibile: una sola parte di percorso, niente file nascosti né `..`.
bool dlNameOk(String s) => s.isNotEmpty && !s.startsWith('.') && _name.hasMatch(s);

/// Sistema dal nome del file, o null se il file non è un pacchetto da
/// elencare.
DlOs? dlOsOf(String name) {
  final n = name.toLowerCase();
  // gli archivi della CLI non sono l'app: la pagina dei download li ignora
  // (restano nella release su GitHub)
  if (n.contains('-cli.')) return null;
  if (n.endsWith('.exe') || n.endsWith('.msi')) return DlOs.windows;
  if (n.endsWith('.dmg') || n.endsWith('.pkg')) return DlOs.macos;
  if (n.endsWith('.appimage') ||
      n.endsWith('.deb') ||
      n.endsWith('.rpm') ||
      n.endsWith('.tar.gz')) {
    if (n.contains('-macos-')) return DlOs.macos;
    if (n.contains('-windows-')) return DlOs.windows;
    return DlOs.linux;
  }
  return null;
}

final _x64 = RegExp(r'(?<![a-z0-9])(x86_64|x86-64|x64|amd64)(?![a-z0-9])');
final _arm64 = RegExp(r'(?<![a-z0-9])(arm64|aarch64)(?![a-z0-9])');
final _universal = RegExp(r'(?<![a-z0-9])universal(?![a-z0-9])');

/// `x64`, `arm64`, `universal` dal nome, o null.
String? dlArchOf(String name) {
  final n = name.toLowerCase();
  if (_universal.hasMatch(n)) return 'universal';
  if (_arm64.hasMatch(n)) return 'arm64';
  if (_x64.hasMatch(n)) return 'x64';
  return null;
}

final _version = RegExp(
  r'(?<![0-9.])v?(\d+\.\d+\.\d+(?:-(?:alpha|beta|rc|pre|dev)(?:\.?\d+)?)?)(?![0-9])',
  caseSensitive: false,
);

/// Versione `x.y.z` (con un eventuale `-rc.1` e simili) dal nome, o null.
String? dlVersionOf(String name) => _version.firstMatch(name)?.group(1);

/// Le righe `<hex>  <nome>` (o `<hex> *<nome>`) di SHA256SUMS.
Map<String, String> parseSha256Sums(String text) {
  final out = <String, String>{};
  final line = RegExp(r'^([0-9a-fA-F]{64}) [ *]?(\S.*)$');
  for (final l in const LineSplitter().convert(text)) {
    final m = line.firstMatch(l.trim());
    if (m != null) out[m[2]!.trim()] = m[1]!.toLowerCase();
  }
  return out;
}

/// I download e l'aggiornamento automatico; [dir] null = niente /dl.
final class Downloads {
  Downloads(this.dir);

  /// MINESYNC_DL, o null.
  final String? dir;

  static const _maxManifest = 1 << 20;
  static const _maxSums = 1 << 20;

  /// La cartella in forma reale (symlink risolti), o null se manca.
  Future<String?> _root() async {
    final d = dir;
    if (d == null) return null;
    try {
      return await Directory(d).resolveSymbolicLinks();
    } on FileSystemException {
      return null;
    }
  }

  /// Il file [rel] (relativo, '/'), solo se è un file regolare e il suo
  /// percorso reale sta dentro [root].
  static Future<File?> _safe(String root, String rel) async {
    final p = '$root/$rel';
    try {
      if (await FileSystemEntity.type(p) != FileSystemEntityType.file) return null;
      final real = await File(p).resolveSymbolicLinks();
      if (!real.startsWith('$root/')) return null;
      return File(real);
    } on FileSystemException {
      return null;
    }
  }

  static Future<String?> _readText(File f, int limit) async {
    try {
      if (await f.length() > limit) return null;
      return utf8.decode(await f.readAsBytes(), allowMalformed: true);
    } on FileSystemException {
      return null;
    }
  }

  /// `GET /api/v1/dl` (B-DL-01): i pacchetti in cima alla cartella, ordinati
  /// per sistema e nome, con le somme di SHA256SUMS e le piattaforme di
  /// update/.
  Future<DlListing> listing() async {
    final root = await _root();
    if (root == null) return const DlListing(files: []);
    final sumsFile = await _safe(root, 'SHA256SUMS');
    final sums = sumsFile == null
        ? const <String, String>{}
        : parseSha256Sums(await _readText(sumsFile, _maxSums) ?? '');
    final files = <DlFile>[];
    try {
      await for (final e in Directory(root).list(followLinks: false)) {
        final name = e.path.substring(root.length + 1);
        if (!dlNameOk(name)) continue;
        final os = dlOsOf(name);
        if (os == null) continue;
        final f = await _safe(root, name);
        if (f == null) continue;
        files.add(
          DlFile(
            name: name,
            os: os,
            size: await f.length(),
            arch: dlArchOf(name),
            version: dlVersionOf(name),
            sha256: sums[name],
          ),
        );
      }
    } on FileSystemException {
      // cartella sparita a metà: si elenca quello che c'è
    }
    files.sort((a, b) {
      final c = a.os.index.compareTo(b.os.index);
      return c != 0 ? c : a.name.compareTo(b.name);
    });
    return DlListing(
      files: files,
      updates: await _updates(root),
      signedSums: await _safe(root, 'SHA256SUMS.sig') != null,
    );
  }

  /// Piattaforme con l'aggiornamento automatico pubblicato (per GET /system).
  Future<List<UpdateChannel>> updates() async {
    final root = await _root();
    return root == null ? const [] : _updates(root);
  }

  Future<List<UpdateChannel>> _updates(String root) async {
    final out = <UpdateChannel>[];
    final up = Directory('$root/update');
    try {
      if (!await up.exists()) return out;
      await for (final e in up.list(followLinks: false)) {
        final platform = e.path.substring(up.path.length + 1);
        if (!dlNameOk(platform)) continue;
        final m = await _safe(root, 'update/$platform/manifest.json');
        if (m == null) continue;
        final text = await _readText(m, _maxManifest);
        if (text == null) continue;
        final String version;
        try {
          final j = jsonDecode(text);
          if (j is! Map<String, Object?> || j['version'] is! String) continue;
          version = j['version']! as String;
        } on FormatException {
          continue;
        }
        out.add(
          UpdateChannel(
            platform: platform,
            version: version,
            signed: await _safe(root, 'update/$platform/manifest.json.sig') != null,
          ),
        );
      }
    } on FileSystemException {
      // come sopra
    }
    out.sort((a, b) => a.platform.compareTo(b.platform));
    return out;
  }

  /// Serve `/dl/<file>` e `/dl/update/<platform>/<name>`. False per `/dl`
  /// e `/dl/` (la pagina della SPA) e per i percorsi fuori da /dl; lancia
  /// [ApiError] `unauthenticated` se [identify] non riconosce chi chiama e
  /// `not_found` per tutto ciò che non si serve.
  Future<bool> handle(HttpRequest req, Future<Object?> Function() identify) async {
    final segs = req.uri.pathSegments;
    if (segs.isEmpty || segs.first != 'dl') return false;
    if (segs.length == 1 || (segs.length == 2 && segs[1].isEmpty)) return false;
    if (await identify() == null) {
      throw const ApiError(
        ErrorCode.unauthenticated,
        'this device is not a member of the private network: join the network to use the hub',
      );
    }
    if (req.method != 'GET' && req.method != 'HEAD') {
      throw const ApiError(ErrorCode.notFound, 'no such download');
    }
    final root = await _root();
    if (root == null) throw const ApiError(ErrorCode.notFound, 'no downloads on this hub');
    final rest = segs.sublist(1);
    if (!rest.every(dlNameOk)) throw const ApiError(ErrorCode.notFound, 'no such download');
    final String rel;
    final String type;
    String? attachment;
    switch (rest) {
      case [final name] when name == 'SHA256SUMS' || name == 'SHA256SUMS.sig':
        rel = name;
        type = 'text/plain; charset=utf-8';
      case [final name] when dlOsOf(name) != null:
        rel = name;
        type = 'application/octet-stream';
        attachment = name;
      case ['update', final platform, final name]:
        rel = 'update/$platform/$name';
        type = switch (name) {
          'manifest.json' => 'application/json; charset=utf-8',
          'manifest.json.sig' => 'text/plain; charset=utf-8',
          _ when name.endsWith('.tar.gz') || name.endsWith('.tgz') => 'application/gzip',
          _ => 'application/octet-stream',
        };
      default:
        throw const ApiError(ErrorCode.notFound, 'no such download');
    }
    final f = await _safe(root, rel);
    if (f == null) throw const ApiError(ErrorCode.notFound, 'no such download');
    await serveFile(req, f, type: type, attachment: attachment);
    return true;
  }
}

/// Manda [f] con `Cache-Control: no-cache`, ETag (dimensione e data),
/// If-None-Match → 304 e `Range` → 206/416.
Future<void> serveFile(HttpRequest req, File f, {required String type, String? attachment}) async {
  final res = req.response;
  final stat = await f.stat();
  final len = stat.size;
  final etag =
      '"${len.toRadixString(16)}-${stat.modified.microsecondsSinceEpoch.toRadixString(16)}"';
  res.headers
    ..set(HttpHeaders.cacheControlHeader, 'no-cache')
    ..set(HttpHeaders.etagHeader, etag)
    ..set(HttpHeaders.acceptRangesHeader, 'bytes')
    ..set(HttpHeaders.contentTypeHeader, type);
  if (attachment != null) {
    res.headers.set('Content-Disposition', 'attachment; filename="$attachment"');
  }
  final inm = req.headers.value(HttpHeaders.ifNoneMatchHeader);
  if (inm != null && inm.split(',').any((t) => t.trim() == etag || t.trim() == '*')) {
    res.statusCode = HttpStatus.notModified;
    return res.close();
  }
  var start = 0, end = len - 1; // estremi inclusi
  final range = req.headers.value(HttpHeaders.rangeHeader);
  final ifRange = req.headers.value('If-Range');
  if (range != null && (ifRange == null || ifRange.trim() == etag)) {
    final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range.trim());
    var ok = m != null && (m[1]!.isNotEmpty || m[2]!.isNotEmpty);
    if (ok) {
      if (m[1]!.isEmpty) {
        start = max(0, len - int.parse(m[2]!)); // suffisso: ultimi n byte
      } else {
        start = int.parse(m[1]!);
        if (m[2]!.isNotEmpty) end = min(int.parse(m[2]!), len - 1);
      }
      ok = start < len && start <= end;
    }
    if (!ok) {
      res
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */$len');
      return res.close();
    }
    res
      ..statusCode = HttpStatus.partialContent
      ..headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$len');
  }
  res.contentLength = len == 0 ? 0 : end - start + 1;
  if (req.method == 'HEAD' || len == 0) return res.close();
  await res.addStream(f.openRead(start, end + 1));
  await res.close();
}
