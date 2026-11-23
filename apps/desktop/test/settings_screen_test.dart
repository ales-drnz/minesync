// Impostazioni: golden, preferenze salvate (tema, lingua, dimensione,
// notifiche), per server (memoria, spegnimento automatico, Java), limite
// di banda e ricerca.
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_desktop/src/platform/platform.dart';
import 'package:minesync_desktop/src/state/app_state.dart';
import 'package:ms_l10n/ms_l10n.dart';
import 'package:ms_ui/ms_ui.dart';

import 'support/app_harness.dart';

AppState _state({Map<String, Object?> prefs = const {}, SessionEnv session = const SessionEnv()}) {
  final dir = Directory.systemTemp.createTempSync('ms_settings');
  addTearDown(() => dir.deleteSync(recursive: true));
  final s = AppState(
    AppDeps(configDir: dir.path, platform: PlatformServices.inert(), session: session),
  );
  addTearDown(s.dispose);
  s.config
    ..hub = 'http://192.0.2.1:8084'
    ..prefs.addAll(prefs);
  s.debugSet(
    connection: Connection.online,
    hub: sampleHub(),
    latencyMs: 42,
    spaces: sampleSpaces(),
    route: const SettingsRoute(),
  );
  return s;
}

Future<void> _tap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await _settle(t);
}

/// Lascia finire il salvataggio su disco (I/O vero) e ridisegna.
Future<void> _settle(WidgetTester t) async {
  // ogni passo della scrittura atomica riprende nella zona finta del test
  for (var i = 0; i < 12; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump();
  }
}

void main() {
  setUpAll(loadFonts);

  testWidgets('golden', (t) async {
    await expectAppGolden(
      t,
      'settings',
      _state(prefs: {'server.survival.xmx': 6144}),
      size: const Size(1280, 2400),
    );
  });

  testWidgets('golden chiaro, abisso', (t) async {
    await expectAppGolden(
      t,
      'settings_light_abisso',
      _state(prefs: {'theme': 'light', 'palette': 'abisso'}),
      size: const Size(1280, 1100),
      dprs: const [1.0],
    );
  });

  testWidgets('indice delle sezioni: resta fermo e porta la sezione in cima', (t) async {
    final s = _state();
    await pumpApp(t, s, size: const Size(1280, 800));
    // voce del menu (più a sinistra) e titolo del pannello con la stessa etichetta
    (Finder, Finder) both(String label) {
      final f = find.bySemanticsLabel(label);
      final all = f.evaluate().toList();
      expect(all.length, greaterThanOrEqualTo(2), reason: label);
      final xs = [for (var i = 0; i < all.length; i++) t.getTopLeft(f.at(i)).dx];
      final nav = xs.indexOf(xs.reduce((a, b) => a < b ? a : b));
      final panel = xs.indexOf(xs.reduce((a, b) => a > b ? a : b));
      return (f.at(nav), f.at(panel));
    }

    final (navRete, panelRete) = both('Rete');
    final navTop = t.getTopLeft(navRete).dy;
    expect(t.getTopLeft(panelRete).dy, greaterThan(800), reason: 'all\'inizio è sotto');
    await t.tap(navRete);
    // lo scorrimento è animato (220 ms)
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    // il menu non si è mosso, il pannello Rete è salito in cima
    expect(t.getTopLeft(navRete).dy, navTop);
    expect(t.getTopLeft(panelRete).dy, lessThan(navTop + 80));
    // tornando in cima con lo scorrimento si rivede Generali
    await t.drag(find.byType(SingleChildScrollView).last, const Offset(0, 4000));
    await _settle(t);
    final (navGen, panelGen) = both('Generali');
    expect(t.getTopLeft(navGen).dy, lessThan(navTop));
    expect(t.getTopLeft(panelGen).dy, lessThan(navTop + 80));
  });

  testWidgets('tema, stile, dimensione e lingua si salvano subito', (t) async {
    final s = _state();
    await pumpApp(t, s, size: const Size(1280, 2400));
    await _tap(t, find.bySemanticsLabel('Chiaro').first);
    await t.pump();
    expect(s.theme.brightness, Brightness.light);
    expect(s.config.prefs['theme'], 'light');
    await _tap(t, find.bySemanticsLabel('Abisso').first);
    await _tap(t, find.bySemanticsLabel('Grande').first);
    await t.pump();
    expect(s.theme.palette, MsPalette.abisso);
    expect(s.theme.sizeStep, 1);
    await _tap(t, find.bySemanticsLabel('English').first);
    await t.pump();
    expect(s.lang, Lang.en);
    expect(find.text('Settings'), findsWidgets);
    await _tap(t, find.bySemanticsLabel('Same as the system').first);
    await t.pump();
    expect(s.config.lang, isNull);
  });

  testWidgets('notifiche: ogni salvataggio spento di default, si accende', (t) async {
    final s = _state();
    await pumpApp(t, s, size: const Size(1280, 2400));
    expect(s.notifyPref('everySave'), isFalse);
    expect(s.notifyPref('sessionProblems'), isTrue);
    await _tap(t, find.bySemanticsLabel('Ogni salvataggio sull\'hub').first);
    await t.pump();
    expect(s.notifyPref('everySave'), isTrue);
  });

  testWidgets('limite di banda: velocità fissa', (t) async {
    final s = _state();
    await pumpApp(t, s, size: const Size(1280, 2400));
    await _tap(t, find.bySemanticsLabel(RegExp('Velocità fissa')).first);
    await t.pump();
    expect(UploadLimit.fromPrefs(s.config.prefs).mode, UploadLimitMode.fixed);
    final kib = find.byWidgetPredicate((w) => w is EditableText && w.controller.text == '2048');
    await t.enterText(kib, '512');
    await _settle(t);
    expect(UploadLimit.fromPrefs(s.config.prefs).bytesPerSecond(null), 512 * 1024);
  });

  testWidgets('ricerca: restano solo le impostazioni che corrispondono', (t) async {
    final s = _state();
    await pumpApp(t, s, size: const Size(1280, 2400));
    await t.enterText(_searchField, 'banda');
    await t.pump();
    expect(find.text('Limite di banda per i caricamenti'), findsOneWidget);
    expect(find.text('Testo leggibile'), findsNothing);
    await t.enterText(_searchField, 'zzzz');
    await t.pump();
    expect(find.text('Nessuna impostazione corrisponde alla ricerca.'), findsOneWidget);
  });
}

/// Il campo di ricerca delle impostazioni.
final _searchField = find.descendant(
  of: find.byKey(const ValueKey('settings-search')),
  matching: find.byType(EditableText),
);
