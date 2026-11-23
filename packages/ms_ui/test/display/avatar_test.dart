import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';

import 'support.dart';

const _names = ['alice', 'bob', 'carol', 'dave', 'erin', 'frank'];

void main() {
  setUpAll(loadMsFonts);

  test('volto deterministico, simmetrico, occhi fissi, due colori diversi', () {
    for (final n in _names) {
      final a = MsAvatarFace.of(n);
      expect(MsAvatarFace.of(n.toUpperCase()).cells, a.cells);
      expect(a.primary, isNot(a.secondary));
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 4; x++) {
          expect(a.cells[y * 8 + x], a.cells[y * 8 + 7 - x], reason: '$n ($x,$y)');
        }
      }
      for (final i in const [18, 21, 26, 29]) {
        expect(a.cells[i], 3);
      }
    }
    expect(MsAvatarFace.of('alice').cells, isNot(MsAvatarFace.of('bob').cells));
  });

  testWidgets('avatar e pila (pixel puri)', (t) async {
    await displayGoldens(
      t,
      'avatars',
      () => gallery([
        row([for (final n in _names.take(4)) MsAvatar(n, size: MsAvatarSize.large)]),
        row([for (final n in _names) MsAvatar(n)]),
        row([for (final n in _names) MsAvatar(n, size: MsAvatarSize.small)]),
        const MsAvatarStack(names: ['alice', 'bob', 'carol']),
        const MsAvatarStack(names: ['dave', 'erin'], size: MsAvatarSize.medium),
      ]),
      pure: true,
      extra: (c) => const [MsAvatarFace.eyeColor],
      size: const Size(480, 320),
    );
  });

  testWidgets('semantica: etichetta se data, altrimenti decorativo', (t) async {
    final h = t.ensureSemantics();
    await t.pumpWidget(
      host(
        const Row(
          children: [
            MsAvatar('alice', semanticLabel: 'Avatar di alice'),
            MsAvatar('bob'),
            MsAvatarStack(names: ['alice', 'bob'], semanticLabel: '2 online'),
          ],
        ),
      ),
    );
    expect(find.bySemanticsLabel('Avatar di alice'), findsOneWidget);
    expect(find.bySemanticsLabel('2 online'), findsOneWidget);
    h.dispose();
  });
}
