// Card «Pacchetto per i giocatori» della scheda Mod: download del .mrpack e
// delle sole mod dagli endpoint dell'hub, generazione, istruzioni per app,
// Prism e launcher ufficiale, mod CurseForge da scaricare a mano, lato di
// ogni mod, server vanilla, vista da membro e da admin, golden.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_hub_web/src/api/pack_file.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../support/harness.dart';
import '../support/server_fixtures.dart';
import '../support/server_helpers.dart';

const _tall = Size(1280, 1900);

const survivalPack = ClientPack(
  n: 41,
  available: true,
  name: 'Survival',
  mcVersion: '1.21.1',
  loader: Loader.fabric,
  loaderVersion: '0.16.14',
  mods: 4,
  required: 2,
  optional: 1,
  serverOnly: 1,
  manual: 1,
  fileName: 'Survival-41.mrpack',
  size: 31 << 10,
  modsZipName: 'Survival-41-mods.zip',
  modsZipSize: 148 << 20,
);

const _packFile = PackFile(
  mcVersion: '1.21.1',
  loader: 'fabric',
  loaderVersion: '0.16.14',
  mods: [
    PackEntry(path: 'mods/biomi-lontani-1.9.0.jar', name: 'Biomi Lontani', source: 'modrinth'),
    PackEntry(path: 'mods/forziere-plus-2.0.4.jar', name: 'Forziere Plus', source: 'modrinth'),
    PackEntry(path: 'mods/server-tweak-local.jar', side: 'server'),
    PackEntry(
      path: 'mods/turbo-render-0.6.0.jar',
      name: 'Turbo Render',
      side: 'client',
      optional: true,
      source: 'modrinth',
    ),
  ],
);

void _withPack(FakeHubApi api, {ClientPack pack = survivalPack}) {
  api.packs['survival'] = pack;
  api.packFiles['survival'] = _packFile;
}

void main() {
  setUpAll(loadFonts);

  testWidgets('membro: scarica .mrpack e solo le mod dagli endpoint dell\'hub', (t) async {
    final s = serverState(me: bob, setup: _withPack);
    await pumpHub(t, s, location: '/server/survival/mods', size: _tall);
    await settle(t);
    expect(msText('Pacchetto per i giocatori'), findsOneWidget);
    expect(msText('Aggiornato alla versione 41'), findsOneWidget);
    expect(msTextContaining('Fabric 0.16.14 per Minecraft 1.21.1 e le 3 mod'), findsOneWidget);
    await tapOn(t, msButton('Scarica Survival-41.mrpack'));
    await tapOn(t, msButton('Solo le mod (.zip, 148 MB)'));
    expect(fakePlatform(s).downloads.map((u) => u.path), [
      '/api/v1/spaces/survival/pack.mrpack',
      '/api/v1/spaces/survival/pack-mods.zip',
    ]);
    // la nota per gli admin non c'è
    expect(msTextContaining('Le mod si modificano dalla scheda Mod'), findsNothing);
  });

  testWidgets('lato di ogni mod dal minesync-pack.json', (t) async {
    await pumpHub(
      t,
      serverState(setup: _withPack),
      location: '/server/survival/mods',
      size: _tall,
    );
    await settle(t);
    MsChip chip(String label) =>
        t.widget<MsChip>(find.byWidgetPredicate((w) => w is MsChip && w.label == label).first);
    expect(chip('client e server').label, 'client e server');
    expect(chip('server').label, 'server');
    expect(chip('client (facoltativa per i giocatori)').label, isNotEmpty);
    expect(msTextContaining('Le mod si modificano dalla scheda Mod'), findsOneWidget);
  });

  testWidgets('mod CurseForge da scaricare a mano: link alla pagina', (t) async {
    final s = serverState(
      me: bob,
      setup: (api) => _withPack(
        api,
        pack: const ClientPack(
          n: 41,
          available: true,
          mcVersion: '1.21.1',
          loader: Loader.fabric,
          loaderVersion: '0.16.14',
          required: 2,
          fileName: 'Survival-41.mrpack',
          size: 31 << 10,
          missing: [
            PackMissingMod(
              file: 'torri-antiche.jar',
              source: 'curseforge',
              name: 'Torri Antiche',
              pageUrl: 'https://www.curseforge.com/minecraft/mc-mods/torri-antiche',
            ),
          ],
        ),
      ),
    );
    await pumpHub(t, s, location: '/server/survival/mods', size: _tall);
    await settle(t);
    expect(msText('1 mod non è nel file'), findsOneWidget);
    await tapOn(t, msButton('Pagina di Torri Antiche'));
    expect(fakePlatform(s).opened.single.host, 'www.curseforge.com');
  });

  testWidgets('server vanilla: niente da scaricare', (t) async {
    await pumpHub(t, serverState(me: bob), location: '/server/creativo/mods');
    await settle(t);
    expect(msText('Nessun pacchetto da scaricare'), findsOneWidget);
    expect(msButton('Scarica Survival-41.mrpack'), findsNothing);
  });

  testWidgets('golden: pacchetto, vista da membro', (t) async {
    await expectHubGolden(
      t,
      'server_pack_member',
      serverState(me: bob, setup: _withPack),
      location: '/server/survival/mods',
      size: _tall,
      prepare: settle,
    );
  });

  testWidgets('golden: pacchetto, vista da admin', (t) async {
    await expectHubGolden(
      t,
      'server_pack_admin',
      serverState(setup: _withPack),
      location: '/server/survival/mods',
      size: _tall,
      prepare: settle,
    );
  });

  testWidgets('golden: server vanilla', (t) async {
    await expectHubGolden(
      t,
      'server_pack_vanilla',
      serverState(me: bob),
      location: '/server/creativo/mods',
      size: const Size(1280, 900),
      prepare: settle,
    );
  });
}
