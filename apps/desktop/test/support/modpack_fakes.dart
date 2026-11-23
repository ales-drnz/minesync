// Modrinth, siti dei loader e strumenti del PC finti per i test del modpack:
// un trasporto HTTP in memoria con risposte nella forma dell'API v2 di
// Modrinth (dati inventati), un esecutore di processi che non esegue niente
// e strumenti che ricordano cosa è stato chiesto. Mai la rete vera.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:minesync_desktop/src/state/app_state.dart';
import 'package:ms_modpack/io.dart';
import 'package:ms_modpack/ms_modpack.dart';

String sha1Of(List<int> b) => crypto.sha1.convert(b).toString();
String sha512Of(List<int> b) => crypto.sha512.convert(b).toString();

/// Byte finti e riconoscibili di un jar.
Uint8List fakeJar(String name) => Uint8List.fromList(utf8.encode('jar:$name'));

typedef Handler = HttpRes Function(HttpReq req);

/// Trasporto finto: il primo gestore il cui `METODO host/percorso` combacia
/// (anche con `*` finale); le altre richieste sono 404.
final class FakeTransport implements HttpTransport {
  FakeTransport([Map<String, Handler>? routes]) : routes = {...?routes};

  final Map<String, Handler> routes;
  final requests = <HttpReq>[];

  /// Fa rispondere ogni richiesta con un errore di rete.
  bool offline = false;

  @override
  Future<HttpRes> send(HttpReq req) async {
    requests.add(req);
    if (offline) throw HttpUnavailable(req.url, 'offline');
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

HttpRes jsonRes(Object? body, {int status = 200}) =>
    HttpRes.bytes(status, utf8.encode(jsonEncode(body)));

/// Un file di versione di Modrinth.
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

/// Una versione di Modrinth.
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

Map<String, Object?> dep(String project) => {
  'version_id': null,
  'project_id': project,
  'file_name': null,
  'dependency_type': 'required',
};

/// Un progetto di Modrinth.
Map<String, Object?> projectJson(
  String id, {
  String? title,
  String client = 'required',
  String server = 'required',
}) => {
  'id': id,
  'slug': id.toLowerCase(),
  'project_type': 'mod',
  'team': 'team0001',
  'title': title ?? id,
  'description': 'A mod',
  'body': '',
  'categories': ['utility'],
  'client_side': client,
  'server_side': server,
  'downloads': 1000,
  'icon_url': null,
  'license': {'id': 'MIT', 'name': 'MIT License', 'url': null},
  'versions': <String>[],
  'game_versions': ['1.21.1'],
  'loaders': ['fabric'],
};

/// Un risultato di ricerca di Modrinth.
Map<String, Object?> hitJson(
  String id, {
  String? title,
  List<String> categories = const ['fabric'],
  List<String> versions = const ['1.21.1'],
  int downloads = 41000000,
  String author = 'someone',
}) => {
  'project_id': id,
  'slug': id.toLowerCase(),
  'title': title ?? id,
  'description': 'teleport between stones',
  'author': author,
  'project_type': 'mod',
  'categories': categories,
  'versions': versions,
  'downloads': downloads,
  'icon_url': null,
  'client_side': 'required',
  'server_side': 'required',
  'latest_version': 'v1',
  'license': 'MIT',
};

/// Un Modrinth finto con progetti e versioni: versioni per progetto,
/// riconoscimento per SHA-1, download dei file dal CDN.
final class FakeModrinth {
  FakeModrinth();

  final projects = <String, Map<String, Object?>>{};
  final versions = <String, List<Map<String, Object?>>>{};
  final hits = <Map<String, Object?>>[];

  /// Byte dei file sul CDN per URL (i file di [versionJson] sono già lì).
  final cdn = <String, List<int>>{};

  void addProject(Map<String, Object?> p, List<Map<String, Object?>> vs) {
    projects[p['id']! as String] = p;
    versions[p['id']! as String] = vs;
    for (final v in vs) {
      for (final f in (v['files']! as List).cast<Map<String, Object?>>()) {
        cdn[f['url']! as String] = fakeJar(f['filename']! as String);
      }
    }
  }

  Iterable<Map<String, Object?>> get _allVersions => versions.values.expand((l) => l);

  Map<String, Handler> get routes => {
    'GET api.modrinth.com/v2/search': (_) =>
        jsonRes({'hits': hits, 'offset': 0, 'limit': 20, 'total_hits': hits.length}),
    'GET api.modrinth.com/v2/projects': (r) {
      final ids = (jsonDecode(r.url.queryParameters['ids']!) as List).cast<String>();
      return jsonRes([for (final i in ids) ?projects[i]]);
    },
    'GET api.modrinth.com/v2/versions': (r) {
      final ids = (jsonDecode(r.url.queryParameters['ids']!) as List).cast<String>().toSet();
      return jsonRes([
        for (final v in _allVersions)
          if (ids.contains(v['id'])) v,
      ]);
    },
    'GET api.modrinth.com/v2/version/*': (r) {
      final id = r.url.pathSegments.last;
      final v = _allVersions.where((v) => v['id'] == id).firstOrNull;
      return v == null ? jsonRes({'error': 'not_found'}, status: 404) : jsonRes(v);
    },
    'GET api.modrinth.com/v2/project/*': (r) {
      final seg = r.url.pathSegments;
      final id = seg[2];
      final p = projects[id] ?? projects.values.where((p) => p['slug'] == id).firstOrNull;
      if (p == null) return jsonRes({'error': 'not_found'}, status: 404);
      if (seg.length > 3 && seg[3] == 'version') return jsonRes(versions[p['id']] ?? const []);
      return jsonRes(p);
    },
    'POST api.modrinth.com/v2/version_files': (r) {
      final hashes = ((jsonDecode(utf8.decode(r.body!)) as Map)['hashes'] as List).cast<String>();
      final out = <String, Object?>{};
      for (final v in _allVersions) {
        for (final f in (v['files']! as List).cast<Map<String, Object?>>()) {
          final h = (f['hashes']! as Map)['sha1'];
          if (hashes.contains(h)) out[h! as String] = v;
        }
      }
      return jsonRes(out);
    },
    'GET cdn.modrinth.com/*': (r) {
      final b = cdn[r.url.toString()];
      return b == null ? jsonRes({'error': 'not_found'}, status: 404) : HttpRes.bytes(200, b);
    },
  };
}

/// Strumenti del PC finti: ricordano cosa è stato chiesto.
final class FakeTools implements ClientTools {
  FakeTools({this.prismPath, this.launcher, this.downloadsDir = '/tmp/downloads'});

  String? prismPath;
  String? launcher;
  String downloadsDir;
  final opened = <String>[];
  final imported = <String>[];

  @override
  Future<String?> prism() async => prismPath;

  @override
  Future<void> openInPrism(String exe, String mrpack) async => imported.add(mrpack);

  @override
  String? officialLauncher() => launcher;

  @override
  String downloads() => downloadsDir;

  @override
  Future<void> openUrl(String url) async => opened.add(url);
}

/// Esecutore finto degli installer: non esegue niente.
final class FakeRunner implements ProcessRunner {
  final runs = <List<String>>[];

  @override
  Future<int> run(
    String executable,
    List<String> args, {
    required String workingDirectory,
    void Function(String line)? onLine,
  }) async {
    runs.add([executable, ...args]);
    return 0;
  }
}

/// L'ambiente del modpack dei test.
ModpackEnv fakeModpackEnv({FakeTransport? transport, FakeTools? tools}) => ModpackEnv(
  transport: transport ?? FakeTransport(),
  tools: tools ?? FakeTools(),
  runner: FakeRunner(),
  sleep: (_) async {},
);
