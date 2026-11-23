// L'app: tema e lingua dalle preferenze, testi, notifiche a comparsa e la
// cornice con la schermata corrente.
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:ms_ui/ms_ui.dart';

import 'dialogs/app_dialogs.dart';
import 'l10n/l10n.dart';
import 'platform/platform.dart';
import 'shell/shell.dart';
import 'state/app_state.dart';

class MinesyncApp extends StatefulWidget {
  const MinesyncApp({super.key, required this.state, required this.platform, this.os});

  final AppState state;
  final PlatformServices platform;

  /// Aspetto della barra del titolo (test e anteprime).
  final MsTitlebarOs? os;

  @override
  State<MinesyncApp> createState() => _MinesyncAppState();
}

class _MinesyncAppState extends State<MinesyncApp> {
  final toasts = MsToastController();
  final _navigator = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    // chiusura dal sistema o da "Esci" nella barra di sistema: con una
    // sessione in corso prima si ferma il server e si salva sull'hub
    widget.platform.window.onCloseRequested = () async {
      final ctx = _navigator.currentContext;
      if (ctx == null) return true;
      return confirmQuit(ctx, onFinishedInBackground: () => exit(0));
    };
  }

  @override
  void dispose() {
    widget.platform.window.onCloseRequested = null;
    toasts.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppStateScope(
    state: widget.state,
    child: ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final theme = widget.state.theme;
        final strings = AppStrings(widget.state.lang);
        return WidgetsApp(
          navigatorKey: _navigator,
          title: 'MineSync',
          color: theme.colors.accent,
          debugShowCheckedModeBanner: false,
          pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
            settings: settings,
            transitionDuration: Duration.zero,
            pageBuilder: (context, _, _) => builder(context),
          ),
          builder: (context, child) => AppStringsScope(
            strings: strings,
            child: MsTheme(
              data: theme,
              child: ToastScope(
                controller: toasts,
                child: MsToastHost(
                  controller: toasts,
                  closeLabel: strings.shell.close,
                  child: child!,
                ),
              ),
            ),
          ),
          home: Shell(platform: widget.platform, os: widget.os),
        );
      },
    ),
  );
}

/// Accesso al controller delle notifiche a comparsa.
class ToastScope extends InheritedWidget {
  const ToastScope({super.key, required this.controller, required super.child});
  final MsToastController controller;

  static MsToastController of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ToastScope>()!.controller;

  @override
  bool updateShouldNotify(ToastScope old) => old.controller != controller;
}
