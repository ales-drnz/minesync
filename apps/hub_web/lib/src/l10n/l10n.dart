// Testi della web UI in italiano e inglese, divisi per area come nell'app
// desktop: ogni area è una classe astratta con le due implementazioni, così
// una lingua a cui manca un testo non compila. Per un'area nuova: un file
// <area>_strings.dart, un campo qui sotto, un export.
import 'package:flutter/widgets.dart';
import 'package:ms_l10n/ms_l10n.dart';

import 'admin_strings.dart';
import 'common_strings.dart';
import 'download_strings.dart';
import 'event_strings.dart';
import 'format_strings.dart';
import 'overview_strings.dart';
import 'pack_strings.dart';
import 'server_strings.dart';
import 'shell_strings.dart';

export 'package:ms_l10n/ms_l10n.dart' show Lang, Strings;
export 'admin_strings.dart';
export 'common_strings.dart';
export 'download_strings.dart';
export 'event_strings.dart';
export 'format_strings.dart';
export 'overview_strings.dart';
export 'pack_strings.dart';
export 'server_strings.dart';
export 'shell_strings.dart';

/// Tutti i testi della web UI in una lingua.
final class WebStrings {
  WebStrings(this.lang)
    : sync = Strings.of(lang),
      common = CommonStrings.of(lang),
      fmt = FormatStrings.of(lang),
      shell = ShellStrings.of(lang),
      events = EventStrings.of(lang),
      overview = OverviewStrings.of(lang),
      download = DownloadStrings.of(lang),
      server = ServerStrings.of(lang),
      admin = AdminStrings.of(lang),
      pack = PackStrings.of(lang);

  final Lang lang;

  /// Testi condivisi con app e CLI (ms_l10n).
  final Strings sync;

  /// Errori dell'hub, azioni comuni.
  final CommonStrings common;

  /// Dimensioni, durate, date.
  final FormatStrings fmt;
  final ShellStrings shell;

  /// Eventi dell'hub (Attività, Storia).
  final EventStrings events;
  final OverviewStrings overview;
  final DownloadStrings download;
  final ServerStrings server;
  final AdminStrings admin;

  /// Pacchetto per i giocatori (scheda Mod).
  final PackStrings pack;
}

/// Fornisce i testi ai widget.
class WebStringsScope extends InheritedWidget {
  const WebStringsScope({super.key, required this.strings, required super.child});

  final WebStrings strings;

  static WebStrings of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WebStringsScope>()!.strings;

  @override
  bool updateShouldNotify(WebStringsScope old) => old.strings.lang != strings.lang;
}

extension WebStringsContext on BuildContext {
  /// I testi nella lingua corrente.
  WebStrings get s => WebStringsScope.of(this);
}
