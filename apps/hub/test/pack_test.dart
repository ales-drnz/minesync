// Pacchetto per i giocatori: /pack, /pack.mrpack e /pack-mods.zip
// costruiti dall'hub dalla HEAD, senza rete.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:ms_modpack/ms_modpack.dart';
import 'package:test/test.dart';

import 'support.dart';

List<int> jar(String name) => utf8.encode('jar bytes of $name');

PackMod mod(
  String path, {
  PackSide side = PackSide.both,
  bool optional = false,
  PackSource source = PackSource.modrinth,
  String? id,
  bool disabled = false,
}) {
  final b = jar(path);
  final pid = id ?? 'p${path.hashCode.toUnsigned(28).toRadixString(16).padLeft(7, '0')}';
  return PackMod(
    path: path,
    name: path.split('/').last,
    sha1: crypto.sha1.convert(b).toString(),
    sha512: crypto.sha512.convert(b).toString(),
    size: b.length,
    side: side,
    optional: optional,
    source: source,
    disabled: disabled,
    projectId: source == PackSource.modrinth ? pid : null,
    versionId: source == PackSource.modrinth ? 'v0000001' : null,
    downloads: source == PackSource.modrinth
        ? ['https://cdn.modrinth.com/data/$pid/versions/v0000001/${path.split('/').last}']
        : const [],
    curseforge: source == PackSource.curseforge
        ? const CurseForgeRef(pageUrl: 'https://www.curseforge.com/minecraft/mc-mods/towers')
        : null,
  );
}

void main() {
  late TestHub t;
  late String space;

  setUp(() async {
    t = await TestHub.start();
    space = await t.createSpace('Survival');
  });
  tearDown(() => t.close());

  final pack = Pack(
    mcVersion: '1.21.1',
    loader: Loader.fabric,
    loaderVersion: '0.16.14',
    shared: ['config/**'],
    mods: [
      mod('mods/create.jar'),
      mod('mods/sodium.jar', side: PackSide.client),
      mod('mods/iris.jar', side: PackSide.client, optional: true),
      mod('mods/chunky.jar', side: PackSide.server),
      mod('mods/minimap.jar', side: PackSide.client, disabled: true),
      mod('mods/tweaks.jar', source: PackSource.manual),
      mod('mods/towers.jar', source: PackSource.curseforge),
    ],
  );

  Map<String, List<int>> serverFiles() => {
    'minesync-pack.json': pack.encodeBytes(),
    'server.properties': bytes('motd=hi'),
    'config/create.toml': bytes('a=1'),
    'mods/create.jar': jar('mods/create.jar'),
    'mods/chunky.jar': jar('mods/chunky.jar'),
    'mods/tweaks.jar': jar('mods/tweaks.jar'),
    'mods/towers.jar': jar('mods/towers.jar'),
    'client-overrides/mods/sodium.jar': jar('mods/sodium.jar'),
    'client-overrides/mods/iris.jar': jar('mods/iris.jar'),
    'client-overrides/mods/minimap.jar.disabled': jar('mods/minimap.jar'),
    'client-overrides/options.txt': bytes('fov=90'),
  };

  test('spazio senza HEAD, senza pack, pack non valido: niente da scaricare', () async {
    var r = await t.get('/spaces/$space/pack');
    expect(r.status, 200);
    expect(r.obj, {'n': 0, 'available': false});
    expect((await t.get('/spaces/$space/pack.mrpack')).code, 'not_found');
    expect((await t.get('/spaces/nope/pack')).status, 404);

    await t.push(space, {'server.properties': bytes('motd=vanilla')});
    r = await t.get('/spaces/$space/pack');
    expect(r.obj, {'n': 1, 'available': false});

    await t.push(space, {'minesync-pack.json': bytes('{"format": 99}')});
    expect(ClientPack.fromJson((await t.get('/spaces/$space/pack')).json).available, isFalse);
  });

  test('riassunto: conti, mancanti, nomi e dimensioni esatte', () async {
    await t.push(space, serverFiles());
    final r = await t.get('/spaces/$space/pack');
    expect(r.status, 200);
    final s = ClientPack.fromJson(r.json);
    expect(s.available, isTrue);
    expect(s.n, 1);
    expect((s.mcVersion, s.loader, s.loaderVersion), ('1.21.1', Loader.fabric, '0.16.14'));
    expect(
      (s.mods, s.required, s.optional, s.serverOnly, s.manual, s.disabled),
      (7, 4, 1, 1, 1, 1),
    );
    expect(s.missing.single.file, 'towers.jar');
    expect(s.missing.single.pageUrl, contains('curseforge.com'));
    expect(s.fileName, 'Survival-1.mrpack');
    expect(s.modsZipName, 'Survival-1-mods.zip');

    final mr = await t.get('/spaces/$space/pack.mrpack');
    expect(mr.status, 200);
    expect(mr.headers.contentType!.mimeType, 'application/x-modrinth-modpack+zip');
    expect(mr.headers.value('content-disposition'), 'attachment; filename="Survival-1.mrpack"');
    expect(mr.bytes.length, s.size);
    final mz = await t.get('/spaces/$space/pack-mods.zip');
    expect(mz.bytes.length, s.modsZipSize);
  });

  test('.mrpack: indice per URL, override dai blob, si reimporta', () async {
    await t.push(space, serverFiles());
    final mr = await t.get('/spaces/$space/pack.mrpack');
    final imp = readMrpack(mr.bytes);
    expect(imp.index.versionId, '1');
    expect(imp.index.name, 'Survival');
    expect(imp.index.dependencies, {'minecraft': '1.21.1', 'fabric-loader': '0.16.14'});
    expect([
      for (final f in imp.index.files) f.path,
    ], unorderedEquals(['mods/create.jar', 'mods/sodium.jar', 'mods/iris.jar']));
    expect(
      imp.index.files.firstWhere((f) => f.path == 'mods/iris.jar').env!.client,
      MrEnv.optional,
    );
    final files = {for (final f in imp.files) f.path: utf8.decode(f.bytes)};
    expect(files['config/create.toml'], 'a=1');
    expect(files['mods/tweaks.jar'], 'jar bytes of mods/tweaks.jar');
    expect(files['client-overrides/options.txt'], 'fov=90');
    expect(files.containsKey('server.properties'), isFalse);
    expect(
      files.keys.any((k) => k.contains('towers') || k.contains('chunky') || k.contains('minimap')),
      isFalse,
    );
    // lo stesso ETag dà 304
    final etag = mr.headers.value('etag')!;
    final again = await t.req(
      'GET',
      '/spaces/$space/pack.mrpack',
      headers: {'If-None-Match': etag},
    );
    expect(again.status, HttpStatus.notModified);
  });

  test('pack-mods.zip: solo le mod per i giocatori presenti, mai CurseForge vietate', () async {
    await t.push(space, serverFiles());
    final r = await t.get('/spaces/$space/pack-mods.zip');
    expect(r.status, 200);
    final z = ZipDecoder().decodeBytes(r.bytes);
    expect(
      [for (final f in z.files) f.name],
      ['mods/create.jar', 'mods/iris.jar', 'mods/sodium.jar', 'mods/tweaks.jar'],
    );
    expect(utf8.decode(z.findFile('mods/sodium.jar')!.content), 'jar bytes of mods/sodium.jar');
  });

  test('una generazione nuova cambia il pacchetto; la vecchia resta nella storia', () async {
    await t.push(space, serverFiles());
    final first = ClientPack.fromJson((await t.get('/spaces/$space/pack')).json);
    final smaller = pack.withoutKeys([pack.byPath('mods/create.jar')!.key]);
    await t.push(space, {...serverFiles(), 'minesync-pack.json': smaller.encodeBytes()});
    final second = ClientPack.fromJson((await t.get('/spaces/$space/pack')).json);
    expect(second.n, 2);
    expect(second.mods, first.mods - 1);
    expect(second.fileName, 'Survival-2.mrpack');
  });

  test('blob mancante: 409 blobs_missing invece di un file troncato', () async {
    await t.push(space, serverFiles());
    final h = crypto.sha256.convert(jar('mods/tweaks.jar')).toString();
    await File(t.hub.store.blobs.pathOf(h)).delete();
    final r = await t.get('/spaces/$space/pack.mrpack');
    expect(r.status, 409);
    expect(r.code, 'blobs_missing');
  });
}
