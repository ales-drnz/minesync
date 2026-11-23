// Contenuto dell'icona nella barra di sistema, ricavato dallo stato
// dell'app: suggerimento con lo stato dell'hub, "Apri MineSync", lo stato di
// ogni server (solo lettura), "Esci".
import 'package:flutter/foundation.dart';

import '../l10n/l10n.dart';
import '../state/app_state.dart';
import 'platform.dart';

/// Suggerimento e azioni per lo stato attuale.
(String, List<TrayAction>) trayContent(
  AppState app, {
  required void Function() onOpen,
  required void Function() onQuit,
}) {
  final s = ShellStrings.of(app.lang);
  final hub = switch (app.connection) {
    Connection.online => s.connected(app.hub?.name ?? '', app.latencyMs ?? 0),
    Connection.offline => s.offline,
    Connection.connecting || Connection.none => s.connecting,
  };
  final tooltip = app.config.hub == null ? s.appName : '${s.appName}: $hub';
  final online = app.connection == Connection.online;
  return (
    tooltip,
    [
      TrayAction(s.trayOpen, onOpen),
      if (app.config.hub != null) ...[
        const TrayAction('', _none),
        TrayAction(hub, _none, enabled: false),
        if (online)
          for (final sp in app.spaces)
            TrayAction(
              '${sp.name}: ${switch (sp.lock) {
                null => s.lockFree,
                final l when l.stale => s.lockStale,
                final l => s.lockPlaying(l.name),
              }}',
              _none,
              enabled: false,
            ),
      ],
      const TrayAction('', _none),
      TrayAction(s.trayQuit, onQuit),
    ],
  );
}

void _none() {}

/// Tiene aggiornata l'icona finché vive.
final class TrayStatus {
  TrayStatus(this.app, this.tray, {required this.onOpen, required this.onQuit}) {
    app.addListener(_update);
    _update();
  }

  final AppState app;
  final TrayService tray;
  final void Function() onOpen;
  final void Function() onQuit;

  void _update() {
    final (tooltip, actions) = trayContent(app, onOpen: onOpen, onQuit: onQuit);
    tray.setStatus(tooltip: tooltip, actions: actions).catchError((Object e) {
      debugPrint('[tray] $e');
    });
  }

  void dispose() => app.removeListener(_update);
}
