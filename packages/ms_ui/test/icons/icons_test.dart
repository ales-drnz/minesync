import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';
import 'package:ms_ui/src/icons/icon_data.dart' show logoLayout;

import '../../tool/export_icon.dart' as exporter;

String get _dart =>
    Platform.resolvedExecutable.contains('flutter') ? 'dart' : Platform.resolvedExecutable;

void main() {
  test('icons.g.dart allineato a icons.json', () {
    final r = Process.runSync(_dart, ['run', 'tool/gen_icons.dart', '--check']);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
  });

  test('icone: nomi unici, 8 × 8, nessuna vuota', () {
    final names = {for (final i in MsIcons.values) i.name};
    expect(names.length, MsIcons.values.length);
    expect(MsIcons.values.length, 51);
    for (final i in MsIcons.values) {
      expect((i.width, i.height), (8, 8), reason: i.name);
      expect(i.runs, isNotEmpty, reason: i.name);
      for (var k = 0; k < i.runs.length; k += 3) {
        expect(i.runs[k] + i.runs[k + 2], lessThanOrEqualTo(8), reason: i.name);
        expect(i.runs[k + 1], lessThan(8), reason: i.name);
      }
    }
    expect(MsIcons.play.filled(2, 0), isTrue);
    expect(MsIcons.play.filled(3, 0), isFalse);
  });

  test('logo: disegni e scale come nel canvas', () {
    (int, int, int) l(int box, {int? content}) {
      final r = logoLayout(msLogoArt, box, content: content);
      return (r.art.width, r.scale, r.offset);
    }

    expect(l(16), (16, 1, 0));
    expect(l(20), (16, 1, 2));
    expect(l(24), (16, 1, 4));
    expect(l(32), (32, 1, 0));
    expect(l(40), (32, 1, 4));
    expect(l(48), (16, 3, 0));
    expect(l(64), (64, 1, 0));
    expect(l(96), (32, 3, 0));
    expect(l(128), (64, 2, 0));
    expect(l(256), (64, 4, 0));
    expect(l(1024, content: 960), (64, 15, 32));
    expect(l(192, content: 168), (32, 5, 16));
    expect(l(8), (16, 1, -4));
    // Contorno nell'angolo arrotondato di un pixel, faccia chiara dentro.
    expect(msLogoArt.grid16.roleAt(0, 0), -1);
    expect(msLogoArt.grid16.roleAt(1, 0), 0);
    expect(msLogoArt.grid16.roleAt(1, 1), 1);
  });

  test('export: deterministico e uguale ai file versionati', () {
    final a = exporter.renderAll(Directory.current.path);
    final b = exporter.renderAll(Directory.current.path);
    expect(a.keys, b.keys);
    for (final k in a.keys) {
      expect(a[k], b[k], reason: k);
    }
    for (final path in [
      'packages/ms_ui/assets/brand/minesync-16.png',
      'packages/ms_ui/assets/brand/minesync-256.png',
      'apps/desktop/windows/runner/resources/app_icon.ico',
      'apps/hub_web/web/icons/Icon-maskable-192.png',
    ]) {
      expect(File('../../$path').readAsBytesSync(), a[path], reason: path);
    }
  });

  test('export --check: tutti i file aggiornati', () {
    final r = Process.runSync(_dart, ['run', 'tool/export_icon.dart', '--check']);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
  });

  test('PNG esportato: pixel del logo, ingrandimento intero', () {
    // 48 = griglia 16 ×3: ogni cella è un blocco 3 × 3 dello stesso colore.
    final px = exporter.renderRgba((size: 48, content: null, maskable: false), background: 0);
    int at(int x, int y) {
      final i = (y * 48 + x) * 4;
      return (px[i + 3] << 24) | (px[i] << 16) | (px[i + 1] << 8) | px[i + 2];
    }

    for (var y = 0; y < 16; y++) {
      for (var x = 0; x < 16; x++) {
        final role = msLogoArt.grid16.roleAt(x, y);
        final want = role < 0 ? 0 : msLogoPrato.roles[role];
        for (var dy = 0; dy < 3; dy++) {
          for (var dx = 0; dx < 3; dx++) {
            expect(at(x * 3 + dx, y * 3 + dy), want, reason: '($x,$y)');
          }
        }
      }
    }
  });

  testWidgets('MsIcon: decorativa senza etichetta, colore corrente', (t) async {
    final handle = t.ensureSemantics();
    await t.pumpWidget(
      const MsTheme(
        data: MsThemeData(),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            children: [
              MsIcon(MsIcons.play),
              MsIcon(MsIcons.stop, semanticLabel: 'Ferma'),
              MsLogo(),
            ],
          ),
        ),
      ),
    );
    expect(find.bySemanticsLabel('Ferma'), findsOneWidget);
    expect(find.bySemanticsLabel('MineSync'), findsOneWidget);
    final ctx = t.element(find.byType(MsIcon).first);
    expect(MsIcon.currentColor(ctx), pratoDark.text);
    handle.dispose();
  });

  testWidgets('senza size l\'icona prende la dimensione da IconTheme', (t) async {
    t.view.devicePixelRatio = 1.5;
    addTearDown(t.view.reset);
    late double got;
    await t.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(devicePixelRatio: 1.5),
        child: MsTheme(
          data: const MsThemeData(),
          child: Builder(
            builder: (c) {
              final unit = PixelScope.of(c).unit;
              return IconTheme(
                data: IconThemeData(size: 32 / 2 * unit),
                child: Builder(
                  builder: (c2) {
                    got = MsIcon.sizeOf(c2, null);
                    return const SizedBox();
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
    expect(got, 32);
  });
}
