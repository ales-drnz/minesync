// Testi dell'app in italiano e inglese, divisi per area: ogni area è una
// classe astratta con le due implementazioni, così una lingua a cui manca
// un testo non compila. Le aree si aggiungono qui sotto.
import 'package:flutter/widgets.dart';
import 'package:ms_l10n/ms_l10n.dart';

import 'dialogs_strings.dart';
import 'first_run_strings.dart';
import 'format_strings.dart';
import 'history_strings.dart';
import 'home_strings.dart';
import 'modpack_strings.dart';
import 'new_server_strings.dart';
import 'pack_browser_strings.dart';
import 'server_strings.dart';
import 'session_strings.dart';
import 'settings_strings.dart';
import 'shell_strings.dart';

export 'package:ms_l10n/ms_l10n.dart' show Lang, Strings;
export 'dialogs_strings.dart';
export 'first_run_strings.dart';
export 'format_strings.dart';
export 'history_strings.dart';
export 'home_strings.dart';
export 'modpack_strings.dart';
export 'new_server_strings.dart';
export 'pack_browser_strings.dart';
export 'server_strings.dart';
export 'session_strings.dart';
export 'settings_strings.dart';
export 'shell_strings.dart';

/// Tutti i testi dell'app in una lingua.
final class AppStrings {
  AppStrings(this.lang)
    : common = Strings.of(lang),
      shell = ShellStrings.of(lang),
      fmt = FormatStrings.of(lang),
      firstRun = FirstRunStrings.of(lang),
      home = HomeStrings.of(lang),
      server = ServerStrings.of(lang),
      history = HistoryStrings.of(lang),
      session = SessionStrings.of(lang),
      settings = SettingsStrings.of(lang),
      dialogs = DialogsStrings.of(lang),
      modpack = ModpackStrings.of(lang),
      newServer = NewServerStrings.of(lang),
      packBrowser = PackBrowserStrings.of(lang);

  final Lang lang;

  /// Testi condivisi con CLI e hub (errori del sync…).
  final Strings common;
  final ShellStrings shell;

  /// Formati di dimensioni, durate e date.
  final FormatStrings fmt;
  final FirstRunStrings firstRun;
  final HomeStrings home;

  /// Dettaglio di un server (anche etichette comuni a Home e Storia).
  final ServerStrings server;
  final HistoryStrings history;

  final SessionStrings session;
  final SettingsStrings settings;
  final DialogsStrings dialogs;

  /// Scheda Mod, dialoghi del modpack e pacchetto per i giocatori.
  final ModpackStrings modpack;

  /// Procedura «Nuovo server».
  final NewServerStrings newServer;

  /// Catalogo dei modpack di Modrinth nella procedura «Nuovo server».
  final PackBrowserStrings packBrowser;
}

/// Fornisce i testi ai widget.
class AppStringsScope extends InheritedWidget {
  const AppStringsScope({super.key, required this.strings, required super.child});

  final AppStrings strings;

  static AppStrings of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppStringsScope>()!.strings;

  @override
  bool updateShouldNotify(AppStringsScope old) => old.strings.lang != strings.lang;
}

extension AppStringsContext on BuildContext {
  /// I testi dell'app nella lingua corrente.
  AppStrings get s => AppStringsScope.of(this);
}
