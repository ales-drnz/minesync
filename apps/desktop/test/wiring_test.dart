// Collegamenti tra cornice, aggiornamento e chiusura della finestra.
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_desktop/src/platform/platform.dart';
import 'package:ms_ui/ms_ui.dart';

import 'support/app_harness.dart';

final class _Updates extends ChangeNotifier implements UpdateService {
  @override
  String? ready;
  int restarts = 0;
  @override
  Future<void> check(Uri hub) async {}
  @override
  Future<void> restart() async => restarts++;
}

final class _Window implements WindowService {
  Future<bool> Function()? handler;
  @override
  set onCloseRequested(Future<bool> Function()? h) => handler = h;
  @override
  Future<void> minimize() async {}
  @override
  Future<void> toggleMaximize() async {}
  @override
  Future<bool> get isMaximized async => false;
  @override
  Future<void> hide() async {}
  @override
  Future<void> show() async {}
  @override
  Future<void> startDragging() async {}
  @override
  Future<void> setMinimumSize(Size size) async {}
}

PlatformServices _platform(_Updates u, _Window w) {
  final inert = PlatformServices.inert();
  return PlatformServices(
    window: w,
    tray: inert.tray,
    notifications: inert.notifications,
    autostart: inert.autostart,
    updates: u,
  );
}

void main() {
  setUpAll(loadFonts);

  testWidgets('chip "Riavvia per" e dialogo di aggiornamento', (t) async {
    final u = _Updates();
    final w = _Window();
    await pumpApp(t, testState(), platform: _platform(u, w));
    expect(find.byType(MsChip), findsNothing);
    u
      ..ready = '0.1.1'
      ..notifyListeners();
    await t.pump();
    expect(find.bySemanticsLabel(RegExp('Riavvia per 0.1.1')), findsWidgets);
    await t.tap(find.bySemanticsLabel(RegExp('Riavvia per 0.1.1')).first);
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await t.tap(find.bySemanticsLabel(RegExp('^Riavvia')).last);
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(u.restarts, 1);
  });

  testWidgets('la chiusura della finestra passa dalla conferma dell\'app', (t) async {
    final w = _Window();
    await pumpApp(t, testState(), platform: _platform(_Updates(), w));
    expect(w.handler, isNotNull);
    // senza sessione si chiude subito
    expect(await w.handler!(), isTrue);
  });
}
