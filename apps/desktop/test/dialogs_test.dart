// Dialoghi critici: scelte del conflitto (con la seconda conferma),
// forzatura in due passi, chiusura durante una sessione, aggiornamento mai
// durante il gioco, EULA e conflitto aperti dalla schermata della sessione,
// golden di ogni dialogo.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_desktop/src/dialogs/app_dialogs.dart';
import 'package:minesync_desktop/src/screens/dialogs.dart' show GcDialog, gcKeepDefault;
import 'package:minesync_desktop/src/state/app_state.dart';
import 'package:ms_core/ms_core.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import 'support/app_harness.dart';
import 'support/finders.dart';
import 'support/session_fixtures.dart';

const _facts = ConflictFacts(
  server: 'Survival',
  folder: '/home/alice/MineSync/survival',
  changed: 12,
  removed: 3,
  base: 127,
  head: 131,
  lastAuthor: 'bob, 21:40',
);

const _conflict = SyncException(
  SyncErrorKind.dirtyLocal,
  diverged: true,
  changed: ['world/level.dat'],
  base: 127,
  head: 131,
);

final _lock = LockHolder(
  memberId: 'b2',
  name: 'bob',
  since: at(17, 30).millisecondsSinceEpoch,
  lastBeat: at(18, 40).millisecondsSinceEpoch,
  stale: false,
  info: const LockInfo(action: 'play', players: ['bob', 'carol', 'dave']),
);

BuildContext _ctx(WidgetTester t) => t.element(find.byType(MsSidebar));

AppState _app({SessionController? session, SessionRoute? route}) => testState(
  setup: (a) {
    a.debugSetSession(session);
    if (route != null) a.debugSet(route: route);
  },
);

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

/// Golden con un dialogo aperto da [open].
Future<void> _golden(
  WidgetTester t,
  String name,
  void Function(BuildContext) open, {
  AppState? state,
  Future<void> Function(WidgetTester)? then,
}) async {
  var opened = false;
  await expectAppGolden(
    t,
    'dialog_$name',
    state ?? _app(),
    prepare: (t) async {
      if (!opened) {
        opened = true;
        open(_ctx(t));
        await _settle(t);
        await then?.call(t);
      }
      await _settle(t);
    },
  );
}

void main() {
  setUpAll(loadFonts);

  group('conflitto', () {
    testWidgets('versione dell\'hub è la scelta a fuoco; Esc annulla', (t) async {
      await pumpApp(t, _app());
      var r = showConflictDialog(_ctx(t), _facts);
      await _settle(t);
      await t.tap(find.bySemanticsLabel('Usa la versione dell\'hub').first);
      await _settle(t);
      expect(await r, ConflictChoice.useHub);

      r = showConflictDialog(_ctx(t), _facts);
      await _settle(t);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(t);
      expect(await r, ConflictChoice.cancel);
    });

    testWidgets('le mie: seconda conferma, "torna indietro" riporta alla prima', (t) async {
      await pumpApp(t, _app());
      final r = showConflictDialog(_ctx(t), _facts);
      var done = false;
      unawaited(r.then((_) => done = true));
      await _settle(t);
      await t.tap(find.bySemanticsLabel('Carica le modifiche locali come nuova versione…').first);
      await _settle(t);
      expect(find.text('Sostituire la versione dell\'hub per tutti?'), findsOneWidget);
      await t.tap(find.bySemanticsLabel('Torna indietro').first);
      await _settle(t);
      expect(done, isFalse);
      expect(find.text('Modifiche non salvate su questo PC'), findsOneWidget);
      await t.tap(find.bySemanticsLabel('Carica le modifiche locali come nuova versione…').first);
      await _settle(t);
      await t.tap(find.bySemanticsLabel('Carica le modifiche locali').first);
      await _settle(t);
      expect(await r, ConflictChoice.keepMine);
    });

    testWidgets('aperto dalla sessione; Annulla annulla la sessione', (t) async {
      final s = sampleSession(
        phase: SessionPhase.conflict,
        setup: (s) => s.debugSet(conflict: _conflict),
      );
      await pumpApp(t, _app(session: s, route: const SessionRoute('survival')));
      await _settle(t);
      expect(find.byType(ConflictDialog), findsOneWidget);
      await t.tap(find.bySemanticsLabel('Annulla').last);
      await _settle(t);
      expect(s.phase, SessionPhase.cancelled);
    });

    testWidgets('golden', (t) async {
      await _golden(t, 'conflict', (c) => showConflictDialog(c, _facts));
    });

    testWidgets('golden, seconda conferma', (t) async {
      await _golden(
        t,
        'conflict_confirm',
        (c) => showConflictDialog(c, _facts),
        then: (t) =>
            t.tap(find.bySemanticsLabel('Carica le modifiche locali come nuova versione…').first),
      );
    });
  });

  group('forza e gioca', () {
    testWidgets('due conferme a pulsante, senza scrivere il nome', (t) async {
      await pumpApp(t, _app());
      var r = showForceDialog(_ctx(t), server: 'Survival', lock: _lock, now: sampleNow);
      await _settle(t);
      await t.tap(find.bySemanticsLabel('Continua…').first);
      await _settle(t);
      expect(find.text('Conferma definitiva'), findsOneWidget);
      expect(find.byType(EditableText), findsNothing);
      await t.tap(find.bySemanticsLabel('Forza e gioca').first);
      await _settle(t);
      expect(await r, isTrue);

      r = showForceDialog(_ctx(t), server: 'Survival', lock: _lock, now: sampleNow);
      await _settle(t);
      await t.tap(find.bySemanticsLabel('Annulla').first);
      await _settle(t);
      expect(await r, isFalse);
    });

    testWidgets('golden, primo e secondo passo', (t) async {
      final head = sampleGen(131);
      await _golden(
        t,
        'force',
        (c) => showForceDialog(c, server: 'Survival', lock: _lock, head: head, now: sampleNow),
      );
      await _golden(
        t,
        'force_confirm',
        (c) => showForceDialog(c, server: 'Survival', lock: _lock, head: head, now: sampleNow),
        then: (t) => t.tap(find.bySemanticsLabel('Continua…').first),
      );
    });
  });

  group('chiusura durante una sessione', () {
    testWidgets('senza sessione si chiude subito', (t) async {
      await pumpApp(t, _app());
      expect(await confirmQuit(_ctx(t)), isTrue);
    });

    testWidgets('con una sessione: arresto pulito, poi chiude (tempo massimo)', (t) async {
      final s = sampleSession();
      await pumpApp(t, _app(session: s));
      final r = confirmQuit(_ctx(t), max: const Duration(seconds: 2));
      await _settle(t);
      expect(find.byType(QuitDialog), findsOneWidget);
      expect(s.console.last.note, ConsoleNote.stopping);
      await t.pump(const Duration(seconds: 3));
      await _settle(t);
      expect(await r, isTrue);
    });

    testWidgets('continua in background: la finestra si nasconde, l\'app resta', (t) async {
      final s = sampleSession();
      await pumpApp(t, _app(session: s));
      final r = confirmQuit(_ctx(t), max: const Duration(seconds: 2));
      await _settle(t);
      await t.tap(find.bySemanticsLabel('Continua in background').first);
      await _settle(t);
      expect(await r, isFalse);
      await t.pump(const Duration(seconds: 3));
    });

    testWidgets('golden', (t) async {
      final s = sampleSession(
        phase: SessionPhase.finalPush,
        setup: (s) => s.debugSet(
          upload: const UploadInfo(done: 17 << 20, total: 38 << 20, bytesPerSecond: 2 << 20),
        ),
      );
      await _golden(
        t,
        'quit',
        (c) => showMsDialog<void>(
          context: c,
          builder: (_) =>
              QuitDialog(session: s, autoStop: false, onDone: () {}, onBackground: () {}),
        ),
      );
    });
  });

  group('aggiornamento pronto', () {
    testWidgets('mai durante una sessione', (t) async {
      final s = sampleSession();
      await pumpApp(t, _app(session: s));
      expect(await showUpdateReady(_ctx(t), version: '0.1.1'), isFalse);
      await t.pump();
      expect(find.byType(UpdateReadyDialog), findsNothing);
    });

    testWidgets('riavvia ora / non ora', (t) async {
      await pumpApp(t, _app());
      var r = showUpdateReady(_ctx(t), version: '0.1.1');
      await _settle(t);
      await t.tap(find.bySemanticsLabel('Riavvia ora').first);
      await _settle(t);
      expect(await r, isTrue);
      r = showUpdateReady(_ctx(t), version: '0.1.1');
      await _settle(t);
      await t.tap(find.bySemanticsLabel('Non ora').first);
      await _settle(t);
      expect(await r, isFalse);
    });

    testWidgets('golden', (t) async {
      await _golden(
        t,
        'update',
        (c) => showUpdateReady(
          c,
          version: '0.1.1',
          notes: const ['Console più veloce con molte righe', 'Test della porta più affidabile'],
        ),
      );
    });
  });

  group('EULA', () {
    testWidgets('chiesta dalla sessione: Accetto risponde sì', (t) async {
      final s = sampleSession(
        phase: SessionPhase.starting,
        setup: (s) => s.debugSet(prompt: SessionPrompt.eula),
      );
      await pumpApp(t, _app(session: s, route: const SessionRoute('survival')));
      await _settle(t);
      expect(find.byType(EulaDialog), findsOneWidget);
      await t.tap(find.bySemanticsLabel('Accetto e avvio').first);
      await _settle(t);
      expect(s.prompt, isNull);
      expect(find.byType(EulaDialog), findsNothing);
    });

    testWidgets('golden', (t) async {
      await _golden(t, 'eula', (c) => showEulaDialog(c, server: 'Survival'));
    });
  });

  testWidgets('Java mancante: golden', (t) async {
    await _golden(
      t,
      'java_missing',
      (c) => showStartError(c, server: 'Survival', error: const JavaMissing(21)),
    );
  });

  testWidgets('crash con riavvio: golden', (t) async {
    final crash = CrashInfo(
      at: at(18, 51, 2),
      exitCode: 1,
      restarting: true,
      attempt: 1,
      maxAttempts: 2,
      lastErrors: const [
        'Exception in server tick loop',
        'java.lang.OutOfMemoryError: Java heap space',
      ],
      savedN: 132,
    );
    await _golden(t, 'crash', (c) => showCrashDialog(c, server: 'Survival', crash: crash));
  });

  testWidgets('sessione terminata: golden', (t) async {
    final s = sampleSession(phase: SessionPhase.ended);
    await _golden(t, 'ended', (c) => showSessionEnded(c, s), state: _app(session: s));
  });

  group('pulizia dell\'hub (admin)', () {
    GcPreview preview(int keep) => GcPreview(
      keep: keep,
      now: 400,
      // con 50 non c'è niente da togliere
      after: keep == 50 ? 400 : keep * 3,
      bytes: keep == 50 ? 0 : 18 << 30,
      spaces: [
        GcPreviewRow(id: 'survival', name: 'Survival', now: 132, after: keep, bytes: 12 << 30),
        GcPreviewRow(id: 'creativo', name: 'Creativo', now: 57, after: keep, bytes: 4 << 30),
        GcPreviewRow(
          id: 'avventura',
          name: 'Avventura',
          now: 211,
          after: keep,
          bytes: 2 << 30,
          ownRules: true,
        ),
      ],
    );

    /// Monta l'app e apre il dialogo; restituisce il suo esito futuro.
    Future<({Future<GcReport?> result})> open(
      WidgetTester t, {
      List<int>? asked,
      Future<GcReport> Function(int keep)? run,
    }) async {
      await pumpApp(t, _app());
      final r = showMsDialog<GcReport>(
        context: _ctx(t),
        builder: (_) => GcDialog(
          preview: (k) async {
            asked?.add(k);
            return preview(k);
          },
          run: run ?? (k) async => GcReport(generations: 400 - k * 3, blobs: 900, bytes: 18 << 30),
        ),
      );
      await _settle(t);
      return (result: r);
    }

    testWidgets('anteprima con le ultime 20, cambio a 5, pulizia', (t) async {
      final asked = <int>[];
      final r = (await open(t, asked: asked)).result;
      await _settle(t);
      expect(asked, [gcKeepDefault]);
      expect(find.textContaining('da 400 a 60'), findsOneWidget);
      expect(find.textContaining('18 GB'), findsWidgets);
      expect(msText('regole proprie'), findsOneWidget);
      await t.tap(find.bySemanticsLabel('ultime 5').first);
      await _settle(t);
      expect(asked, [20, 5]);
      expect(find.textContaining('da 400 a 15'), findsOneWidget);
      await t.tap(find.bySemanticsLabel('Pulisci ora').first);
      await _settle(t);
      final rep = await r;
      expect(rep!.generations, 385);
      expect(find.byType(GcDialog), findsNothing);
    });

    testWidgets('niente da togliere: Pulisci ora spento', (t) async {
      await open(t);
      await _settle(t);
      await t.tap(find.bySemanticsLabel('ultime 50').first);
      await _settle(t);
      expect(find.text('Nessuna versione da eliminare con questa scelta.'), findsOneWidget);
      final run = t.widget<MsButton>(
        find.byWidgetPredicate((w) => w is MsButton && w.label == 'Pulisci ora'),
      );
      expect(run.onPressed, isNull);
    });

    testWidgets('errore della pulizia: il dialogo resta aperto e lo dice', (t) async {
      await open(t, run: (_) async => throw const ApiError(ErrorCode.forbidden, 'no'));
      await _settle(t);
      await t.tap(find.bySemanticsLabel('Pulisci ora').first);
      await _settle(t);
      expect(find.byType(GcDialog), findsOneWidget);
      expect(find.text('Pulizia non riuscita'), findsOneWidget);
    });

    testWidgets('golden', (t) async {
      await _golden(
        t,
        'gc',
        (c) => showMsDialog<GcReport>(
          context: c,
          builder: (_) => GcDialog(
            preview: (k) async => preview(k),
            run: (k) async => const GcReport(generations: 0, blobs: 0, bytes: 0),
          ),
        ),
      );
    });
  });
}
