import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';
import 'package:ms_ui/src/components/display/common.dart';

import 'support.dart';

Iterable<Color> _extra(MsColors c) => [
  msBlend(c.text, c.panel, .35),
  msBlend(c.accentInk, c.panel, .35),
  msBlend(c.overlay, c.panelHi, .7),
];

/// Quadrato pixel 16×16 al posto di un'icona.
class _Ico extends StatelessWidget {
  const _Ico();
  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color!;
    return PixelBox(
      width: 16,
      height: 16,
      repaintKey: color,
      painter: (p, w, h) {
        p.rect(0, 0, 16, 4, color);
        p.rect(6, 4, 4, 12, color);
      },
    );
  }
}

void main() {
  setUpAll(loadMsFonts);

  testWidgets('spinner e skeleton (pixel puri)', (t) async {
    await displayGoldens(
      t,
      'loading',
      () => Builder(
        builder: (context) {
          final c = MsTheme.colorsOf(context);
          return SizedBox(
            width: 360,
            child: MsPanel(
              title: 'Caricamento',
              child: gallery([
                row([
                  const MsSpinner(semanticLabel: 'Caricamento'),
                  MsSpinner(large: true, color: c.accentInk),
                ]),
                MsList(
                  children: [
                    for (var i = 0; i < 2; i++)
                      const MsListRow(
                        title: '',
                        lead: MsSkeleton.square(),
                        trail: SizedBox(width: 120, child: MsSkeleton.title()),
                      ),
                  ],
                ),
                const MsSkeleton.text(),
                const MsSkeleton.short(),
              ]),
            ),
          );
        },
      ),
      pure: true,
      extra: _extra,
      size: const Size(440, 420),
    );
  });

  testWidgets('avvisi, stati vuoti, statistiche, dati', (t) async {
    await displayGoldens(
      t,
      'messages',
      () => gallery(width: 520, [
        const MsAlert(
          tone: MsAlertTone.err,
          icon: _Ico(),
          title: 'Lock perso: server fermato',
          text: 'Un admin ha forzato il rilascio. Il mondo è salvo solo su questo PC.',
          actions: [MsChip('Carica')],
        ),
        const MsAlert(tone: MsAlertTone.warn, icon: _Ico(), title: 'Hub quasi pieno'),
        const MsAlert(
          icon: _Ico(),
          title: 'Hub irraggiungibile',
          text: 'Salvo in locale e carico appena torna.',
        ),
        const MsAlert(tone: MsAlertTone.ok, icon: _Ico(), title: 'Sessione terminata'),
        Row(
          spacing: 16,
          children: [
            const Expanded(
              child: MsPanel(
                padding: MsPanelPadding.none,
                child: MsEmptyState(
                  title: 'Nessun server',
                  text: 'Questo hub è ancora vuoto.',
                  art: MsTexture(MsTextureKind.grass, width: 64, height: 64),
                ),
              ),
            ),
            Expanded(
              child: MsPanel(
                padding: MsPanelPadding.none,
                child: MsEmptyState(
                  error: true,
                  title: 'Non ti riconosco',
                  text: 'Connettiti alla rete del gruppo.',
                  action: MsChip('Riprova', onTap: () {}),
                ),
              ),
            ),
          ],
        ),
        row(const [
          MsStat(value: '3', label: 'Server', icon: _Ico()),
          MsStat(value: '1', label: 'Aperti ora', icon: _Ico(), iconTone: MsTextTone.info),
          MsStat(value: '12', label: 'In gioco', icon: _Ico(), iconTone: MsTextTone.ok),
        ], gap: 24),
      ]),
      extra: (c) => textureColors(c),
      size: const Size(600, 900),
    );
  });

  testWidgets('geometria degli avvisi (pixel pura)', (t) async {
    await displayGoldens(
      t,
      'alerts_geometry',
      () => gallery(width: 320, [
        for (final tone in MsAlertTone.values) MsAlert(tone: tone, icon: const _Ico(), title: ''),
      ]),
      pure: true,
      size: const Size(400, 300),
    );
  });

  testWidgets('semantica: avviso, stato vuoto in errore, spinner, statistica', (t) async {
    final h = t.ensureSemantics();
    await t.pumpWidget(
      host(
        const Column(
          children: [
            MsAlert(tone: MsAlertTone.err, title: 'Errore grave'),
            MsAlert(title: 'Nota'),
            MsEmptyState(title: 'Non ti riconosco', error: true),
            MsSpinner(semanticLabel: 'Caricamento'),
            MsStat(value: '3', label: 'Server'),
          ],
        ),
      ),
    );
    expect(
      t.getSemantics(find.bySemanticsLabel('Errore grave')),
      isSemantics(role: SemanticsRole.alert),
    );
    expect(t.getSemantics(find.bySemanticsLabel('Nota')), isSemantics(role: SemanticsRole.status));
    expect(
      t.getSemantics(find.bySemanticsLabel('Caricamento')),
      isSemantics(role: SemanticsRole.loadingSpinner),
    );
    expect(find.bySemanticsLabel('3 Server'), findsOneWidget);
    h.dispose();
  });

  testWidgets('animazioni ridotte: spinner e skeleton fermi', (t) async {
    const w = SizedBox(width: 200, child: Column(children: [MsSpinner(), MsSkeleton()]));
    await t.pumpWidget(host(w, theme: const MsThemeData(reducedMotion: true)));
    expect(t.binding.hasScheduledFrame, isFalse);
    await t.pumpWidget(host(w));
    expect(t.binding.hasScheduledFrame, isTrue);
    // anche con l'impostazione di sistema
    await t.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: MsTheme(data: MsThemeData(), child: w),
        ),
      ),
    );
    await t.pump();
    expect(t.binding.hasScheduledFrame, isFalse);
  });
}
