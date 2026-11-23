// Integrazione con il sistema operativo, dietro interfacce: finestra,
// icona nella barra di sistema, notifiche, avvio con il sistema, istanza
// singola, aggiornamento. Le implementazioni vere stanno in platform/ e si
// scelgono in main.dart; i test usano quelle finte qui sotto.
import 'package:flutter/foundation.dart';

/// La finestra principale (barra del titolo disegnata dall'app).
abstract interface class WindowService {
  Future<void> minimize();
  Future<void> toggleMaximize();
  Future<bool> get isMaximized;

  /// Nasconde la finestra (resta l'icona nella barra di sistema).
  Future<void> hide();
  Future<void> show();

  /// Avvia lo spostamento della finestra trascinando la barra del titolo.
  Future<void> startDragging();

  /// Chiamato quando l'utente chiude la finestra; se restituisce false la
  /// chiusura è annullata (es. sessione in corso: si chiede prima).
  set onCloseRequested(Future<bool> Function()? handler);
}

/// Icona nella barra di sistema. Nel menu un'azione con etichetta vuota è un
/// separatore.
abstract interface class TrayService {
  Future<void> setStatus({required String tooltip, required List<TrayAction> actions});
  Future<void> dispose();
}

final class TrayAction {
  const TrayAction(this.label, this.onSelected, {this.enabled = true});
  final String label;
  final void Function() onSelected;
  final bool enabled;
}

/// Notifiche del desktop.
abstract interface class NotificationService {
  Future<void> show({required String title, required String body});
}

/// Avvio con il sistema.
abstract interface class AutostartService {
  Future<bool> get enabled;
  Future<void> setEnabled(bool on);
}

/// Aggiornamento dell'app. Avvisa i listener quando [ready] cambia (per il
/// chip "Riavvia per vX" nella barra del titolo).
abstract interface class UpdateService implements Listenable {
  /// Versione pronta per il riavvio, o null.
  String? get ready;

  /// Controlla e scarica in background un aggiornamento dall'hub.
  Future<void> check(Uri hub);

  /// Riavvia nella versione nuova (mai durante una sessione).
  Future<void> restart();
}

/// L'insieme dei servizi di piattaforma.
final class PlatformServices {
  const PlatformServices({
    required this.window,
    required this.tray,
    required this.notifications,
    required this.autostart,
    required this.updates,
  });

  /// Implementazioni che non fanno niente (test, piattaforme non gestite).
  factory PlatformServices.inert() => PlatformServices(
    window: _InertWindow(),
    tray: _InertTray(),
    notifications: InertNotifications(),
    autostart: _InertAutostart(),
    updates: _InertUpdates(),
  );

  final WindowService window;
  final TrayService tray;
  final NotificationService notifications;
  final AutostartService autostart;
  final UpdateService updates;
}

final class _InertWindow implements WindowService {
  var _max = false;
  @override
  Future<void> minimize() async {}
  @override
  Future<void> toggleMaximize() async => _max = !_max;
  @override
  Future<bool> get isMaximized async => _max;
  @override
  Future<void> hide() async {}
  @override
  Future<void> show() async {}
  @override
  Future<void> startDragging() async {}
  @override
  set onCloseRequested(Future<bool> Function()? handler) {}
}

final class _InertTray implements TrayService {
  @override
  Future<void> setStatus({required String tooltip, required List<TrayAction> actions}) async {}
  @override
  Future<void> dispose() async {}
}

/// Notifiche finte: le ricorda (per i test).
final class InertNotifications implements NotificationService {
  final shown = <(String, String)>[];
  @override
  Future<void> show({required String title, required String body}) async =>
      shown.add((title, body));
}

final class _InertAutostart implements AutostartService {
  var _on = false;
  @override
  Future<bool> get enabled async => _on;
  @override
  Future<void> setEnabled(bool on) async => _on = on;
}

final class _InertUpdates extends ChangeNotifier implements UpdateService {
  @override
  String? get ready => null;
  @override
  Future<void> check(Uri hub) async {}
  @override
  Future<void> restart() async {}
}
