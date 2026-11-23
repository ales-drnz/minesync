// Supporto dei test: un trasporto HTTP finto e risposte nella forma dell'API
// v2 di Modrinth, scritte a mano dalla documentazione pubblica (dati
// inventati, nessun payload copiato).
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:ms_modpack/ms_modpack.dart';

String sha1Of(List<int> b) => crypto.sha1.convert(b).toString();
String sha512Of(List<int> b) => crypto.sha512.convert(b).toString();
String sha256Of(List<int> b) => crypto.sha256.convert(b).toString();

/// Byte finti e riconoscibili per un file.
Uint8List fakeJar(String name) => Uint8List.fromList(utf8.encode('jar:$name'));

typedef Handler = HttpRes Function(HttpReq req);

/// Trasporto finto: risponde con il primo gestore il cui prefisso combacia
/// con `METODO percorso`; registra le richieste.
final class FakeTransport implements HttpTransport {
  FakeTransport([Map<String, Handler>? routes]) : routes = {...?routes};

  final Map<String, Handler> routes;
  final requests = <HttpReq>[];

  @override
  Future<HttpRes> send(HttpReq req) async {
    requests.add(req);
    final key = '${req.method} ${req.url.host}${req.url.path}';
    for (final e in routes.entries) {
      if (key == e.key ||
          (e.key.endsWith('*') && key.startsWith(e.key.substring(0, e.key.length - 1)))) {
        return e.value(req);
      }
    }
    return HttpRes.bytes(404, utf8.encode('{"error":"not_found","description":"nope"}'));
  }
}

HttpRes json(Object? body, {int status = 200, Map<String, String> headers = const {}}) =>
    HttpRes.bytes(status, utf8.encode(jsonEncode(body)), headers: headers);

/// Un id Modrinth finto di 8 caratteri.
String mrId(String s) => '${s.replaceAll(RegExp('[^A-Za-z0-9]'), '')}xxxxxxxx'.substring(0, 8);

/// Un file di versione nella forma di Modrinth.
Map<String, Object?> fileJson(String project, String version, String filename) {
  final b = fakeJar(filename);
  return {
    'hashes': {'sha1': sha1Of(b), 'sha512': sha512Of(b)},
    'url': 'https://cdn.modrinth.com/data/$project/versions/$version/$filename',
    'filename': filename,
    'primary': true,
    'size': b.length,
    'file_type': null,
  };
}

/// Una versione nella forma di Modrinth.
Map<String, Object?> versionJson({
  required String id,
  required String project,
  required String number,
  List<String> game = const ['1.21.1'],
  List<String> loaders = const ['fabric'],
  String type = 'release',
  String date = '2026-01-01T00:00:00Z',
  List<Map<String, Object?>> deps = const [],
  String? filename,
}) => {
  'id': id,
  'project_id': project,
  'author_id': 'author01',
  'featured': false,
  'name': '$project $number',
  'version_number': number,
  'changelog': 'Fixes',
  'dependencies': deps,
  'game_versions': game,
  'version_type': type,
  'loaders': loaders,
  'status': 'listed',
  'date_published': date,
  'downloads': 10,
  'files': [fileJson(project, id, filename ?? '$project-$number.jar')],
};

Map<String, Object?> dep(String? project, {String? version, String type = 'required'}) => {
  'version_id': version,
  'project_id': project,
  'file_name': null,
  'dependency_type': type,
};

/// Un progetto nella forma di Modrinth.
Map<String, Object?> projectJson(
  String id, {
  String? title,
  String client = 'required',
  String server = 'required',
  String type = 'mod',
}) => {
  'id': id,
  'slug': id.toLowerCase(),
  'project_type': type,
  'team': 'team0001',
  'title': title ?? id,
  'description': 'A mod',
  'body': '',
  'categories': ['utility'],
  'client_side': client,
  'server_side': server,
  'downloads': 1000,
  'icon_url': 'https://cdn.modrinth.com/data/$id/icon.png',
  'license': {'id': 'MIT', 'name': 'MIT License', 'url': null},
  'versions': <String>[],
  'game_versions': ['1.21.1'],
  'loaders': ['fabric'],
};

MrVersion v(
  String id,
  String project,
  String number, {
  List<String> game = const ['1.21.1'],
  List<String> loaders = const ['fabric'],
  String type = 'release',
  int day = 1,
  List<Map<String, Object?>> deps = const [],
}) => MrVersion.fromJson(
  versionJson(
    id: id,
    project: project,
    number: number,
    game: game,
    loaders: loaders,
    type: type,
    date: DateTime.utc(2026, 1, day).toIso8601String(),
    deps: deps,
  ),
);

MrProject proj(String id, {String client = 'required', String server = 'required'}) =>
    MrProject.fromJson(projectJson(id, client: client, server: server));

/// Pack Fabric 1.21.1 con le mod date.
Pack fabricPack(Iterable<PackMod> mods) => Pack(
  name: 'Survival',
  mcVersion: '1.21.1',
  loader: Loader.fabric,
  loaderVersion: '0.16.14',
  mods: mods,
);

/// La voce del pack per la versione [ver] (come se fosse installata).
PackMod installed(MrVersion ver, {MrProject? project, bool pinned = false, bool auto = false}) =>
    modFromVersion(ver, project: project, auto: auto).copyWith(pinned: pinned);

/// Una voce manuale con byte finti.
PackMod manual(String path, {PackSide side = PackSide.server}) {
  final b = fakeJar(path);
  return PackMod(path: path, sha1: sha1Of(b), sha512: sha512Of(b), size: b.length, side: side);
}
