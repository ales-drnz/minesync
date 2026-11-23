// Schermata della sessione: stati principali (golden), console con filtri,
// ricerca e cronologia dei comandi, avvisi gravi, nessuna sessione.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_desktop/src/l10n/l10n.dart';
import 'package:minesync_desktop/src/screens/screens.dart';
import 'package:minesync_desktop/src/state/app_state.dart';
import 'package:ms_core/ms_core.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import 'support/app_harness.dart';
import 'support/finders.dart';
import 'support/session_fixtures.dart';

AppState _state(SessionController? s, {Map<String, Object?> prefs = const {}, PortCheck? port}) =>
    testState(
      prefs: prefs,
      setup: (a) {
        a.debugSetSession(s);
        a.debugSet(route: const SessionRoute('survival'));
        if (port != null) a.debugSet(spaces: _hosted(port));
      },
    );

/// Survival ospitato da questo PC (alice), con il nome DNS dell'hub, l'IP
/// visto dall'hub e la prova della porta.
List<SpaceSummary> _hosted(PortCheck port) {
  final spaces = sampleSpaces();
  final sp = spaces.first;
  spaces[0] = SpaceSummary(
    id: sp.id,
    name: sp.name,
    profile: sp.profile,
    createdAt: sp.createdAt,
    head: sp.head,
    dnsName: 'zerotier.survival.internal',
    lock: LockHolder(
      memberId: sampleMe.id,
      name: sampleMe.name,
      since: at(17, 30).millisecondsSinceEpoch,
      lastBeat: at(18, 3).millisecondsSinceEpoch,
      stale: false,
      ip: '192.0.2.10',
      portCheck: port,
      info: const LockInfo(action: 'play', players: ['alice', 'bob', 'carol'], port: 25565),
    ),
  );
  return spaces;
}

final _reachable = PortCheck(
  state: PortState.reachable,
  port: 25565,
  checkedAt: at(18, 3).millisecondsSinceEpoch,
);

Finder _pill(String label) =>
    find.byWidgetPredicate((w) => w is MsPill && w.label == label, description: 'pill "$label"');

void main() {
  setUpAll(loadFonts);

  testWidgets('in gioco: golden', (t) async {
    await expectAppGolden(
      t,
      'session_running',
      _state(sampleSession(), port: _reachable),
      size: const Size(1280, 1500),
    );
  });

  testWidgets('caricamento sull\'hub: golden chiaro', (t) async {
    final s = sampleSession(
      setup: (s) => s.debugSet(
        upload: const UploadInfo(done: 17 << 20, total: 38 << 20, bytesPerSecond: 2400 << 10),
        lagMs: 2300,
      ),
    );
    await expectAppGolden(
      t,
      'session_uploading_light',
      _state(s, prefs: const {'theme': 'light'}),
      size: const Size(1280, 1500),
      dprs: const [1.0],
    );
  });

  testWidgets('lock perso: server fermato, golden', (t) async {
    final s = sampleSession(
      phase: SessionPhase.ended,
      setup: (s) => s.debugSet(alerts: {'lockLost'}, alertAt: at(18, 44)),
    );
    await expectAppGolden(t, 'session_lock_lost', _state(s), size: const Size(1280, 1500));
  });

  testWidgets('arresto in corso e hub irraggiungibile: golden', (t) async {
    final s = sampleSession(
      phase: SessionPhase.stopping,
      setup: (s) => s.debugSet(hubUnreachable: true, alerts: {'hubDiskFull'}),
    );
    await expectAppGolden(t, 'session_stopping', _state(s), size: const Size(1280, 1500));
  });

  testWidgets('nessuna sessione su questo server', (t) async {
    // senza sessione torna la panoramica del server
    await pumpApp(t, _state(null));
    expect(find.byType(ServerScreen), findsOneWidget);
  });

  testWidgets('console: filtri per livello e ricerca', (t) async {
    final s = sampleSession();
    await pumpApp(t, _state(s), size: const Size(1280, 1500));
    expect(find.text('bob joined the game'), findsOneWidget);
    await t.tap(find.bySemanticsLabel('Errori 1').first);
    await t.pump();
    expect(find.text('bob joined the game'), findsNothing);
    expect(find.textContaining('Failed to load contraption'), findsOneWidget);
    await t.tap(find.bySemanticsLabel('Tutto').first);
    await t.pump();
    await t.enterText(find.bySemanticsLabel('Cerca nella console'), 'bob');
    await t.pump();
    expect(find.text('3 risultati'), findsOneWidget);
    final lines = t.widget<MsConsole>(find.byType(MsConsole)).lines;
    expect(lines.where((l) => l.match), hasLength(3));
  });

  testWidgets('console: invio comando e cronologia con le frecce', (t) async {
    final s = sampleSession();
    await pumpApp(t, _state(s), size: const Size(1280, 1500));
    final input = find.bySemanticsLabel('Comando per il server');
    await t.enterText(input, 'say ciao');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pump();
    expect(s.commandHistory, ['say ciao']);
    expect(s.console.last.text, '> say ciao');
    await t.tap(input);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await t.pump();
    final field = t.widget<EditableText>(
      find.descendant(of: find.byType(MsConsole), matching: find.byType(EditableText)).last,
    );
    expect(field.controller.text, 'say ciao');
  });

  testWidgets('B-DNS-01 come entrano gli amici: indirizzo fisso, IP diretto, porta provata', (
    t,
  ) async {
    await pumpApp(t, _state(sampleSession(), port: _reachable), size: const Size(1280, 1500));
    expect(find.text('zerotier.survival.internal'), findsOneWidget);
    expect(msText('192.0.2.10:25565'), findsWidgets);
    expect(_pill('Porta raggiungibile'), findsOneWidget);
    expect(find.text('verificata dall\'hub 1 min fa'), findsOneWidget);
    expect(msButton('Riprova'), findsOneWidget);
  });

  testWidgets('porta chiusa: spiegazione; in prova: niente Riprova', (t) async {
    final a = _state(
      sampleSession(),
      port: PortCheck(
        state: PortState.blocked,
        port: 25565,
        checkedAt: at(18, 1).millisecondsSinceEpoch,
      ),
    );
    await pumpApp(t, a, size: const Size(1280, 1500));
    expect(_pill('Porta chiusa'), findsOneWidget);
    expect(find.textContaining('Controlla il firewall'), findsOneWidget);
    a.debugSet(spaces: _hosted(const PortCheck(state: PortState.pending, port: 25565)));
    await t.pump();
    expect(_pill('Verifica della porta…'), findsOneWidget);
    final retry = t.widget<MsButton>(msButton('Riprova'));
    expect(retry.onPressed, isNull);
  });

  testWidgets('senza DNS e senza sessione dell\'hub: le interfacce di questo PC', (t) async {
    await pumpApp(t, _state(sampleSession()), size: const Size(1280, 1500));
    expect(find.text('192.0.2.10:25565'), findsOneWidget);
    expect(_pill('Porta raggiungibile'), findsNothing);
  });

  test('Riprova rifiutato dall\'hub (409/429): avvisi gentili, il resto è un errore', () {
    final s = AppStrings(Lang.it);
    (String, MsToastTone) of(ErrorCode c) => portRetryNotice(s, ApiError(c, ''));
    expect(of(ErrorCode.rateLimited), (
      'Verifica appena eseguita. Attendi qualche secondo.',
      MsToastTone.warn,
    ));
    expect(of(ErrorCode.notLocked).$2, MsToastTone.warn);
    expect(of(ErrorCode.featureOff), (
      'Verifica della porta disattivata sull\'hub.',
      MsToastTone.warn,
    ));
    expect(of(ErrorCode.forbidden).$2, MsToastTone.err);
    expect(portRetryNotice(s, const HubUnreachable('x')).$2, MsToastTone.err);
  });

  testWidgets('in inglese', (t) async {
    final a = _state(sampleSession());
    a.config.lang = 'en';
    await pumpApp(t, a, size: const Size(1280, 1500));
    expect(find.text('Survival running on this PC'), findsOneWidget);
    expect(find.bySemanticsLabel('Stop and save'), findsWidgets);
  });
}
