import 'dart:ui' show SemanticsRole;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';

import '../support/golden.dart';
import 'support.dart';

const _langs = [
  MsSelectOption(value: 'auto', label: 'Automatica'),
  MsSelectOption(value: 'it', label: 'Italiano'),
  MsSelectOption(value: 'en', label: 'English'),
];

Widget _fields() => width(
  420,
  column([
    const MsField(
      label: 'Nome del server',
      help: 'Massimo 40 caratteri.',
      child: MsTextInput(placeholder: 'es. Survival'),
    ),
    MsField(
      label: 'Nome del server · hover',
      child: MsTextInput(
        controller: TextEditingController(text: 'Creativo'),
        forcedStates: MsStates.hover,
      ),
    ),
    MsField(
      label: 'Indirizzo dell\'hub · focus',
      child: MsTextInput(
        mono: true,
        controller: TextEditingController(text: 'http://192.0.2.10:8084'),
        forcedStates: MsStates.focus,
      ),
    ),
    MsField(
      label: 'Indirizzo dell\'hub · errore',
      error: 'Hub non raggiungibile: controlla di essere connesso alla rete ZeroTier.',
      child: MsTextInput(
        mono: true,
        controller: TextEditingController(text: 'http://192.0.2.10:8048'),
      ),
    ),
    MsField(
      label: 'Cartella locale · disattivato',
      child: MsTextInput(
        mono: true,
        enabled: false,
        controller: TextEditingController(text: '~/MineSync/survival'),
      ),
    ),
    MsField(
      label: 'Lingua dei messaggi',
      child: MsSelect<String>(options: _langs, value: 'auto', onChanged: (_) {}),
    ),
    MsField(
      label: 'Dove tengo i mondi',
      child: MsInputGroup(
        input: MsTextInput(mono: true, controller: TextEditingController(text: '~/MineSync')),
        actions: [MsButton(label: 'Scegli…', icon: const TestIcon(), onPressed: () {})],
      ),
    ),
    MsSegmented<String>(
      semanticLabel: 'Lingua',
      segments: const [
        MsSegment(value: 'it', label: 'IT'),
        MsSegment(value: 'en', label: 'EN'),
        MsSegment(value: 'sys', label: 'Come il sistema'),
      ],
      value: 'it',
      onChanged: (_) {},
      forcedStates: const {1: MsStates.hover, 0: MsStates.focus},
    ),
    const MsSegmented<String>(
      segments: [
        MsSegment(value: 'mc', label: 'Minecraft'),
        MsSegment(value: 'dir', label: 'Cartella generica'),
      ],
      value: 'dir',
      onChanged: null,
    ),
  ]),
);

/// Solo geometria: campi vuoti e select senza testo.
Widget _geometry() => width(
  240,
  column([
    const MsTextInput(),
    const MsTextInput(forcedStates: MsStates.hover),
    const MsTextInput(forcedStates: MsStates.focus),
    const MsTextInput(error: true),
    const MsTextInput(enabled: false),
    MsSelect<String>(options: const [], value: null, onChanged: (_) {}),
    MsSelect<String>(
      options: const [],
      value: null,
      onChanged: (_) {},
      forcedStates: MsStates.focus,
    ),
    const MsSelect<String>(options: [], value: null, onChanged: null),
  ]),
);

void main() {
  setUpAll(loadMsFonts);

  goldenSuite('fields', _fields, size: const Size(600, 900));
  goldenSuite('fields_geometry', _geometry, pure: true, size: const Size(400, 600));

  testWidgets('golden: menu della select aperto', (t) async {
    setGoldenView(t, 1.0, size: const Size(400, 300));
    await t.pumpWidget(
      goldenHost(
        1.0,
        Overlay.wrap(
          child: SizedBox(
            width: 360,
            height: 260,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 240,
                  child: MsSelect<String>(options: _langs, value: 'it', onChanged: (_) {}),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.byType(MsSelect<String>));
    await t.pumpAndSettle();
    await expectLater(
      find.byKey(const Key('ms-golden-capture')),
      matchesGoldenFile('goldens/select_open/dpr_1.00.png'),
    );
  });

  group('input', () {
    testWidgets('scrive, invia, legge l\'etichetta del campo', (t) async {
      final h = t.ensureSemantics();
      String? sent;
      final ctl = TextEditingController();
      addTearDown(ctl.dispose);
      await t.pumpWidget(
        host(
          SizedBox(
            width: 300,
            child: MsField(
              label: 'Nome',
              child: MsTextInput(controller: ctl, onSubmitted: (v) => sent = v),
            ),
          ),
        ),
      );
      await t.tap(find.byType(EditableText));
      await t.enterText(find.byType(EditableText), 'Survival');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      expect(ctl.text, 'Survival');
      expect(sent, 'Survival');
      expect(find.bySemanticsLabel('Nome'), findsOneWidget);
      h.dispose();
    });

    testWidgets('errore del campo: annunciato come alert', (t) async {
      final h = t.ensureSemantics();
      await t.pumpWidget(
        host(
          const SizedBox(
            width: 300,
            child: MsField(label: 'Hub', error: 'Non raggiungibile', child: MsTextInput()),
          ),
        ),
      );
      final node = t.getSemantics(find.byType(MsFieldError));
      expect(node.getSemanticsData().role, SemanticsRole.alert);
      h.dispose();
    });

    testWidgets('maxLength e disattivato', (t) async {
      final ctl = TextEditingController();
      addTearDown(ctl.dispose);
      await t.pumpWidget(
        host(SizedBox(width: 300, child: MsTextInput(controller: ctl, maxLength: 3))),
      );
      await t.enterText(find.byType(EditableText), 'abcdef');
      expect(ctl.text, 'abc');
    });
  });

  group('select', () {
    testWidgets('tastiera: apre, scorre, sceglie, Esc chiude', (t) async {
      String? v = 'auto';
      await t.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, set) => SizedBox(
              width: 240,
              child: MsSelect<String>(
                options: _langs,
                value: v,
                autofocus: true,
                onChanged: (x) => set(() => v = x),
              ),
            ),
          ),
        ),
      );
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown); // apre
      await t.pump();
      expect(find.text('English', skipOffstage: false), findsNothing); // PixelText, non Text
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      expect(v, 'en');
      await t.sendKeyEvent(LogicalKeyboardKey.space); // riapre
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.home);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      expect(v, 'en');
      // lettera: salta a "Italiano"
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.keyI);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      expect(v, 'it');
    });

    testWidgets('mouse: apre e sceglie un\'opzione', (t) async {
      final h = t.ensureSemantics();
      String? v = 'auto';
      await t.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, set) => SizedBox(
              width: 240,
              child: MsSelect<String>(
                options: _langs,
                value: v,
                semanticLabel: 'Lingua',
                onChanged: (x) => set(() => v = x),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.byType(MsSelect<String>));
      await t.pump();
      expect(find.bySemanticsLabel('Italiano'), findsOneWidget);
      await t.tap(find.bySemanticsLabel('Italiano'));
      await t.pump();
      expect(v, 'it');
      expect(find.bySemanticsLabel('Italiano'), findsNothing);
      h.dispose();
    });

    testWidgets('disattivata non si apre', (t) async {
      await t.pumpWidget(
        host(
          const SizedBox(
            width: 240,
            child: MsSelect<String>(options: _langs, value: 'it', onChanged: null),
          ),
        ),
      );
      await t.tap(find.byType(MsSelect<String>));
      await t.pump();
      expect(find.byType(Overlay), findsWidgets);
      expect(find.bySemanticsLabel('English'), findsNothing);
    });
  });

  group('segmented', () {
    testWidgets('frecce e tap cambiano la scelta; semantica radio', (t) async {
      final h = t.ensureSemantics();
      var v = 'it';
      await t.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, set) => MsSegmented<String>(
              semanticLabel: 'Lingua',
              segments: const [
                MsSegment(value: 'it', label: 'IT'),
                MsSegment(value: 'en', label: 'EN'),
              ],
              value: v,
              onChanged: (x) => set(() => v = x),
            ),
          ),
        ),
      );
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pump();
      expect(v, 'en');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight); // gira
      await t.pump();
      expect(v, 'it');
      await t.tap(find.bySemanticsLabel('EN'));
      await t.pump();
      expect(v, 'en');
      expect(
        t.getSemantics(find.bySemanticsLabel('EN')),
        matchesSemantics(
          label: 'EN',
          hasCheckedState: true,
          isChecked: true,
          isInMutuallyExclusiveGroup: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      h.dispose();
    });
  });
}
