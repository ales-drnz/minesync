// Fluidità sul desktop reale (Linux/Windows/macOS), da eseguire in profile:
//   flutter drive --profile -d linux --driver=test_driver/perf_driver.dart \
//     --target=integration_test/perf_test.dart
// Misura i tempi di build/raster dei fotogrammi durante lo scroll continuo
// della console con 2000 righe e durante pressioni ripetute del GIOCA.
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pixel_spike/ms/components.dart';
import 'package:pixel_spike/ms/tokens.dart';
import 'package:pixel_spike/pixel/grid.dart';
import 'package:pixel_spike/pixel/render.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('console 2000 righe + GIOCA', (tester) async {
    final ctl = ScrollController();
    final lines = demoLines(2000);
    // GIOCA in alto e console sotto: tutto dentro la finestra predefinita.
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: Ms.bg,
        child: PixelScope(
          child: Builder(builder: (context) {
            final g = PixelScope.of(context);
            final size = MediaQuery.sizeOf(context);
            return Padding(
              padding: EdgeInsets.all(g.d(16)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MsPlayButton(onPressed: () {}),
                  const PixelGap(0, 16),
                  MsConsole(
                      lines: lines,
                      controller: ctl,
                      // altezza: quello che resta della finestra, in px di design
                      height: ((size.height - g.d(16 * 2 + 86 + 16 + 8)) / g.unit * 2).floorToDouble()),
                ],
              ),
            );
          }),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final view = ui.PlatformDispatcher.instance.implicitView!;
    binding.reportData ??= {};
    binding.reportData!['env'] = {
      'devicePixelRatio': view.devicePixelRatio,
      'physicalSize': '${view.physicalSize.width.toInt()}x${view.physicalSize.height.toInt()}',
      'refreshRate': view.display.refreshRate,
      'unitPx': PixelGrid.forDpr(view.devicePixelRatio).unitPx,
      'visibleLines': (tester.getSize(find.byKey(const Key('console-list'))).height /
              PixelGrid.forDpr(view.devicePixelRatio).d(20))
          .floor(),
    };

    // scroll continuo: 0 -> fondo in 6 s, poi fondo -> 0 in 6 s
    const dur = Duration(seconds: 6);
    final sw = Stopwatch();
    await binding.watchPerformance(() async {
      sw.start();
      await ctl.animateTo(ctl.position.maxScrollExtent, duration: dur, curve: Curves.linear);
      await ctl.animateTo(0, duration: dur, curve: Curves.linear);
      sw.stop();
    }, reportKey: 'console_scroll');
    // fotogrammi al secondo effettivi = frame_count / durata dello scroll
    binding.reportData!['console_scroll_seconds'] = sw.elapsedMilliseconds / 1000;
    final n = (binding.reportData!['console_scroll'] as Map)['frame_count'] as int;
    binding.reportData!['console_scroll_fps'] = n / (sw.elapsedMilliseconds / 1000);

    // fling ripetuti con la rotella/trascinamento
    await binding.watchPerformance(() async {
      for (var i = 0; i < 6; i++) {
        await tester.fling(find.byKey(const Key('console-list')), Offset(0, i.isEven ? -1500 : 1500), 3000);
        await tester.pumpAndSettle();
      }
    }, reportKey: 'console_fling');

    // pressioni del GIOCA (animazione 80 ms a scatti di pixel fisici)
    final btn = find.byType(MsPlayButton);
    await binding.watchPerformance(() async {
      for (var i = 0; i < 20; i++) {
        final g = await tester.startGesture(tester.getCenter(btn));
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await g.up();
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }, reportKey: 'play_press');
  });
}
