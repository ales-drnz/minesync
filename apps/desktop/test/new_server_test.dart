// Procedura «Nuovo server»: prima l'origine, poi il nome obbligatorio con
// versione e tipo di server e il controllo di Java (Temurin e «Cerca di
// nuovo» se manca), Avanti spento che dice cosa manca, passi fissi da
// Origine a EULA, mod consigliate, EULA con un clic, creazione con l'esito
// dei passi, errore senza niente a metà sull'hub, golden dei passi.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_desktop/src/state/app_state.dart';
import 'package:ms_minecraft/ms_minecraft.dart';
import 'package:ms_modpack/ms_modpack.dart';
import 'package:ms_protocol/ms_protocol.dart' show Profile;
import 'package:ms_ui/ms_ui.dart';

import 'home_test.dart' show homeSpaces;
import 'support/app_harness.dart';
import 'support/finders.dart';
import 'support/modpack_fakes.dart';
import 'support/space_fakes.dart';

const _java17 = [
  JavaRuntime(path: '/usr/lib/jvm/java-17/bin/java', major: 17, version: '17.0.12', bits: 64),
];

AppState nsState({
  NsStep step = NsStep.origin,
  String name = 'Avventura',
  List<JavaRuntime> javas = sampleJavas,
  Map<NsTask, NsTaskState>? tasks,
  NsTask? failed,
  Object? error,
  bool done = false,
}) => testState(
  setup: (s) {
    s.debugSet(spaces: homeSpaces(), route: const NewServerRoute());
    final c = s.newServer
      ..name = name
      ..mc = '1.21.1'
      ..loader = Loader.fabric
      ..loaderVersion = '0.16.14'
      ..chosenMods.addAll(['lithium', 'ferrite-core', 'chunky']);
    c.debugSet(
      step: step,
      mcVersions: const ['26.1', '1.21.11', '1.21.10', '1.21.4', '1.21.1'],
      loaderVersions: const [('0.16.14', true)],
      javas: javas,
      tasks: tasks,
      failed: failed,
      error: error,
      progress: tasks != null && failed == null && !done ? .58 : null,
      progressLabel: tasks != null && failed == null && !done ? 'Chunky' : null,
      created: done ? s.space('avventura') : null,
      firstGeneration: done ? 1 : null,
    );
    if (done) c.folder = '/tmp/MineSync/avventura';
  },
);

void main() {
  setUpAll(loadFonts);

  testWidgets('origine prima del nome: tre strade, poi il nome; senza non si va avanti', (t) async {
    final h = t.ensureSemantics();
    final s = nsState(name: '');
    await pumpApp(t, s);
    expect(msText('Scegli il punto di partenza'), findsOneWidget);
    expect(msText('Tutto si può cambiare in seguito.'), findsOneWidget);
    expect(msText('Da zero'), findsOneWidget);
    expect(msText('Da un modpack'), findsOneWidget);
    expect(msText('Da una cartella'), findsOneWidget);
    expect(find.byType(MsTextInput), findsNothing);
    expect(
      t.getSemantics(find.bySemanticsLabel('Passi')),
      matchesSemantics(label: 'Passi', value: 'passo 1 di 4, Origine'),
    );
    await t.tap(msButton('Avanti'));
    await t.pump();
    expect(s.newServer.step, NsStep.version);
    expect(find.byType(MsTextInput), findsOneWidget);
    expect(t.widget<MsButton>(msButton('Avanti')).onPressed, isNull);
    expect(msText('Scrivi un nome'), findsOneWidget);
    await t.enterText(find.byType(EditableText), 'Survival');
    await t.pump();
    expect(s.newServer.name, 'Survival');
    expect(msText('Scrivi un nome'), findsNothing);
    expect(t.widget<MsButton>(msButton('Avanti')).onPressed, isNotNull);
    h.dispose();
  });

  testWidgets('passi fissi da Origine a EULA; Vanilla salta le mod', (t) async {
    final c = nsState().newServer;
    expect(c.steps, [NsStep.origin, NsStep.version, NsStep.mods, NsStep.eula]);
    c.setOrigin(NsOrigin.modpack);
    expect(c.steps, [NsStep.origin, NsStep.modpack, NsStep.eula]);
    c.setOrigin(NsOrigin.folder);
    expect(c.steps, [NsStep.origin, NsStep.folder, NsStep.eula]);
    expect(c.skipped(NsStep.eula), isFalse);
    c.setProfile(Profile.generic);
    expect(c.skipped(NsStep.eula), isTrue);
    c
      ..setOrigin(NsOrigin.scratch)
      ..loader = Loader.vanilla
      ..go(NsStep.version)
      ..next();
    expect(c.step, NsStep.eula);
    c.back();
    expect(c.step, NsStep.version);
  });

  testWidgets('versione: Java mancante blocca Avanti, con Temurin e «Cerca di nuovo»', (t) async {
    final s = nsState(step: NsStep.version, javas: _java17);
    await pumpApp(t, s);
    expect(msText('Manca Java 21'), findsOneWidget);
    expect(t.widget<MsButton>(msButton('Avanti')).onPressed, isNull);
    expect(msText('Serve Java 21'), findsOneWidget);
    await t.tap(msButton('Come installare Java (Temurin)'));
    await t.pump();
    expect((s.modpackEnv.tools as FakeTools).opened.single, temurinUrl(21));
    expect(msButton('Cerca di nuovo'), findsOneWidget);
  });

  testWidgets('versione con Java: Avanti porta alle mod, poi all\'EULA', (t) async {
    final s = nsState(step: NsStep.version);
    await pumpApp(t, s);
    expect(msText('Java 21: presente'), findsOneWidget);
    await t.tap(msButton('Avanti'));
    await t.pump();
    expect(msText('Mod iniziali'), findsOneWidget);
    expect(msText('Fabric API sempre inclusa'), findsOneWidget);
    await t.tap(msButton('Avanti (3 mod)'));
    await t.pump();
    expect(msText('L\'EULA di Minecraft'), findsOneWidget);
    expect(msButton('Accetta e crea il server'), findsOneWidget);
    expect(msText('Fabric API, Lithium, FerriteCore, Chunky'), findsOneWidget);
  });

  testWidgets('errore: niente a metà sull\'hub, Riprova', (t) async {
    await pumpApp(
      t,
      nsState(
        step: NsStep.create,
        tasks: {
          NsTask.server: NsTaskState.done,
          NsTask.mods: NsTaskState.failed,
          NsTask.hub: NsTaskState.pending,
          NsTask.push: NsTaskState.pending,
        },
        failed: NsTask.mods,
        error: 'cdn.modrinth.com non risponde',
      ),
    );
    expect(msText('Creazione non riuscita'), findsOneWidget);
    expect(msText('Nessun dato parziale sull\'hub'), findsOneWidget);
    expect(msButton('Riprova'), findsOneWidget);
  });

  group('golden', () {
    testWidgets('origine', (t) async {
      await expectAppGolden(t, 'new_server_origin', nsState());
    });
    testWidgets('versione e loader', (t) async {
      await expectAppGolden(t, 'new_server_version', nsState(step: NsStep.version));
    });
    testWidgets('Java mancante', (t) async {
      await expectAppGolden(t, 'new_server_java', nsState(step: NsStep.version, javas: _java17));
    });
    testWidgets('mod consigliate', (t) async {
      await expectAppGolden(t, 'new_server_mods', nsState(step: NsStep.mods));
    });
    testWidgets('EULA', (t) async {
      await expectAppGolden(t, 'new_server_eula', nsState(step: NsStep.eula));
    });
    testWidgets('creazione', (t) async {
      await expectAppGolden(
        t,
        'new_server_create',
        nsState(
          step: NsStep.create,
          tasks: {
            NsTask.server: NsTaskState.done,
            NsTask.mods: NsTaskState.running,
            NsTask.hub: NsTaskState.pending,
            NsTask.push: NsTaskState.pending,
          },
        ),
      );
    });
    testWidgets('errore', (t) async {
      await expectAppGolden(
        t,
        'new_server_error',
        nsState(
          step: NsStep.create,
          tasks: {
            NsTask.server: NsTaskState.failed,
            NsTask.mods: NsTaskState.pending,
            NsTask.hub: NsTaskState.pending,
            NsTask.push: NsTaskState.pending,
          },
          failed: NsTask.server,
          error: 'meta.fabricmc.net non risponde',
        ),
      );
    });
    testWidgets('pronto', (t) async {
      await expectAppGolden(
        t,
        'new_server_done',
        nsState(
          step: NsStep.create,
          tasks: {for (final k in NsTask.values) k: NsTaskState.done},
          done: true,
        ),
      );
    });
  });
}
