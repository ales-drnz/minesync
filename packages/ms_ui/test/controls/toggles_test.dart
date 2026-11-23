import 'dart:ui' show Tristate;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';

import '../support/golden.dart';
import 'support.dart';

void _set(bool _) {}
void _setD(double _) {}

/// Solo geometria: checkbox, switch e slider in ogni stato.
Widget _geometry() => column([
  hrow([
    const MsCheckbox(value: false, onChanged: _set),
    const MsCheckbox(value: true, onChanged: _set),
    const MsCheckbox(value: true, onChanged: _set, forcedStates: MsStates.focus),
    const MsCheckbox(value: false, onChanged: null),
    const MsCheckbox(value: true, onChanged: null),
  ]),
  hrow([
    const MsSwitch(value: false, onChanged: _set),
    const MsSwitch(value: true, onChanged: _set),
    const MsSwitch(value: true, onChanged: _set, forcedStates: MsStates.focus),
    const MsSwitch(value: false, onChanged: null),
    const MsSwitch(value: true, onChanged: null),
  ]),
  width(
    320,
    column([
      const MsSlider(value: 0, onChanged: _setD),
      const MsSlider(value: .4, onChanged: _setD),
      const MsSlider(value: 1, onChanged: _setD, forcedStates: MsStates.focus),
      const MsSlider(value: .4, onChanged: null),
    ], gap: 8),
  ),
]);

Widget _choices() => width(
  480,
  column([
    const MsSwitch(
      value: true,
      onChanged: _set,
      label: 'Autostop dopo 30 min senza giocatori',
      description: 'Acceso: barretta "I" e manopola a destra',
    ),
    const MsSwitch(value: false, onChanged: _set, label: 'Annuncia su Telegram'),
    const MsSwitch(value: false, onChanged: null, label: 'Disattivato'),
    const MsCheckbox(value: true, onChanged: _set, label: 'Server aperto'),
    const MsCheckbox(value: false, onChanged: null, label: 'Disattivato'),
    MsRadioGroup<String>(
      semanticLabel: 'Limite di banda',
      value: 'auto',
      onChanged: (_) {},
      forcedStates: const {1: MsStates.hover, 3: MsStates.focus},
      options: [
        const MsRadioOption(
          value: 'auto',
          title: 'Automatico',
          description: 'Uso il 70% della velocità misurata',
        ),
        const MsRadioOption(
          value: 'pct',
          title: 'Percentuale',
          description: 'della velocità misurata',
        ),
        MsRadioOption(
          value: 'fixed',
          title: 'Velocità fissa',
          description: 'sempre la stessa',
          trailing: width(120, const MsSlider(value: .5, onChanged: null)),
        ),
        const MsRadioOption(value: 'none', title: 'Nessun limite'),
        const MsRadioOption(value: 'off', title: 'Non disponibile', enabled: false),
      ],
    ),
  ], gap: 8),
);

void main() {
  setUpAll(loadMsFonts);

  goldenSuite('toggles_geometry', _geometry, pure: true, size: const Size(600, 400));
  goldenSuite('toggles', _choices, size: const Size(600, 800));

  testWidgets('checkbox: tap sulla riga e Spazio cambiano il valore', (t) async {
    final h = t.ensureSemantics();
    var v = false;
    await t.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, set) =>
              MsCheckbox(value: v, label: 'Server aperto', onChanged: (x) => set(() => v = x)),
        ),
      ),
    );
    await t.tap(find.bySemanticsLabel('Server aperto').first);
    await t.pump();
    expect(v, isTrue);
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.sendKeyEvent(LogicalKeyboardKey.space);
    await t.pump();
    expect(v, isFalse);
    expect(
      t.getSemantics(find.bySemanticsLabel('Server aperto').first),
      matchesSemantics(
        label: 'Server aperto',
        hasCheckedState: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        isFocused: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    h.dispose();
  });

  testWidgets('switch: semantica toggled, disattivato immobile, riga alta 44', (t) async {
    final h = t.ensureSemantics();
    var v = false;
    await t.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, set) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MsSwitch(value: v, label: 'Autostop', onChanged: (x) => set(() => v = x)),
              const MsSwitch(value: true, label: 'Spento', onChanged: null),
            ],
          ),
        ),
      ),
    );
    await t.tap(find.bySemanticsLabel('Autostop').first);
    await t.pumpAndSettle();
    expect(v, isTrue);
    final data = t.getSemantics(find.bySemanticsLabel('Autostop').first).getSemanticsData();
    expect(data.flagsCollection.isToggled, Tristate.isTrue);
    await t.tap(find.bySemanticsLabel('Spento').first, warnIfMissed: false);
    await t.pump();
    final g = PixelGrid.forDpr(t.view.devicePixelRatio);
    expect(
      t.getSize(find.bySemanticsLabel('Autostop').first).height,
      greaterThanOrEqualTo(g.d(44)),
    );
    h.dispose();
  });

  testWidgets('radio: frecce cambiano scelta, saltano i disattivati', (t) async {
    var v = 'a';
    await t.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, set) => SizedBox(
            width: 400,
            child: MsRadioGroup<String>(
              value: v,
              onChanged: (x) => set(() => v = x),
              options: const [
                MsRadioOption(value: 'a', title: 'A'),
                MsRadioOption(value: 'b', title: 'B', enabled: false),
                MsRadioOption(value: 'c', title: 'C'),
              ],
            ),
          ),
        ),
      ),
    );
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pump();
    expect(v, 'c');
    await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await t.pump();
    expect(v, 'a');
    await t.tap(find.bySemanticsLabel('C'));
    await t.pump();
    expect(v, 'c');
  });

  testWidgets('slider: frecce, Inizio/Fine, passo e trascinamento', (t) async {
    final h = t.ensureSemantics();
    var v = 8.0;
    await t.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, set) => SizedBox(
            width: 400,
            child: MsSlider(
              value: v,
              min: 0,
              max: 20,
              step: 1,
              semanticLabel: 'Banda',
              semanticFormatter: (x) => '$x Mbit/s',
              onChanged: (x) => set(() => v = x),
            ),
          ),
        ),
      ),
    );
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pump();
    expect(v, 9);
    await t.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await t.pump();
    expect(v, 7);
    await t.sendKeyEvent(LogicalKeyboardKey.end);
    await t.pump();
    expect(v, 20);
    await t.sendKeyEvent(LogicalKeyboardKey.home);
    await t.pump();
    expect(v, 0);
    final r = t.getRect(find.byType(MsSlider));
    await t.dragFrom(r.centerLeft + const Offset(10, 0), Offset(r.width, 0));
    await t.pump();
    expect(v, 20);
    final node = t.getSemantics(find.byType(MsSlider));
    expect(node.getSemanticsData().flagsCollection.isSlider, isTrue);
    expect(node.getSemanticsData().value, '20.0 Mbit/s');
    h.dispose();
  });
}
