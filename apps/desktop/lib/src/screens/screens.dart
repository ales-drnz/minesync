// Indice delle schermate e scelta della schermata per la rotta corrente.
import 'package:flutter/widgets.dart';

import '../state/app_state.dart';
import 'first_run.dart';
import 'history.dart';
import 'home.dart';
import 'modpack.dart';
import 'new_server.dart';
import 'server.dart';
import 'session.dart';
import 'settings.dart';

export 'dialogs.dart';
export 'first_run.dart';
export 'history.dart';
export 'home.dart';
export 'modpack.dart';
export 'modpack_dialogs.dart';
export 'new_server.dart';
export 'server.dart';
export 'session.dart';
export 'settings.dart';

/// La schermata del contenuto per [r] (il primo avvio occupa tutta la finestra).
Widget screenFor(AppRoute r) => switch (r) {
  FirstRunRoute() => const FirstRunScreen(),
  HomeRoute() => const HomeScreen(),
  ServerRoute(:final space) || SessionRoute(:final space) => ServerOrSession(space: space),
  HistoryRoute(:final space) => HistoryScreen(space: space),
  ModpackRoute(:final space, :final client) => ModpackScreen(space: space, client: client),
  NewServerRoute() => const NewServerScreen(),
  SettingsRoute() => const SettingsScreen(),
};

/// La pagina di un server: la sessione quando la si ospita da questo PC,
/// altrimenti la panoramica (niente scheda "Sessione" vuota).
class ServerOrSession extends StatelessWidget {
  const ServerOrSession({super.key, required this.space});
  final String space;

  @override
  Widget build(BuildContext context) {
    final s = AppStateScope.of(context).session;
    return s != null && s.space == space ? SessionScreen(space: space) : ServerScreen(space: space);
  }
}
