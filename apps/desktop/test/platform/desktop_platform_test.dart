// Servizi di piattaforma senza plugin (come nei test o su un sistema a cui
// manca una libreria): l'app deve partire lo stesso con i servizi inerti.
// Più le parti pure: dimensioni salvate della finestra, menu della barra di
// sistema.
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_desktop/src/l10n/l10n.dart';
import 'package:minesync_desktop/src/platform/desktop_platform.dart';
import 'package:minesync_desktop/src/platform/desktop_tray.dart';
import 'package:minesync_desktop/src/platform/desktop_window.dart';
import 'package:minesync_desktop/src/platform/platform.dart';
import 'package:minesync_desktop/src/platform/tray_status.dart';
import 'package:minesync_desktop/src/state/app_state.dart';
import 'package:minesync_desktop/src/update/update_service.dart';

import '../support/app_harness.dart';

final class _RecordingTray implements TrayService {
  String? tooltip;
  List<TrayAction> actions = const [];
  var disposed = false;
  @override
  Future<void> setStatus({required String tooltip, required List<TrayAction> actions}) async {
    this.tooltip = tooltip;
    this.actions = actions;
  }

  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('plugin assenti: tutto ripiega sugli inerti senza errori', () async {
    final logs = <String>[];
    final d = await DesktopPlatform.create(env: const {}, log: logs.add);
    expect(d.window, isNull);
    expect(d.tray, isNull);
    // local_notifier su Linux e macOS non parla col nativo finché non mostra
    // una notifica: lì il ripiego avviene dentro show().
    expect(d.unavailable, containsAll(['window', 'tray']));
    expect(logs, hasLength(d.unavailable.length));
    // i servizi inerti rispondono comunque
    await d.services.window.minimize();
    await d.services.notifications.show(title: 't', body: 'b');
    expect(d.services.updates, isA<HubUpdateService>());
    expect((d.services.updates as HubUpdateService).managed, isFalse);
    final state = testState();
    await d.attach(state);
    await d.dispose();
  });

  test('plugin che falliscono a metà: stesso ripiego', () async {
    final d = await DesktopPlatform.create(
      env: const {},
      log: (_) {},
      window: () async => throw StateError('niente finestra'),
      tray: (_) async => throw StateError('niente barra di sistema'),
      notifications: () async => throw StateError('niente libnotify'),
    );
    expect(d.unavailable, ['window', 'tray', 'notifications']);
  });

  test('i costruttori veri lanciano senza plugin (non si bloccano)', () async {
    await expectLater(DesktopWindow.create(), throwsA(anything));
    await expectLater(DesktopTray.create(onOpen: () {}), throwsA(anything));
  });

  test('icona collegata allo stato: menu aggiornato, "esci" ed "apri"', () async {
    final tray = _RecordingTray();
    final d = await DesktopPlatform.create(
      env: const {'MINESYNC_AUTOSTART': '1'},
      log: (_) {},
      tray: (_) async => tray,
    );
    expect(d.autostarted, isTrue);
    final state = testState()..config.hub = 'http://hub.test:8084';
    await d.attach(state);
    state.debugSet(connection: Connection.online);
    expect(tray.tooltip, contains('MineSync'));
    expect(tray.actions.map((a) => a.label), contains('Apri MineSync'));
    await d.dispose();
    expect(tray.disposed, isTrue);
  });

  group('dimensioni salvate', () {
    const screen = Rect.fromLTWH(0, 0, 1920, 1080);

    test('rettangolo valido su uno schermo: ripristinato', () {
      final r = restorableBounds({'x': 100, 'y': 50, 'w': 1300, 'h': 900}, [screen]);
      expect(r, const Rect.fromLTWH(100, 50, 1300, 900));
    });

    test('mai sotto la dimensione minima', () {
      final r = restorableBounds({'x': 0, 'y': 0, 'w': 300, 'h': 200}, [screen]);
      expect(r!.size, minWindowSize);
    });

    test('su un monitor staccato o illeggibile: si ricomincia dal centro', () {
      expect(restorableBounds({'x': 4000, 'y': 50, 'w': 1300, 'h': 900}, [screen]), isNull);
      expect(restorableBounds({'x': 'a'}, [screen]), isNull);
      expect(restorableBounds(null, [screen]), isNull);
    });

    test('schermi sconosciuti: ci si fida del salvato', () {
      expect(restorableBounds({'x': 4000, 'y': 0, 'w': 1300, 'h': 900}, const []), isNotNull);
    });

    test('preferenza salvata: interi e stato massimizzato', () {
      expect(boundsPref(const Rect.fromLTWH(1.4, 2.6, 1300, 900), maximized: true), {
        'x': 1,
        'y': 3,
        'w': 1300,
        'h': 900,
        'max': true,
      });
    });
  });

  group('menu della barra di sistema', () {
    test('senza hub: solo apri ed esci', () {
      final state = testState();
      final (tooltip, actions) = trayContent(state, onOpen: () {}, onQuit: () {});
      expect(tooltip, 'MineSync');
      expect(actions.map((a) => a.label), ['Apri MineSync', '', 'Esci']);
    });

    test('con hub: stato dell\'hub e dei server, in sola lettura', () {
      var quit = 0;
      final state = testState()..config.hub = 'http://hub.test:8084';
      final (tooltip, actions) = trayContent(state, onOpen: () {}, onQuit: () => quit++);
      expect(tooltip, startsWith('MineSync: '));
      final servers = actions.where((a) => !a.enabled).map((a) => a.label).toList();
      expect(servers.length, 1 + state.spaces.length);
      expect(servers.skip(1).every((l) => l.contains(': ')), isTrue);
      actions.last.onSelected();
      expect(quit, 1);
    });

    test('hub offline: niente server', () {
      final state = testState()
        ..config.hub = 'http://hub.test:8084'
        ..debugSet(connection: Connection.offline);
      final (_, actions) = trayContent(state, onOpen: () {}, onQuit: () {});
      expect(actions.where((a) => !a.enabled), hasLength(1));
    });

    test('in inglese', () async {
      final state = testState();
      await state.setLang(Lang.en);
      final (_, actions) = trayContent(state, onOpen: () {}, onQuit: () {});
      expect(actions.first.label, 'Open MineSync');
      expect(actions.last.label, 'Quit');
    });
  });
}
