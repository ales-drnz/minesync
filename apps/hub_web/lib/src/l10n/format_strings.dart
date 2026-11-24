// Formati comuni alle pagine: dimensioni, velocità, durate, date relative.
// Separati dai testi delle aree perché li usano tutte. Stesse regole
// dell'app desktop (apps/desktop/lib/src/l10n/format_strings.dart), così
// web e app mostrano gli stessi numeri.
import 'package:ms_l10n/ms_l10n.dart';

/// Testo con parti in grassetto: (testo, grassetto).
typedef Rich = List<(String, bool)>;

abstract final class FormatStrings {
  const FormatStrings();

  static FormatStrings of(Lang l) => switch (l) {
    Lang.it => const _It(),
    Lang.en => const _En(),
  };

  /// Separatore decimale.
  String get _dec;

  /// Dimensione leggibile: 4 KB, 38 MB, 3,4 GB.
  String size(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    if (i == 0) return '$bytes B';
    final t = v < 10 ? v.toStringAsFixed(1) : v.toStringAsFixed(0);
    return '${t.replaceAll('.', _dec)} ${units[i]}';
  }

  /// Velocità: 3,1 MB/s.
  String speed(double bytesPerSecond) => '${size(bytesPerSecond.round())}/s';

  /// Percentuale intera.
  String percent(double fraction) => '${(fraction * 100).floor()}%';

  /// Percentuale intera con lo spazio, come nelle frasi: "91 %".
  String percentSpaced(double fraction) => '${(fraction * 100).floor()} %';

  /// Numero di generazione: #41.
  String gen(int n) => '#$n';

  /// Elenco di nomi: "alice, bob e carol".
  String names(List<String> n);

  /// Durata breve: 40 s, 4 min, 1 h 12 min.
  String duration(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds.clamp(0, 59)} s';
    if (d.inMinutes < 60) return '${d.inMinutes} min';
    final m = d.inMinutes % 60;
    return m == 0 ? '${d.inHours} h' : '${d.inHours} h ${m.toString().padLeft(2, '0')} min';
  }

  /// Ora del giorno: 18:42.
  String clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// Ora del giorno con il giorno se non è oggi, da mettere dopo «alle» o
  /// «dalle»: "18:42", "18:42 di ieri", "18:42 di lunedì", "18:42 del 3 nov".
  String clockOn(DateTime t, DateTime now) {
    final d = _days(t, now);
    return d == 0 ? clock(t) : '${clock(t)} ${_onDay(t, d)}';
  }

  /// Il giorno di [t] ([days] giorni fa, mai 0) in coda a un'ora.
  String _onDay(DateTime t, int days);

  /// Quanto tempo fa, breve: "12 min fa", "ieri 21:40", "lun 22:15", "3 nov".
  String ago(DateTime t, DateTime now);

  /// Quando, per le liste: "oggi 18:37", "ieri 23:10", "lun 22:15", "3 nov 18:02".
  String when(DateTime t, DateTime now);

  /// Quando, in una frase: "oggi alle 18:37", "ieri alle 23:10".
  String whenLong(DateTime t, DateTime now);

  /// Ora per il registro attività: l'ora se è di oggi, altrimenti il giorno.
  String eventTime(DateTime t, DateTime now) {
    final days = _days(t, now);
    if (days == 0) return clock(t);
    return _day(t, now);
  }

  /// Giorno breve: "ieri", "lun", "3 nov".
  String _day(DateTime t, DateTime now);

  static int _days(DateTime t, DateTime now) =>
      DateTime(now.year, now.month, now.day).difference(DateTime(t.year, t.month, t.day)).inDays;
}

final class _It extends FormatStrings {
  const _It();
  @override
  String get _dec => ',';

  @override
  String names(List<String> n) =>
      n.length < 2 ? n.join() : '${n.sublist(0, n.length - 1).join(', ')} e ${n.last}';

  static const _wd = ['lun', 'mar', 'mer', 'gio', 'ven', 'sab', 'dom'];
  static const _mo = [
    'gen', 'feb', 'mar', 'apr', 'mag', 'giu', 'lug', 'ago', 'set', 'ott', 'nov', 'dic', //
  ];

  @override
  String _day(DateTime t, DateTime now) {
    final d = FormatStrings._days(t, now);
    if (d == 1) return 'ieri';
    if (d > 1 && d < 7) return _wd[t.weekday - 1];
    return '${t.day} ${_mo[t.month - 1]}';
  }

  static const _wdLong = [
    'lunedì', 'martedì', 'mercoledì', 'giovedì', 'venerdì', 'sabato', 'domenica', //
  ];

  @override
  String _onDay(DateTime t, int days) {
    if (days == 1) return 'di ieri';
    if (days > 1 && days < 7) return 'di ${_wdLong[t.weekday - 1]}';
    // dell'1, dell'8, dell'11
    final art = t.day == 1 || t.day == 8 || t.day == 11 ? "dell'" : 'del ';
    return '$art${t.day} ${_mo[t.month - 1]}';
  }

  @override
  String ago(DateTime t, DateTime now) {
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return 'ora';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min fa';
    if (FormatStrings._days(t, now) == 0) return '${diff.inHours} h fa';
    return '${_day(t, now)} ${clock(t)}';
  }

  @override
  String when(DateTime t, DateTime now) =>
      FormatStrings._days(t, now) == 0 ? 'oggi ${clock(t)}' : '${_day(t, now)} ${clock(t)}';

  @override
  String whenLong(DateTime t, DateTime now) {
    final d = FormatStrings._days(t, now);
    if (d == 0) return 'oggi alle ${clock(t)}';
    if (d == 1) return 'ieri alle ${clock(t)}';
    return '${_day(t, now)} alle ${clock(t)}';
  }
}

final class _En extends FormatStrings {
  const _En();
  @override
  String get _dec => '.';

  @override
  String names(List<String> n) =>
      n.length < 2 ? n.join() : '${n.sublist(0, n.length - 1).join(', ')} and ${n.last}';

  static const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _mo = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec', //
  ];

  @override
  String _day(DateTime t, DateTime now) {
    final d = FormatStrings._days(t, now);
    if (d == 1) return 'yesterday';
    if (d > 1 && d < 7) return _wd[t.weekday - 1];
    return '${t.day} ${_mo[t.month - 1]}';
  }

  static const _wdLong = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday', //
  ];

  @override
  String _onDay(DateTime t, int days) {
    if (days == 1) return 'yesterday';
    if (days > 1 && days < 7) return 'on ${_wdLong[t.weekday - 1]}';
    return 'on ${t.day} ${_mo[t.month - 1]}';
  }

  @override
  String ago(DateTime t, DateTime now) {
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (FormatStrings._days(t, now) == 0) return '${diff.inHours} h ago';
    return '${_day(t, now)} ${clock(t)}';
  }

  @override
  String when(DateTime t, DateTime now) =>
      FormatStrings._days(t, now) == 0 ? 'today ${clock(t)}' : '${_day(t, now)} ${clock(t)}';

  @override
  String whenLong(DateTime t, DateTime now) {
    final d = FormatStrings._days(t, now);
    if (d == 0) return 'today at ${clock(t)}';
    if (d == 1) return 'yesterday at ${clock(t)}';
    return '${_day(t, now)} at ${clock(t)}';
  }
}
