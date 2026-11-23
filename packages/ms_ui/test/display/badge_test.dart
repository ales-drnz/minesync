import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';
import 'package:ms_ui/src/components/display/common.dart';

import 'support.dart';

Iterable<Color> _lockExtra(MsColors c) => [msBlend(const Color(0xFF000000), c.lockPlay, .25)];

void main() {
  setUpAll(loadMsFonts);

  testWidgets('badge, pillole e lock senza testo vettoriale (pixel puri)', (t) async {
    await displayGoldens(
      t,
      'badges',
      () => gallery([
        row([
          const MsBadge('Salva', kind: MsBadgeKind.push),
          const MsBadge('Avvio', kind: MsBadgeKind.lock),
          const MsBadge('Stop', kind: MsBadgeKind.stop),
          const MsBadge('Forza', kind: MsBadgeKind.force),
          const MsBadge('Ripristino', kind: MsBadgeKind.restore),
          const MsBadge('Pulizia', kind: MsBadgeKind.gc),
          const MsBadge('Disco', kind: MsBadgeKind.disk),
        ]),
        row([for (final tone in MsStatusTone.values) MsPill(tone.name, tone: tone)]),
        row([for (final tone in MsStatusTone.values) MsPill(tone.name, tone: tone, solid: true)]),
        row([
          const MsLock(label: 'Libero'),
          const MsLock(label: 'In gioco', state: MsLockState.play),
          const MsLock(label: 'Stale', state: MsLockState.stale),
        ]),
        row([
          const MsLock(label: 'Libero', big: true),
          const MsLock(label: 'In gioco', state: MsLockState.play, big: true),
          const MsLock(label: 'Stale', state: MsLockState.stale, big: true),
        ]),
      ]),
      pure: true,
      extra: _lockExtra,
      size: const Size(640, 320),
    );
  });

  testWidgets('chip, lock con dettagli, indicatore live, livello', (t) async {
    await displayGoldens(
      t,
      'chips',
      () => gallery([
        row([
          const MsChip('1.21.1'),
          const MsChip('214 mod'),
          const MsChip('gen #128', tone: MsChipTone.accent),
          MsChip('Riavvia per 0.1.1', tone: MsChipTone.update, onTap: () {}),
          MsChip('focus', onTap: () {}, forceFocus: true),
        ]),
        row([
          const MsLock(label: 'In gioco', state: MsLockState.play, meta: '· bob · 3 online'),
          const MsLock(label: 'Stale', state: MsLockState.stale, meta: '· heartbeat perso'),
          const MsLock(label: 'In gioco', state: MsLockState.play, meta: '· alice', big: true),
        ]),
        row([
          const MsLive('42 ms'),
          const MsLive('Hub offline', online: false),
          const MsLevel('#128'),
          const MsLevel('7'),
          // il tooltip vive in un Overlay
          SizedBox(
            width: 64,
            height: 24,
            child: Overlay(
              initialEntries: [
                OverlayEntry(
                  builder: (_) => const Row(
                    children: [
                      MsIconTag(MsIcon(MsIcons.server), tooltip: 'Solo sul server'),
                      SizedBox(width: 8),
                      MsIconTag(MsIcon(MsIcons.user), tooltip: 'Solo per i giocatori'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ]),
      ]),
      extra: _lockExtra,
      size: const Size(640, 260),
    );
  });

  testWidgets('animazioni ridotte: niente lampeggio', (t) async {
    await t.pumpWidget(
      host(
        const Row(
          children: [
            MsLock(label: 'In gioco', state: MsLockState.play),
            MsLive('online'),
          ],
        ),
        theme: const MsThemeData(reducedMotion: true),
      ),
    );
    await t.pump(const Duration(seconds: 3));
    expect(t.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('il lampeggio cambia due volte per periodo, senza un frame per refresh', (t) async {
    await t.pumpWidget(
      host(
        const Row(
          children: [
            MsLock(label: 'In gioco', state: MsLockState.play),
            MsLive('online'),
          ],
        ),
      ),
    );
    // niente frame in coda fra uno scatto e l'altro
    expect(t.binding.hasScheduledFrame, isFalse);
    final b = MsBlink(const Duration(milliseconds: 1600));
    addTearDown(b.dispose);
    var changes = 0;
    b.addListener(() => changes++);
    b.repeat();
    await t.pump(const Duration(milliseconds: 1700));
    expect(changes, 2);
    expect(b.value, 0);
    b.stop();
    await t.pump(const Duration(seconds: 2));
    expect(changes, 2);
  });

  testWidgets('le etichette pixel sono lette dalle tecnologie assistive', (t) async {
    final h = t.ensureSemantics();
    await t.pumpWidget(
      host(
        const Row(
          children: [
            MsBadge('Salva', kind: MsBadgeKind.push),
            MsPill('Raggiungibile', tone: MsStatusTone.ok),
            MsLock(label: 'Libero'),
          ],
        ),
      ),
    );
    expect(find.bySemanticsLabel('Salva'), findsOneWidget);
    expect(find.bySemanticsLabel('Raggiungibile'), findsOneWidget);
    expect(find.bySemanticsLabel('Libero'), findsOneWidget);
    h.dispose();
  });

  testWidgets('etichetta a icona: 24×24, tooltip che è anche l\'etichetta letta', (t) async {
    final h = t.ensureSemantics();
    await t.pumpWidget(
      host(
        Overlay(
          initialEntries: [
            OverlayEntry(
              builder: (_) => const Padding(
                padding: EdgeInsets.all(80),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: MsIconTag(MsIcon(MsIcons.server), tooltip: 'Solo sul server'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    final box = t.getSize(find.byType(PixelFrame).first);
    final g = PixelScope.of(t.element(find.byType(MsIconTag)));
    expect(box, Size(g.d(24), g.d(24)));
    expect(find.bySemanticsLabel(RegExp('Solo sul server')), findsWidgets);
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(t.getCenter(find.byType(MsIconTag)));
    await t.pump(MsDuration.d4);
    expect(find.byType(MsTooltipBubble), findsOneWidget);
    h.dispose();
  });

  testWidgets('dati su una riga: entrano tutti, oppure l\'ultimo visibile si accorcia', (t) async {
    Future<void> at(double w) => t.pumpWidget(
      host(
        Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: w,
            child: const MsMeta([
              'aggiunto a mano',
              'Non trovato su Modrinth: va aggiornato a mano',
              'ultima',
            ], maxLines: 1),
          ),
        ),
      ),
    );
    await at(900);
    expect(t.takeException(), isNull);
    expect(find.byType(PixelFrame), findsNWidgets(3));
    await at(260);
    // niente trabocco: la seconda si accorcia, la terza non si mostra
    expect(t.takeException(), isNull);
    expect(find.byType(PixelFrame), findsNWidgets(2));
    expect(t.getSize(find.byType(MsMeta)).width, lessThanOrEqualTo(260));
    // anche la prima si accorcia invece di sparire
    await at(60);
    expect(t.takeException(), isNull);
    expect(find.byType(PixelFrame), findsOneWidget);
    expect(t.getSize(find.byType(MsMeta)).width, lessThanOrEqualTo(60));
  });
}
