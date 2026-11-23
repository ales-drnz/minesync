import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';
import 'package:ms_ui/src/components/display/common.dart';

import 'support.dart';

Iterable<Color> _dimmed(MsColors c) => [
  for (final x in [c.accent, c.accentHi, c.ok, c.warn, c.err]) msBlend(x, c.inset, .6),
];

void main() {
  setUpAll(loadMsFonts);

  testWidgets('barre a lingotti (pixel pure)', (t) async {
    await displayGoldens(
      t,
      'progress',
      () => gallery(width: 400, [
        const MsProgress(value: 0),
        const MsProgress(value: .63),
        const MsProgress(value: 1, tone: MsProgressTone.ok, thin: true),
        const MsProgress(value: .92, tone: MsProgressTone.warn, thin: true),
        const MsProgress(value: .3, tone: MsProgressTone.err),
        const MsProgress.indeterminate(),
        const MsProgress.indeterminate(thin: true),
        Builder(
          builder: (context) => MsTheme(
            data: MsTheme.of(context).copyWith(reducedMotion: true),
            child: const MsProgress.indeterminate(),
          ),
        ),
      ]),
      pure: true,
      extra: _dimmed,
      size: const Size(480, 400),
    );
  });

  testWidgets('barra con dettagli', (t) async {
    await displayGoldens(
      t,
      'progress_meta',
      () => gallery(width: 400, gap: 8, [
        const MsProgressMeta(
          start: MsText.rich(
            [MsSpan('Scarico le differenze', strong: true), MsSpan(' · 214 / 340 file')],
            kind: MsTextKind.small,
            tone: MsTextTone.secondary,
            strongWeight: 600,
          ),
          end: MsText.small('63 %', weight: 600, tabular: true),
        ),
        const MsProgress(value: .63, semanticLabel: 'Download'),
        const MsProgressMeta(
          start: MsText.small('812 MB di 1,29 GB', tone: MsTextTone.secondary, tabular: true),
          end: MsText.small('24,6 MB/s · ETA 0:19', tone: MsTextTone.secondary, tabular: true),
        ),
      ]),
      size: const Size(480, 200),
    );
  });

  testWidgets('semantica: barra di progresso con valore', (t) async {
    final h = t.ensureSemantics();
    await t.pumpWidget(host(const MsProgress(value: .63, semanticLabel: 'Download')));
    expect(
      t.getSemantics(find.bySemanticsLabel('Download')),
      isSemantics(label: 'Download', value: '63%', role: SemanticsRole.progressBar),
    );
    await t.pumpWidget(
      host(const MsProgress(value: .5, semanticLabel: 'Upload', valueLabel: '50 %')),
    );
    expect(t.getSemantics(find.bySemanticsLabel('Upload')), isSemantics(value: '50 %'));
    h.dispose();
  });

  testWidgets('il valore avanza a 4 scatti in --ms-dur-3', (t) async {
    double fill() {
      // larghezza del primo lingotto disegnato: si misura dal repaintKey
      final box = t.widget<PixelBox>(find.byType(PixelBox));
      final key = box.repaintKey! as (double, int, Object, Object, Object, Object, Object);
      return key.$1;
    }

    await t.pumpWidget(host(const SizedBox(width: 200, child: MsProgress(value: 0))));
    await t.pumpWidget(host(const SizedBox(width: 200, child: MsProgress(value: 1))));
    expect(fill(), 0);
    await t.pump(const Duration(milliseconds: 70));
    expect(fill(), .25);
    await t.pump(const Duration(milliseconds: 60));
    expect(fill(), .5);
    await t.pump(MsDuration.d3);
    expect(fill(), 1);
    // con le animazioni ridotte il valore è immediato
    await t.pumpWidget(
      host(
        const SizedBox(width: 200, child: MsProgress(value: .2)),
        theme: const MsThemeData(reducedMotion: true),
      ),
    );
    expect(fill(), closeTo(.2, 1e-9));
  });

  testWidgets('indeterminata: anima, ma è ferma con le animazioni ridotte', (t) async {
    await t.pumpWidget(host(const SizedBox(width: 200, child: MsProgress.indeterminate())));
    expect(t.binding.hasScheduledFrame, isTrue);
    await t.pumpWidget(
      host(
        const SizedBox(width: 200, child: MsProgress.indeterminate()),
        theme: const MsThemeData(reducedMotion: true),
      ),
    );
    await t.pump();
    expect(t.binding.hasScheduledFrame, isFalse);
  });
}
