// Notifiche del desktop vere (local_notifier: libnotify su Linux, toast su
// Windows, UserNotifications su macOS).
//
// Windows: i toast richiedono un collegamento nel menu Start con l'AUMID
// dell'app; local_notifier lo crea o lo sistema col nome "MineSync". Il
// collegamento creato dall'installer (che punta al launcher) ha lo stesso
// nome, quindi viene solo marcato con l'AUMID e continua a puntare al
// launcher.
import 'package:local_notifier/local_notifier.dart';

import 'platform.dart';

final class DesktopNotifications implements NotificationService {
  DesktopNotifications._(this._log);

  /// Inizializza il plugin; lancia se non è disponibile.
  static Future<DesktopNotifications> create({void Function(String)? log}) async {
    await localNotifier.setup(appName: 'MineSync', shortcutPolicy: ShortcutPolicy.requireCreate);
    return DesktopNotifications._(log ?? (_) {});
  }

  final void Function(String) _log;

  @override
  Future<void> show({required String title, required String body}) async {
    try {
      await LocalNotification(title: title, body: body).show();
    } on Object catch (e) {
      // Una notifica persa non deve mai rompere chi la manda.
      _log('notifica non mostrata: $e');
    }
  }
}
