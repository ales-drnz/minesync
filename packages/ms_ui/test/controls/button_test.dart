import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';

import '../support/golden.dart';
import 'support.dart';

void _noop() {}

/// Stati della matrice del canvas: normale, hover, premuto, focus,
/// disattivato, caricamento.
const _states = <(MsStates?, bool disabled, bool loading)>[
  (null, false, false),
  (MsStates.hover, false, false),
  (MsStates(hovered: true, pressed: true), false, false),
  (MsStates.focus, false, false),
  (null, true, false),
  (null, false, true),
];

Widget _matrix() => Builder(
  builder: (context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final v in MsButtonVariant.values) ...[
        row(context, [
          for (final (s, disabled, loading) in _states)
            MsButton(
              label: loading ? 'Carico' : 'Carica',
              icon: const TestIcon(),
              variant: v,
              loading: loading,
              onPressed: disabled ? null : _noop,
              forcedStates: s,
            ),
        ]),
        const PixelGap(0, 12),
      ],
      row(context, [
        const MsButton(label: 'Salva ora', size: MsButtonSize.sm, onPressed: _noop),
        const MsButton(
          label: 'Riavvia',
          size: MsButtonSize.sm,
          variant: MsButtonVariant.primary,
          onPressed: _noop,
        ),
        const MsButton(
          label: 'Connetti',
          size: MsButtonSize.lg,
          variant: MsButtonVariant.primary,
          icon: TestIcon(),
          onPressed: _noop,
        ),
        const MsButton(label: 'Non ora', size: MsButtonSize.lg, onPressed: _noop),
      ]),
      const PixelGap(0, 12),
      SizedBox(
        width: PixelScope.of(context).d(400),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MsButton(
              label: 'Usa la versione dell\'hub',
              variant: MsButtonVariant.primary,
              block: true,
              onPressed: _noop,
            ),
            MsButton(
              label: 'Scarica dall\'hub',
              icon: TestIcon(),
              block: true,
              trailing: MsKbd('D'),
              onPressed: _noop,
            ),
          ],
        ),
      ),
      const PixelGap(0, 12),
      row(context, [
        const MsButton.play(
          label: 'Gioca',
          subtitle: 'pronto in pochi secondi',
          icon: TestIcon(),
          onPressed: _noop,
        ),
      ]),
    ],
  ),
);

/// Solo geometria e Silkscreen: icone e GIOCA, nessun testo vettoriale.
Widget _geometry() => Builder(
  builder: (context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final v in MsButtonVariant.values) ...[
        row(context, [
          for (final (s, disabled, loading) in _states)
            MsButton.icon(
              icon: const TestIcon(),
              semanticLabel: 'Copia',
              variant: v,
              loading: loading,
              onPressed: disabled ? null : _noop,
              forcedStates: s,
            ),
          MsButton.icon(
            icon: const TestIcon(),
            semanticLabel: 'Copia',
            size: MsButtonSize.sm,
            variant: v,
            onPressed: _noop,
          ),
        ]),
        const PixelGap(0, 8),
      ],
      for (final pair in [_states.sublist(0, 3), _states.sublist(3)]) ...[
        row(context, [
          for (final (s, disabled, loading) in pair)
            MsButton.play(
              label: loading ? 'Sincronizzo' : (disabled ? 'alice gioca' : 'Gioca'),
              icon: const TestIcon(),
              loading: loading,
              onPressed: disabled ? null : _noop,
              forcedStates: s,
            ),
        ], gap: 24),
        const PixelGap(0, 16),
      ],
    ],
  ),
);

void main() {
  setUpAll(loadMsFonts);

  group('golden', () {
    testWidgets('matrice prato scuro', (t) async {
      await expectControlGoldens(t, 'button_matrix', _matrix());
    });
    testWidgets('matrice prato chiaro', (t) async {
      await expectControlGoldens(
        t,
        'button_matrix_prato_light',
        _matrix(),
        theme: pratoLightTheme,
        dprs: const [1.0],
      );
    });
    testWidgets('matrice abisso scuro', (t) async {
      await expectControlGoldens(
        t,
        'button_matrix_abisso_dark',
        _matrix(),
        theme: abissoDarkTheme,
        dprs: const [1.0],
      );
    });
    testWidgets('geometria pura (icone, GIOCA)', (t) async {
      await expectControlGoldens(t, 'button_geometry', _geometry(), pure: true);
    });
    testWidgets('geometria pura prato chiaro', (t) async {
      await expectControlGoldens(
        t,
        'button_geometry_prato_light',
        _geometry(),
        theme: pratoLightTheme,
        pure: true,
        dprs: const [1.0, 1.5],
      );
    });
    testWidgets('geometria pura abisso scuro (cristalli)', (t) async {
      await expectControlGoldens(
        t,
        'button_geometry_abisso_dark',
        _geometry(),
        theme: abissoDarkTheme,
        pure: true,
        dprs: const [1.0, 1.5],
      );
    });
  });

  group('comportamento', () {
    testWidgets('tap chiama onPressed; disattivato no', (t) async {
      var n = 0;
      await t.pumpWidget(
        host(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MsButton(label: 'Carica', onPressed: () => n++),
              const MsButton(label: 'Spento', onPressed: null),
            ],
          ),
        ),
      );
      await t.tap(find.bySemanticsLabel('Carica'));
      await t.pumpAndSettle();
      expect(n, greaterThanOrEqualTo(1));
      final before = n;
      await t.tap(find.bySemanticsLabel('Spento'), warnIfMissed: false);
      await t.pumpAndSettle();
      expect(n, before);
    });

    testWidgets('Tab mette a fuoco, Invio e Spazio attivano', (t) async {
      var n = 0;
      await t.pumpWidget(host(MsButton(label: 'Carica', onPressed: () => n++)));
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.space);
      await t.pumpAndSettle();
      expect(n, 2);
    });

    testWidgets('disattivato non riceve il focus', (t) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await t.pumpWidget(host(MsButton(label: 'X', onPressed: null, focusNode: node)));
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(node.hasFocus, isFalse);
    });

    testWidgets('caricamento: focusabile ma non attivabile', (t) async {
      var n = 0;
      final node = FocusNode();
      addTearDown(node.dispose);
      await t.pumpWidget(
        host(MsButton(label: 'Carico', loading: true, focusNode: node, onPressed: () => n++)),
      );
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(node.hasFocus, isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      await t.tap(find.bySemanticsLabel('Carico'));
      await t.pump();
      expect(n, 0);
    });

    testWidgets('semantica: pulsante con etichetta, abilitato o no', (t) async {
      final h = t.ensureSemantics();
      await t.pumpWidget(
        host(
          const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MsButton.icon(icon: TestIcon(), semanticLabel: 'Copia', onPressed: _noop),
              MsButton.play(label: 'Gioca', subtitle: 'pronto', onPressed: null),
            ],
          ),
        ),
      );
      expect(
        t.getSemantics(find.bySemanticsLabel('Copia')),
        matchesSemantics(
          label: 'Copia',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      expect(
        t.getSemantics(find.bySemanticsLabel('Gioca, pronto')),
        matchesSemantics(label: 'Gioca, pronto', isButton: true, hasEnabledState: true),
      );
      h.dispose();
    });

    testWidgets('bersaglio minimo 44 px e pressione di 2 px', (t) async {
      await t.pumpWidget(host(const MsButton(label: 'Ok', onPressed: _noop)));
      final g = PixelGrid.forDpr(t.view.devicePixelRatio);
      final box = t.renderObject<RenderBox>(find.byType(PixelFrame));
      // box esterno = 44 + margini 2/2 e 2/8
      expect(box.size.height, g.d(44 + 10));
      expect(box.size.width, greaterThanOrEqualTo(g.d(48)));
      final gesture = await t.startGesture(t.getCenter(find.byType(PixelFrame)));
      await t.pumpAndSettle();
      int shift() => t.widget<PixelFrame>(find.byType(PixelFrame)).childShiftPhys;
      expect(shift(), g.unitPx);
      await gesture.up();
      await t.pumpAndSettle();
      expect(shift(), 0);
    });

    testWidgets('animazioni ridotte: pressione immediata', (t) async {
      await t.pumpWidget(
        host(
          const MsButton(label: 'Ok', onPressed: _noop),
          theme: const MsThemeData(reducedMotion: true),
        ),
      );
      final gesture = await t.startGesture(t.getCenter(find.byType(PixelFrame)));
      await t.pump();
      expect(
        t.widget<PixelFrame>(find.byType(PixelFrame)).childShiftPhys,
        PixelGrid.forDpr(t.view.devicePixelRatio).unitPx,
      );
      await gesture.up();
      await t.pump();
    });
  });
}
