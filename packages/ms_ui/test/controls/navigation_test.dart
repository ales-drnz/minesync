import 'dart:math' as math;
import 'dart:ui' show SemanticsRole, Tristate;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';

import '../support/golden.dart';
import 'support.dart';

void _noop() {}

double _lum(Color c) {
  double ch(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double _contrast(Color a, Color b) {
  final x = _lum(a), y = _lum(b);
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

Widget _tabs() => width(
  760,
  MsTabs<int>(
    semanticLabel: 'Sezioni del server',
    value: 0,
    onChanged: (_) {},
    forcedStates: const {1: MsStates.hover, 3: MsStates.focus},
    tabs: const [
      MsTab(value: 0, label: 'Panoramica'),
      MsTab(value: 1, label: 'Giocatori', count: '6'),
      MsTab(value: 2, label: 'Mod', count: '214'),
      MsTab(value: 3, label: 'Storia'),
      MsTab(value: 4, label: 'Amministrazione', icon: TestIcon(), enabled: false),
    ],
  ),
);

Widget _frame() => width(
  900,
  column([
    const MsTitlebar(
      os: MsTitlebarOs.windows,
      title: 'MineSync',
      version: '0.1.0',
      logo: TestIcon(),
      crumbs: ['Server', 'Survival', 'Sessione'],
      end: [MsKbd('42 ms')],
      minimizeLabel: 'Riduci a icona',
      maximizeLabel: 'Ingrandisci',
      closeLabel: 'Chiudi',
      onMinimize: _noop,
      onMaximize: _noop,
      onClose: _noop,
      forcedHover: 2,
    ),
    const MsTitlebar(
      os: MsTitlebarOs.mac,
      title: 'MineSync',
      crumbs: ['Server', 'Creativo'],
      minimizeLabel: 'Riduci a icona',
      maximizeLabel: 'Ingrandisci',
      closeLabel: 'Chiudi',
      onMinimize: _noop,
      onMaximize: _noop,
      onClose: _noop,
    ),
    Builder(
      builder: (context) => SizedBox(
        height: PixelScope.of(context).d(480),
        child: const Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MsSidebar(
              semanticLabel: 'Navigazione app',
              children: [
                MsSidebarSection('Server'),
                MsNav(
                  children: [
                    MsNavItem(
                      label: 'Survival',
                      icon: TestIcon(),
                      current: true,
                      trailing: MsNavTrail(dot: MsNavDotKind.play, text: 'in gioco'),
                      onPressed: _noop,
                    ),
                    MsNavItem(
                      label: 'Creativo',
                      icon: TestIcon(),
                      trailing: MsNavTrail(dot: MsNavDotKind.free, text: 'libero'),
                      forcedStates: MsStates.hover,
                      onPressed: _noop,
                    ),
                    MsNavItem(
                      label: 'Avventura',
                      icon: TestIcon(),
                      trailing: MsNavTrail(dot: MsNavDotKind.stale, text: 'stale'),
                      forcedStates: MsStates.focus,
                      onPressed: _noop,
                    ),
                    MsNavItem(
                      label: 'Nuovo server',
                      icon: TestIcon(),
                      dashed: true,
                      trailing: MsNavTrail(text: 'Ctrl N'),
                      onPressed: _noop,
                    ),
                    MsNavItem(
                      label: 'Nuovo server',
                      icon: TestIcon(),
                      dashed: true,
                      forcedStates: MsStates.hover,
                      onPressed: _noop,
                    ),
                  ],
                ),
                MsNav(
                  children: [MsNavItem(label: 'Attività', icon: TestIcon(), onPressed: null)],
                ),
              ],
              footer: [
                MsNavItem(
                  label: 'Impostazioni',
                  icon: TestIcon(),
                  current: true,
                  forcedStates: MsStates.focus,
                  trailing: MsKbd('Ctrl ,'),
                  onPressed: _noop,
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  ], gap: 12),
);

void main() {
  setUpAll(loadMsFonts);

  goldenSuite('tabs', _tabs, size: const Size(900, 200));
  goldenSuite('frame', _frame, size: const Size(1000, 700));

  testWidgets('tabs: frecce saltano le schede disattivate; ruoli tab', (t) async {
    final h = t.ensureSemantics();
    var v = 0;
    await t.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, set) => SizedBox(
            width: 600,
            child: MsTabs<int>(
              value: v,
              onChanged: (x) => set(() => v = x),
              tabs: const [
                MsTab(value: 0, label: 'A'),
                MsTab(value: 1, label: 'B', enabled: false),
                MsTab(value: 2, label: 'C'),
              ],
            ),
          ),
        ),
      ),
    );
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pump();
    expect(v, 2);
    await t.sendKeyEvent(LogicalKeyboardKey.home);
    await t.pump();
    expect(v, 0);
    await t.sendKeyEvent(LogicalKeyboardKey.end);
    await t.pump();
    expect(v, 2);
    await t.tap(find.bySemanticsLabel('A').first);
    await t.pump();
    expect(v, 0);
    final data = t.getSemantics(find.bySemanticsLabel('A').first).getSemanticsData();
    expect(data.role, SemanticsRole.tab);
    expect(data.flagsCollection.isSelected, Tristate.isTrue);
    h.dispose();
  });

  testWidgets('nav e barra titolo: tap ed etichette dei controlli', (t) async {
    final h = t.ensureSemantics();
    final log = <String>[];
    await t.pumpWidget(
      host(
        SizedBox(
          width: 800,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MsTitlebar(
                os: MsTitlebarOs.linux,
                title: 'MineSync',
                minimizeLabel: 'Riduci',
                maximizeLabel: 'Ingrandisci',
                closeLabel: 'Chiudi',
                onMinimize: () => log.add('min'),
                onMaximize: () => log.add('max'),
                onClose: () => log.add('close'),
              ),
              SizedBox(
                width: 256,
                child: MsNavItem(label: 'Survival', current: true, onPressed: () => log.add('nav')),
              ),
            ],
          ),
        ),
      ),
    );
    await t.tap(find.bySemanticsLabel('Chiudi').first);
    await t.tap(find.bySemanticsLabel('Riduci').first);
    await t.tap(find.bySemanticsLabel('Survival').first);
    await t.pumpAndSettle();
    expect(log, ['close', 'min', 'nav']);
    final nav = t.getSemantics(find.bySemanticsLabel('Survival').first).getSemanticsData();
    expect(nav.flagsCollection.isSelected, Tristate.isTrue);
    h.dispose();
  });

  testWidgets('voce corrente piena d\'accento: testo e scia leggibili in ogni schema', (t) async {
    for (final theme in const [
      MsThemeData(),
      MsThemeData(brightness: Brightness.light),
      MsThemeData(palette: MsPalette.abisso),
      MsThemeData(palette: MsPalette.abisso, brightness: Brightness.light),
    ]) {
      final c = theme.colors;
      await t.pumpWidget(
        host(
          const SizedBox(
            width: 256,
            child: MsNavItem(
              label: 'Survival',
              current: true,
              trailing: MsNavTrail(dot: MsNavDotKind.play, text: 'in gioco'),
              onPressed: _noop,
            ),
          ),
          theme: theme,
        ),
      );
      final texts = t.widgetList<PixelText>(find.byType(PixelText)).toList();
      expect(texts, hasLength(2));
      for (final x in texts) {
        expect(x.style.color, c.onAccent, reason: '${theme.palette} ${theme.brightness}');
      }
      expect(
        _contrast(c.onAccent, c.accent),
        greaterThanOrEqualTo(4.5),
        reason: '${theme.palette} ${theme.brightness}',
      );
      // il blocco si stacca dalla barra laterale (contrasto non testuale)
      expect(_contrast(c.accent, c.bg2), greaterThanOrEqualTo(3), reason: '${theme.palette}');
    }
  });
}
