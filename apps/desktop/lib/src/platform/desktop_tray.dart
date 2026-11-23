// Icona nella barra di sistema vera (tray_manager). Clic sinistro: apre la
// finestra; clic destro: il menu (su Linux, con AppIndicator, ogni clic apre
// il menu).
import 'dart:async';
import 'dart:io';

import 'package:tray_manager/tray_manager.dart';

import 'platform.dart';

final class DesktopTray with TrayListener implements TrayService {
  DesktopTray._(this._onOpen);

  /// Crea l'icona; lancia se il plugin o la barra di sistema mancano.
  static Future<DesktopTray> create({required void Function() onOpen}) async {
    final t = DesktopTray._(onOpen);
    await trayManager.setIcon(Platform.isWindows ? 'assets/tray/tray.ico' : 'assets/tray/tray.png');
    trayManager.addListener(t);
    return t;
  }

  final void Function() _onOpen;
  String? _last;

  @override
  Future<void> setStatus({required String tooltip, required List<TrayAction> actions}) async {
    // Si ricostruisce il menu solo se è cambiato (lo stato dell'hub cambia
    // spesso, il menu di rado).
    final key = [tooltip, for (final a in actions) '${a.label}|${a.enabled}'].join('\n');
    if (key == _last) return;
    _last = key;
    final menu = Menu(
      items: [
        for (final a in actions)
          if (a.label.isEmpty)
            MenuItem.separator()
          else
            MenuItem(label: a.label, disabled: !a.enabled, onClick: (_) => a.onSelected()),
      ],
    );
    await trayManager.setContextMenu(menu);
    // Su Linux AppIndicator non ha tooltip.
    if (!Platform.isLinux) await trayManager.setToolTip(tooltip);
  }

  @override
  void onTrayIconMouseDown() => _onOpen();

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  Future<void> dispose() async {
    trayManager.removeListener(this);
    await trayManager.destroy();
  }
}
