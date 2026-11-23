// Client Modrinth con un trasporto finto: richieste, decodifica, limiti di
// frequenza, ritentativi e cache. Nessuna rete vera.
import 'dart:convert';

import 'package:ms_modpack/ms_modpack.dart';
import 'package:test/test.dart';

import 'support.dart';

const ua = 'minesync/0.1.0 (+https://example.invalid/minesync)';

void main() {
  late FakeTransport t;
  late List<Duration> slept;
  var now = 1000000;

  ModrinthClient client({ResponseCache? cache}) => ModrinthClient(
    transport: t,
    userAgent: ua,
    cache: cache,
    sleep: (d) async {
      slept.add(d);
      now += d.inMilliseconds;
    },
    nowMs: () => now,
  );

  setUp(() {
    t = FakeTransport();
    slept = [];
    now = 1000000;
  });

  test('User-Agent descrittivo', () {
    expect(modrinthUserAgent('0.1.0'), startsWith('minesync/0.1.0 (+https://github.com/'));
    expect(() => ModrinthClient(transport: t, userAgent: ' '), throwsArgumentError);
  });

  test('ricerca: facet per tipo, versione, loader (Quilt anche Fabric) e lato', () async {
    t.routes['GET api.modrinth.com/v2/search'] = (_) => json({
      'hits': [
        {
          'project_id': 'waystone',
          'project_type': 'mod',
          'slug': 'waystones',
          'author': 'someone',
          'title': 'Waystones',
          'description': 'Teleport stones',
          'categories': ['fabric', 'transportation'],
          'versions': ['1.21.1'],
          'downloads': 41000000,
          'icon_url': 'https://cdn.modrinth.com/data/waystone/icon.png',
          'client_side': 'required',
          'server_side': 'required',
          'latest_version': 'v21',
          'license': 'ARR',
        },
      ],
      'offset': 0,
      'limit': 20,
      'total_hits': 1,
    });
    final r = await client().search(
      query: 'waystones',
      gameVersion: '1.21.1',
      loader: Loader.quilt,
      side: PackSide.server,
      index: MrSearchIndex.downloads,
    );
    expect(r.total, 1);
    expect(r.hits.single.title, 'Waystones');
    expect(r.hits.single.side, (PackSide.both, false));
    expect(r.hits.single.pageUrl, 'https://modrinth.com/mod/waystones');
    final q = t.requests.single.url.queryParameters;
    expect(t.requests.single.headers['User-Agent'], ua);
    expect(q['query'], 'waystones');
    expect(q['index'], 'downloads');
    expect(jsonDecode(q['facets']!), [
      ['project_type:mod'],
      ['versions:1.21.1'],
      ['categories:quilt', 'categories:fabric'],
      ['server_side:required', 'server_side:optional'],
    ]);
    expect(() => client().search(limit: 0), throwsArgumentError);
  });

  test('ricerca dei modpack: pagine con offset e limit, ordinamento, loader esatto', () async {
    Map<String, Object?> hit(int i) => {
      'project_id': 'pack${i.toString().padLeft(4, '0')}',
      'project_type': 'modpack',
      'slug': 'pack-$i',
      'author': 'carol',
      'title': 'Pack $i',
      'description': 'A pack',
      'categories': ['quilt', 'adventure'],
      'versions': ['1.20.1', '1.21.1'],
      'downloads': 1000 - i,
      'icon_url': null,
      'client_side': 'required',
      'server_side': 'unsupported',
      'date_modified': '2026-10-01T12:00:00Z',
    };
    t.routes['GET api.modrinth.com/v2/search'] = (r) {
      final off = int.parse(r.url.queryParameters['offset']!);
      final lim = int.parse(r.url.queryParameters['limit']!);
      return json({
        'hits': [for (var i = off; i < off + lim && i < 45; i++) hit(i)],
        'offset': off,
        'limit': lim,
        'total_hits': 45,
      });
    };
    final c = client();
    final p1 = await c.search(
      projectType: 'modpack',
      loader: Loader.quilt,
      gameVersion: '1.21.1',
      index: MrSearchIndex.updated,
      limit: 20,
    );
    final p3 = await c.search(projectType: 'modpack', offset: 40, limit: 20);
    expect((p1.hits.length, p1.total, p1.offset), (20, 45, 0));
    expect((p3.hits.length, p3.offset), (5, 40));
    expect(p3.hits.first.title, 'Pack 40');
    expect(p1.hits.first.serverSide, MrEnv.unsupported);
    expect(p1.hits.first.dateModified, DateTime.utc(2026, 10, 1, 12).millisecondsSinceEpoch);
    final q1 = t.requests[0].url.queryParameters, q3 = t.requests[1].url.queryParameters;
    expect(q1.containsKey('query'), isFalse);
    expect((q1['index'], q1['offset'], q1['limit']), ('updated', '0', '20'));
    expect((q3['index'], q3['offset']), ('relevance', '40'));
    // un modpack Quilt è solo Quilt (non anche Fabric come per le mod)
    expect(jsonDecode(q1['facets']!), [
      ['project_type:modpack'],
      ['versions:1.21.1'],
      ['categories:quilt'],
    ]);
  });

  test('progetto con descrizione lunga e link', () async {
    t.routes['GET api.modrinth.com/v2/project/cobblePk'] = (_) => json({
      ...projectJson('cobblePk', title: 'Cobble Pack', server: 'unsupported', type: 'modpack'),
      'body': '# Hello\nA **pack**',
      'issues_url': 'https://example.org/issues',
      'discord_url': 'ftp://example.org/x',
      'updated': '2026-09-01T00:00:00Z',
    });
    final p = await client().project('cobblePk');
    expect(p.body, startsWith('# Hello'));
    expect(p.issuesUrl, 'https://example.org/issues');
    expect(p.discordUrl, isNull);
    expect(p.updated, DateTime.utc(2026, 9).millisecondsSinceEpoch);
    expect(p.pageUrl, 'https://modrinth.com/modpack/cobblepk');
  });

  test('progetto, versioni filtrate, versioni per id', () async {
    t.routes['GET api.modrinth.com/v2/project/sodiumPr'] = (_) =>
        json(projectJson('sodiumPr', title: 'Sodium', server: 'unsupported'));
    t.routes['GET api.modrinth.com/v2/project/sodiumPr/version'] = (_) =>
        json([versionJson(id: 'sodiumV1', project: 'sodiumPr', number: '0.6.13')]);
    t.routes['GET api.modrinth.com/v2/versions'] = (_) =>
        json([versionJson(id: 'sodiumV1', project: 'sodiumPr', number: '0.6.13')]);
    final c = client();
    final p = await c.project('sodiumPr');
    expect(p.title, 'Sodium');
    expect(p.side, (PackSide.client, false));
    expect(p.license, 'MIT');
    final vs = await c.versions('sodiumPr', gameVersions: ['1.21.1'], loaders: ['fabric']);
    expect(vs.single.primaryFile!.filename, 'sodiumPr-0.6.13.jar');
    expect(vs.single.datePublished, DateTime.utc(2026).millisecondsSinceEpoch);
    final q = t.requests[1].url.queryParameters;
    expect(jsonDecode(q['game_versions']!), ['1.21.1']);
    expect(jsonDecode(q['loaders']!), ['fabric']);
    final byIds = await c.versionsByIds(['sodiumV1', 'sodiumV1']);
    expect(byIds.single.id, 'sodiumV1');
    expect(jsonDecode(t.requests.last.url.queryParameters['ids']!), ['sodiumV1']);
    expect(await c.versionsByIds(const []), isEmpty);
  });

  test('riconoscimento per hash e aggiornamenti (POST)', () async {
    final ver = versionJson(id: 'jadeV2', project: 'jadePr', number: '15.10.2');
    final h = ((ver['files']! as List).single as Map)['hashes'] as Map;
    t.routes['POST api.modrinth.com/v2/version_files'] = (_) => json({h['sha1']: ver});
    t.routes['POST api.modrinth.com/v2/version_files/update'] = (_) => json({h['sha1']: ver});
    final c = client();
    final m = await c.versionFiles([h['sha1']! as String, 'f' * 40]);
    expect(m[h['sha1']]!.versionNumber, '15.10.2');
    expect(jsonDecode(utf8.decode(t.requests.last.body!)), {
      'hashes': [h['sha1'], 'f' * 40]..sort(),
      'algorithm': 'sha1',
    });
    final u = await c.updates(
      [h['sha1']! as String],
      loaders: ['fabric'],
      gameVersions: ['1.21.1'],
    );
    expect(u.values.single.id, 'jadeV2');
    expect(jsonDecode(utf8.decode(t.requests.last.body!))['game_versions'], ['1.21.1']);
    expect(await c.versionFiles(const []), isEmpty);
  });

  test('429: aspetta Retry-After e riprova', () async {
    var n = 0;
    t.routes['GET api.modrinth.com/v2/project/a'] = (_) => ++n == 1
        ? json({'error': 'ratelimited'}, status: 429, headers: {'Retry-After': '7'})
        : json(projectJson('a'));
    expect((await client().project('a')).id, 'a');
    expect(slept, [const Duration(seconds: 7)]);
    expect(n, 2);
  });

  test('limite esaurito: la richiesta dopo aspetta l\'azzeramento', () async {
    t.routes['GET api.modrinth.com/v2/project/*'] = (_) => json(
      projectJson('a'),
      headers: {
        'X-Ratelimit-Limit': '300',
        'X-Ratelimit-Remaining': '0',
        'X-Ratelimit-Reset': '12',
      },
    );
    final c = client();
    await c.project('a');
    expect(c.rateLimit!.remaining, 0);
    expect(slept, isEmpty);
    await c.project('b');
    expect(slept, [const Duration(seconds: 12)]);
  });

  test('5xx ripetuti e rete assente: Modrinth non risponde', () async {
    t.routes['GET api.modrinth.com/v2/project/a'] = (_) => json({}, status: 503);
    await expectLater(client().project('a'), throwsA(isA<ModrinthUnavailable>()));
    expect(slept.length, 3);
    final down = ModrinthClient(transport: _Down(), userAgent: ua, sleep: (_) async {});
    await expectLater(down.project('a'), throwsA(isA<ModrinthUnavailable>()));
  });

  test('404 e corpo non valido sono ModrinthException', () async {
    await expectLater(
      client().project('missing'),
      throwsA(isA<ModrinthException>().having((e) => e.notFound, 'notFound', isTrue)),
    );
    t.routes['GET api.modrinth.com/v2/project/bad'] = (_) =>
        HttpRes.bytes(200, utf8.encode('<html>'));
    await expectLater(client().project('bad'), throwsA(isA<ModrinthException>()));
    t.routes['GET api.modrinth.com/v2/project/shape'] = (_) => json({'id': 'shape', 'slug': 's'});
    // un progetto senza titolo si decodifica (campi descrittivi tolleranti)
    expect((await client().project('shape')).title, '');
    t.routes['GET api.modrinth.com/v2/version/x'] = (_) => json({
      'id': 'x',
      'project_id': 'p',
      'files': [
        {
          'url': 'ftp://x',
          'filename': 'a.jar',
          'hashes': {'sha1': 'a', 'sha512': 'b'},
        },
      ],
    });
    await expectLater(client().version('x'), throwsA(isA<ModrinthException>()));
  });

  test('cache: la seconda richiesta uguale non va in rete finché è valida', () async {
    t.routes['GET api.modrinth.com/v2/project/a'] = (_) => json(projectJson('a'));
    final cache = MemoryCache();
    final c = client(cache: cache);
    await c.project('a');
    await c.project('a');
    expect(t.requests.length, 1);
    now += const Duration(minutes: 11).inMilliseconds;
    await c.project('a');
    expect(t.requests.length, 2);
  });

  test('lati da client_side/server_side', () {
    expect(sideFromEnv(MrEnv.required, MrEnv.unsupported), (PackSide.client, false));
    expect(sideFromEnv(MrEnv.optional, MrEnv.unsupported), (PackSide.client, true));
    expect(sideFromEnv(MrEnv.unsupported, MrEnv.required), (PackSide.server, false));
    expect(sideFromEnv(MrEnv.optional, MrEnv.required), (PackSide.both, true));
    expect(sideFromEnv(MrEnv.required, MrEnv.optional), (PackSide.both, false));
    expect(sideFromEnv(MrEnv.unknown, MrEnv.unknown), (PackSide.both, false));
    expect(sideFromEnv(MrEnv.required, MrEnv.unknown), (PackSide.both, false));
  });
}

final class _Down implements HttpTransport {
  @override
  Future<HttpRes> send(HttpReq req) async => throw HttpUnavailable(req.url, 'refused');
}
