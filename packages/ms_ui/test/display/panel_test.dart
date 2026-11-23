import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';
import 'package:ms_ui/src/components/display/common.dart';

import 'support.dart';

Iterable<Color> _extra(MsColors c) => [msBlend(c.drop, c.bg), ...textureColors(c)];

void main() {
  setUpAll(loadMsFonts);

  testWidgets('pannelli, slot e card senza testo vettoriale (pixel puri)', (t) async {
    await displayGoldens(
      t,
      'containers',
      () => gallery(width: 560, [
        MsPanel(
          title: 'Stato sull\'hub',
          actions: [const MsBadge('Avvio', kind: MsBadgeKind.lock)],
          foot: const [SizedBox(width: 80, height: 20)],
          child: row([
            const MsSlot.square(child: MsTexture(MsTextureKind.grass)),
            const MsSlot.square(child: MsTexture(MsTextureKind.stone)),
            const MsSlot(child: MsText.label('Entra in gioco su', tone: MsTextTone.secondary)),
          ]),
        ),
        const MsPanel(
          title: 'Rilievo',
          plainTitle: true,
          raised: true,
          padding: MsPanelPadding.tight,
          child: SizedBox(height: 24),
        ),
        row([
          for (final (hover, pressed, selected, focus) in const [
            (false, false, false, false),
            (true, false, false, false),
            (false, true, false, false),
            (false, false, true, false),
            (false, false, false, true),
          ])
            SizedBox(
              width: 96,
              child: MsCard(
                onTap: () {},
                selected: selected,
                forceHover: hover,
                forcePressed: pressed,
                forceFocus: focus,
                child: const SizedBox(height: 24),
              ),
            ),
        ], gap: 16),
        row([
          const SizedBox(
            width: 160,
            child: MsCard(kind: MsCardKind.static, child: SizedBox(height: 24)),
          ),
          SizedBox(
            width: 200,
            child: MsCard.add(label: 'Nuovo server', onTap: () {}),
          ),
          SizedBox(
            width: 200,
            child: MsCard.add(label: 'Nuovo server', onTap: () {}, forceHover: true),
          ),
        ], gap: 16),
      ]),
      pure: true,
      extra: _extra,
      size: const Size(640, 800),
    );
  });

  testWidgets('card e pannello con contenuto', (t) async {
    await displayGoldens(
      t,
      'cards',
      () => gallery(width: 560, [
        const MsPanel(
          title: 'Trasferimento',
          actions: [MsPill('Download', tone: MsStatusTone.info)],
          child: MsFacts([
            MsFact('Ultimo push', 'bob · 18:47'),
            MsFact('Generazione', '#128 (HEAD)'),
            MsFact('Online', 'alice, bob, carol'),
          ]),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 16,
          children: [
            for (final (name, tex, lock, hover, sel) in const [
              ('Survival', MsTextureKind.grass, MsLockState.free, false, false),
              ('Creativo', MsTextureKind.stone, MsLockState.play, true, false),
              ('Avventura', MsTextureKind.wood, MsLockState.stale, false, true),
            ])
              Expanded(
                child: MsCard(
                  onTap: () {},
                  forceHover: hover,
                  selected: sel,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 12,
                    children: [
                      Row(
                        spacing: 12,
                        children: [
                          MsSlot.square(child: MsTexture(tex)),
                          Flexible(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                MsText.h3(name, maxLines: 1),
                                const MsText.small('gen #128', tone: MsTextTone.secondary),
                              ],
                            ),
                          ),
                        ],
                      ),
                      MsLock(label: lock.name, state: lock),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ]),
      extra: _extra,
      size: const Size(640, 520),
    );
  });

  testWidgets('card: clic, tastiera, hover e semantica', (t) async {
    final h = t.ensureSemantics();
    var taps = 0;
    await t.pumpWidget(
      host(
        Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 200,
            child: MsCard(
              onTap: () => taps++,
              selected: true,
              semanticLabel: 'Survival',
              child: const SizedBox(height: 40),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.byType(MsCard));
    expect(taps, 1);
    expect(
      t.getSemantics(find.bySemanticsLabel('Survival')),
      isSemantics(isButton: true, isSelected: true),
    );
    // hover: la card sale a scatti fino a −2 px in --ms-dur-2
    final g = await t.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: Offset.zero);
    await g.moveTo(t.getCenter(find.byType(MsCard)));
    await t.pump();
    await t.pump(MsDuration.d2);
    await g.removePointer();
    h.dispose();
  });

  testWidgets('il pannello espone il titolo come intestazione', (t) async {
    final h = t.ensureSemantics();
    await t.pumpWidget(host(const MsPanel(title: 'Sessione', child: SizedBox(height: 10))));
    expect(t.getSemantics(find.bySemanticsLabel('Sessione').last), isSemantics(isHeader: true));
    h.dispose();
  });
}
