// Servizi di piattaforma veri per il desktop, con ripiego: se un plugin non
// c'è o fallisce (sistema senza barra di sistema, libreria mancante, test)
// quel servizio diventa quello inerte e l'app parte lo stesso.
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';

import '../state/app_state.dart';
import '../update/update_service.dart';
import 'autostart.dart';
import 'desktop_notifications.dart';
import 'desktop_tray.dart';
import 'desktop_window.dart';
import 'desktop_entry.dart';
import 'platform.dart';
import 'single_instance.dart';
import 'tray_status.dart';

/// Primo controllo degli aggiornamenti dopo l'avvio, poi a intervalli.
const updateFirstCheck = Duration(seconds: 30);
const updateEvery = Duration(hours: 6);

final class DesktopPlatform {
  DesktopPlatform._({
    required this.services,
    required this.window,
    required this.tray,
    required this.instance,
    required this.env,
    required this.autostarted,
    required this.unavailable,
    required void Function(String) log,
  }) : _log = log;

  /// Crea i servizi. [window], [tray] e [notifications] costruiscono quelli
  /// veri (sostituibili nei test); se lanciano si usa quello inerte.
  static Future<DesktopPlatform> create({
    required Map<String, String> env,
    List<String> args = const [],
    PrimaryInstance? instance,
    void Function(String)? log,
    Future<DesktopWindow> Function()? window,
    Future<TrayService> Function(void Function() onOpen)? tray,
    Future<NotificationService> Function()? notifications,
  }) async {
    final say = log ?? (s) => debugPrint('[platform] $s');
    final inert = PlatformServices.inert();
    final unavailable = <String>[];
    Future<T?> attempt<T>(String name, Future<T> Function() make) async {
      try {
        return await make();
      } on Object catch (e) {
        unavailable.add(name);
        say('$name non disponibile, ripiego: $e');
        return null;
      }
    }

    final w = await attempt('window', window ?? DesktopWindow.create);
    final WindowService win = w ?? inert.window;
    final t = await attempt(
      'tray',
      () => (tray ?? (open) => DesktopTray.create(onOpen: open))(() => unawaited(win.show())),
    );
    final n = await attempt(
      'notifications',
      notifications ?? () => DesktopNotifications.create(log: say),
    );
    final services = PlatformServices(
      window: win,
      tray: t ?? inert.tray,
      notifications: n ?? inert.notifications,
      autostart: SystemAutostart(command: launchCommand(env), env: env),
      updates: HubUpdateService(env: env, log: (s) => say('update: $s')),
    );
    // voce del menu e icona nella barra delle applicazioni (Linux)
    unawaited(installLinuxDesktopEntry(env, log: say));
    return DesktopPlatform._(
      services: services,
      window: w,
      tray: t,
      instance: instance,
      env: env,
      autostarted: args.contains(autostartArg) || env['MINESYNC_AUTOSTART'] == '1',
      unavailable: unavailable,
      log: say,
    );
  }

  final PlatformServices services;

  /// Finestra vera, o null se window_manager non c'è.
  final DesktopWindow? window;

  /// Icona vera, o null se la barra di sistema non c'è.
  final TrayService? tray;
  final PrimaryInstance? instance;
  final Map<String, String> env;

  /// Avviata dal sistema all'accesso: resta nella barra di sistema.
  final bool autostarted;

  /// Servizi ripiegati su quelli inerti.
  final List<String> unavailable;
  final void Function(String) _log;

  TrayStatus? _trayStatus;
  StreamSubscription<void>? _showSub;
  Timer? _updateTimer;

  /// Collega i servizi allo stato: finestra con le dimensioni salvate,
  /// contenuto dell'icona, richieste "mostrati" dalle altre istanze,
  /// controllo periodico degli aggiornamenti. Da chiamare prima di runApp.
  Future<void> attach(AppState state) async {
    final w = window;
    if (w != null) {
      w
        ..trayAvailable = (() => tray != null)
        ..beforeQuit = dispose;
      try {
        await w.setup(
          saved: state.config.prefs['window'],
          screens: await _screens(),
          save: (b) => unawaited(state.setPref('window', b)),
          title: 'MineSync',
        );
      } on Object catch (e) {
        _log('impostazione della finestra non riuscita: $e');
      }
    }
    _trayStatus = TrayStatus(
      state,
      services.tray,
      onOpen: () => unawaited(services.window.show()),
      onQuit: () => unawaited(quit()),
    );
    _showSub = instance?.showRequests.listen((_) => unawaited(services.window.show()));
    final updates = services.updates;
    if (updates is HubUpdateService) updates.beforeRestart = dispose;
    if (updates is HubUpdateService && updates.managed) {
      void tick() {
        final hub = state.config.hub;
        if (hub != null && state.connection == Connection.online) {
          unawaited(updates.check(Uri.parse(hub)));
        }
      }

      _updateTimer = Timer(updateFirstCheck, () {
        tick();
        _updateTimer = Timer.periodic(updateEvery, (_) => tick());
      });
    }
  }

  /// Dopo il primo frame: marker "partita bene" per il launcher e, se
  /// avviata dal sistema, finestra nella barra di sistema. Durante la prova
  /// di una versione nuova la finestra resta visibile.
  Future<void> afterFirstFrame() async {
    await WidgetsBinding.instance.endOfFrame;
    try {
      await markHealthy(env);
    } on Object catch (e) {
      _log('marker di avvio non scritto: $e');
    }
    if (autostarted && tray != null && env['MINESYNC_TRIAL'] != '1') {
      await services.window.hide();
    }
  }

  /// Esce chiedendo prima conferma (stesso percorso della chiusura dal
  /// sistema); senza finestra vera esce e basta.
  Future<void> quit() async {
    final w = window;
    if (w != null) return w.requestQuit();
    await dispose();
    exit(0);
  }

  Future<void> dispose() async {
    _updateTimer?.cancel();
    _trayStatus?.dispose();
    await _showSub?.cancel();
    try {
      await tray?.dispose();
    } on Object {
      // icona già sparita
    }
    await instance?.dispose();
  }

  static Future<List<Rect>> _screens() async {
    try {
      return [
        for (final d in await screenRetriever.getAllDisplays())
          (d.visiblePosition ?? Offset.zero) & (d.visibleSize ?? d.size),
      ];
    } on Object {
      return const [];
    }
  }
}
