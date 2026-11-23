// Pacchetto per i giocatori: l'hub lo costruisce al volo dalla
// HEAD, partendo da minesync-pack.json e dai file della generazione, senza
// rete (gli URL dei download sono nel file del pack). Tre rotte:
//   GET /spaces/{id}/pack          → riassunto ClientPack
//   GET /spaces/{id}/pack.mrpack   → il .mrpack in streaming
//   GET /spaces/{id}/pack-mods.zip → solo le mod per i giocatori, in streaming
// Una generazione è immutabile: il piano si tiene per (spazio, digest).
import 'dart:convert';
import 'dart:io';

import 'package:ms_modpack/ms_modpack.dart';
import 'package:ms_protocol/ms_protocol.dart';

import '../members.dart';
import '../store.dart';
import '../zip.dart';
import 'blob_source.dart';

/// Tetto al file del pack letto dalla HEAD.
const int packFileMax = 4 << 20;

/// Tipo MIME dei `.mrpack` (quello di Modrinth).
const String mrpackMime = 'application/x-modrinth-modpack+zip';

final class _Built {
  _Built({
    required this.n,
    required this.digest,
    required this.ts,
    required this.summary,
    this.mrpack,
    this.modsZip,
    this.fileName,
    this.modsZipName,
  });

  final int n;
  final String digest;
  final int ts;
  final ClientPack summary;
  final List<ZipItem>? mrpack;
  final List<ZipItem>? modsZip;
  final String? fileName;
  final String? modsZipName;
}

/// Le rotte del pacchetto per i giocatori.
final class PackRoutes {
  PackRoutes(this._store, {void Function(String)? log, this.cacheEntries = 16})
    : _log = log ?? ((m) => stderr.writeln(m));

  final HubStore _store;
  final void Function(String) _log;
  final int cacheEntries;
  final _lru = <String, _Built>{};

  /// Gestisce le rotte; false se [segs] (dopo /api/v1) non sono sue.
  Future<bool> handle(HttpRequest req, Identity who, bool admin, List<String> segs) async {
    if (req.method != 'GET' || segs.length != 3 || segs[0] != 'spaces') return false;
    final id = segs[1];
    switch (segs[2]) {
      case 'pack':
        final b = await _build(id);
        final res = req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(b.summary.toJson()));
        await res.close();
      case 'pack.mrpack':
        final b = await _build(id);
        if (b.mrpack == null) throw const ApiError(ErrorCode.notFound, 'no player pack');
        await _zip(req, b, b.mrpack!, b.fileName!, mrpackMime);
      case 'pack-mods.zip':
        final b = await _build(id);
        if (b.modsZip == null) throw const ApiError(ErrorCode.notFound, 'no player mods');
        await _zip(req, b, b.modsZip!, b.modsZipName!, 'application/zip');
      default:
        return false;
    }
    return true;
  }

  /// Dimentica uno spazio (cancellato).
  void forget(String space) => _lru.removeWhere((k, _) => k.startsWith('$space/'));

  Future<_Built> _build(String id) async {
    final g = await _store.generation(id, null);
    final key = '$id/${g.digest}';
    final hit = _lru.remove(key);
    if (hit != null) return _lru[key] = hit;
    final b = await _compute(id, g);
    _lru[key] = b;
    while (_lru.length > cacheEntries) {
      _lru.remove(_lru.keys.first);
    }
    return b;
  }

  Future<_Built> _compute(String id, Generation g) async {
    final none = _Built(
      n: g.n,
      digest: g.digest,
      ts: g.summary.ts,
      summary: ClientPack(n: g.n, available: false),
    );
    if (g.n == 0) return none;
    final m = g.manifest;
    final entry = m[packFileName];
    if (entry == null) return none;
    final bytes = await readManifestFile(_store.blobs, entry, max: packFileMax);
    if (bytes == null) {
      _log('hub: $id #${g.n}: $packFileName illeggibile o troppo grande');
      return none;
    }
    final Pack pack;
    try {
      pack = Pack.decode(utf8.decode(bytes, allowMalformed: false));
    } on FormatException catch (e) {
      _log('hub: $id #${g.n}: $packFileName non valido: ${e.message}');
      return none;
    }
    final spaceName = _store.summary(id).name;
    final base = '${_safeName(pack.name ?? spaceName)}-${g.n}';
    final plan = planClientPack(
      pack,
      m.files.keys,
      versionId: '${g.n}',
      name: pack.name ?? spaceName,
    );
    final index = ZipItem.bytes(name: mrpackIndexName, data: plan.index.encode());
    ZipItem item(PackZipEntry e) {
      final f = m[e.serverPath]!;
      return ZipItem(name: e.zipPath, size: f.size, blobs: f.blobs.toList());
    }

    final mrpack = [index, for (final e in plan.overrides) item(e)];
    final mods = [for (final e in plan.modsZip) item(e)];
    final time = DateTime.fromMillisecondsSinceEpoch(g.summary.ts);
    final mrLen = ZipPlan(mrpack, time: time).length;
    final modsLen = mods.isEmpty ? null : ZipPlan(mods, time: time).length;
    return _Built(
      n: g.n,
      digest: g.digest,
      ts: g.summary.ts,
      summary: plan.summary(
        n: g.n,
        fileName: '$base.mrpack',
        size: mrLen,
        modsZipName: mods.isEmpty ? null : '$base-mods.zip',
        modsZipSize: modsLen,
      ),
      mrpack: mrpack,
      modsZip: mods.isEmpty ? null : mods,
      fileName: '$base.mrpack',
      modsZipName: mods.isEmpty ? null : '$base-mods.zip',
    );
  }

  Future<void> _zip(
    HttpRequest req,
    _Built b,
    List<ZipItem> items,
    String fileName,
    String mime,
  ) async {
    final need = {for (final i in items) ...i.blobs};
    final release = _store.leaseBlobs(need);
    try {
      final missing = [
        for (final h in need)
          if (!_store.blobs.has(h)) h,
      ];
      if (missing.isNotEmpty) {
        throw ApiError(
          ErrorCode.blobsMissing,
          'generation ${b.n}: ${missing.length} blobs are missing',
          details: {'missing': missing.take(1000).toList()},
        );
      }
      final plan = ZipPlan(items, time: DateTime.fromMillisecondsSinceEpoch(b.ts));
      final res = req.response;
      // stesso digest e stesso file = stessi byte
      final etag = '"${b.digest}-${items.length}-${plan.length}"';
      res.headers
        ..set(HttpHeaders.etagHeader, etag)
        ..set(HttpHeaders.cacheControlHeader, 'private, no-cache');
      final inm = req.headers.value(HttpHeaders.ifNoneMatchHeader);
      if (inm != null && inm.split(',').map((s) => s.trim()).contains(etag)) {
        res.statusCode = HttpStatus.notModified;
        await res.close();
        return;
      }
      res
        ..statusCode = 200
        ..headers.contentType = ContentType.parse(mime)
        ..headers.set('Content-Disposition', 'attachment; filename="$fileName"')
        ..contentLength = plan.length;
      try {
        await plan.write(res, _store.blobs.pathOf);
      } catch (e) {
        _log('hub: pacchetto $fileName interrotto: $e');
      }
      try {
        await res.close();
      } catch (_) {
        // connessione chiusa o corpo più corto del dichiarato
      }
    } finally {
      release();
    }
  }
}

/// Nome di file sicuro per Content-Disposition: lettere, cifre, `.`, `_`,
/// `-` e spazi; il resto diventa `_`.
String _safeName(String s) {
  final t = s.replaceAll(RegExp(r'[^A-Za-z0-9 ._-]'), '_').trim();
  return t.isEmpty ? 'pack' : (t.length > 60 ? t.substring(0, 60) : t);
}
