// L'app: router, tema (chiaro/scuro/sistema) e lingua dallo stato, testi,
// notifiche a comparsa. Le pagine stanno dentro la cornice (shell/).
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:ms_ui/ms_ui.dart';

import 'l10n/l10n.dart';
import 'router.dart';
import 'shell/feedback.dart';
import 'state/hub_state.dart';

class HubWebApp extends StatefulWidget {
  const HubWebApp({super.key, required this.state, this.router});

  final HubState state;

  /// Router già costruito (test: percorso iniziale); di default il suo.
  final GoRouter? router;

  @override
  State<HubWebApp> createState() => _HubWebAppState();
}

class _HubWebAppState extends State<HubWebApp> {
  final toasts = MsToastController();
  GoRouter? _own;
  GoRouter get router => widget.router ?? (_own ??= buildRouter());

  @override
  void dispose() {
    toasts.dispose();
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HubStateScope(
    state: widget.state,
    child: ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final strings = WebStrings(widget.state.lang);
        return WidgetsApp.router(
          routerConfig: router,
          title: widget.state.hub?.name ?? 'MineSync',
          color: pratoDark.accent,
          debugShowCheckedModeBanner: false,
          builder: (context, child) {
            final theme = widget.state.themeFor(MediaQuery.platformBrightnessOf(context));
            return WebStringsScope(
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
            );
          },
        );
      },
    ),
  );
}
