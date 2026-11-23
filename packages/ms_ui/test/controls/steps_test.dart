import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';

import '../support/golden.dart';
import 'support.dart';

const _steps = [MsStep('Origine'), MsStep('Versione'), MsStep('Mod'), MsStep('EULA')];

/// Inizio, a metà, con un passo saltato, tutto fatto.
Widget _gallery() => column([
  const MsSteps(steps: _steps, current: 0),
  const MsSteps(steps: _steps, current: 2),
  const MsSteps(
    steps: [MsStep('Origine'), MsStep('Versione'), MsStep('Mod', skipped: true), MsStep('EULA')],
    current: 3,
  ),
  const MsSteps(steps: _steps, current: 4),
]);

void main() {
  setUpAll(loadMsFonts);

  goldenSuite('steps', _gallery, size: const Size(700, 300));

  testWidgets('steps: un solo nodo «passo X di N» con il passo corrente', (t) async {
    final h = t.ensureSemantics();
    await t.pumpWidget(
      host(
        MsSteps(
          steps: _steps,
          current: 1,
          semanticLabel: 'Passi',
          positionLabel: (p, n) => 'passo $p di $n',
        ),
      ),
    );
    expect(
      t.getSemantics(find.bySemanticsLabel('Passi')),
      matchesSemantics(label: 'Passi', value: 'passo 2 di 4, Versione'),
    );
    expect(find.bySemanticsLabel('Origine'), findsNothing);
    h.dispose();
  });

  testWidgets('steps: oltre l\'ultimo passo sono tutti fatti', (t) async {
    final h = t.ensureSemantics();
    await t.pumpWidget(host(const MsSteps(steps: _steps, current: 9, semanticLabel: 'Passi')));
    expect(
      t.getSemantics(find.bySemanticsLabel('Passi')),
      matchesSemantics(label: 'Passi', value: '4 / 4'),
    );
    h.dispose();
  });
}
