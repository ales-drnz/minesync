// Testi della storia di un server: elenco delle versioni, dettaglio con le
// differenze e ripristino.
import 'package:ms_l10n/ms_l10n.dart';

import 'format_strings.dart';

abstract final class HistoryStrings {
  static HistoryStrings of(Lang l) => switch (l) {
    Lang.it => const _It(),
    Lang.en => const _En(),
  };

  String title(String name);
  String get intro;
  String get versions;
  String count(int n);
  String get filterLabel;
  String get all;
  String get sessions;
  String get restores;
  String get searchLabel;
  String get searchPlaceholder;
  String listLabel(String name);
  String get showOlder;
  String get loading;
  String get noMatch;
  String get empty;
  String get loadError;
  String get retry;

  String get detailTitle;
  String get prev;
  String get prevTip;
  String get next;
  String get nextTip;
  String get size;
  String filesN(int n);
  String fromN(int n);
  String get firstVersion;
  String diffLabel(int n);
  String get added;
  String get changed;
  String get removed;
  String andMore(int n);
  String get noFiles;
  String get diffError;
  String restoreQuestion(String name);
  String restoreButton(int n);

  String restoreTitle(int n);
  Rich restoreBody({required int n, required int next, required int head, required String who});
  String get nextPlayer;
  String get nextPlayerValue;
  String lockFree(String name);
  String lockBusy(String name, String who);
  String restoreConfirm(int next);
  String restored(int n, int next);
  String get restoreFailed;
}

final class _It implements HistoryStrings {
  const _It();
  @override
  String title(String name) => 'Storia di $name';
  @override
  String get intro => 'Puoi tornare a qualsiasi versione senza perdere le altre.';
  @override
  String get versions => 'Versioni';
  @override
  String count(int n) => n == 1 ? '1 versione' : '$n versioni';
  @override
  String get filterLabel => 'Mostra';
  @override
  String get all => 'Tutte';
  @override
  String get sessions => 'Salvataggi';
  @override
  String get restores => 'Ripristini';
  @override
  String get searchLabel => 'Cerca nella storia';
  @override
  String get searchPlaceholder => 'Cerca per autore o messaggio';
  @override
  String listLabel(String name) => 'Versioni di $name';
  @override
  String get showOlder => 'Mostra le più vecchie';
  @override
  String get loading => 'Caricamento della storia…';
  @override
  String get noMatch => 'Nessuna versione corrisponde.';
  @override
  String get empty => 'Ancora nessuna versione.';
  @override
  String get loadError => 'Impossibile leggere la storia dall\'hub.';
  @override
  String get retry => 'Riprova';

  @override
  String get detailTitle => 'Versione';
  @override
  String get prev => 'Versione precedente';
  @override
  String get prevTip => 'Precedente';
  @override
  String get next => 'Versione successiva';
  @override
  String get nextTip => 'Successiva';
  @override
  String get size => 'Dimensione';
  @override
  String filesN(int n) => '$n file';
  @override
  String fromN(int n) => 'parte da #$n';
  @override
  String get firstVersion => 'prima versione';
  @override
  String diffLabel(int n) => 'Differenze con la #$n';
  @override
  String get added => 'Aggiunti';
  @override
  String get changed => 'Modificati';
  @override
  String get removed => 'Rimossi';
  @override
  String andMore(int n) => n == 1 ? 'e un altro file' : 'e altri $n file';
  @override
  String get noFiles => 'Nessun file.';
  @override
  String get diffError => 'Impossibile leggere le differenze di questa versione.';
  @override
  String restoreQuestion(String name) => 'Riportare $name a questa versione?';
  @override
  String restoreButton(int n) => 'Ripristina #$n…';

  @override
  String restoreTitle(int n) => 'Ripristinare la #$n?';
  @override
  Rich restoreBody({required int n, required int next, required int head, required String who}) => [
    ('Viene creata una nuova versione ', false),
    ('#$next', true),
    (' uguale alla #$n di $who. ', false),
    ('Nessuna versione va persa', true),
    (': la #$head resta nella storia e si può ripristinare in qualsiasi momento.', false),
  ];
  @override
  String get nextPlayer => 'Chi gioca dopo';
  @override
  String get nextPlayerValue => 'riparte da qui';
  @override
  String lockFree(String name) => 'Possibile solo quando nessuno gioca. Ora $name è libero.';
  @override
  String lockBusy(String name, String who) =>
      'Possibile solo quando nessuno gioca. Ora su $name c\'è $who.';
  @override
  String restoreConfirm(int next) => 'Ripristina come #$next';
  @override
  String restored(int n, int next) => '#$n ripristinata come #$next';
  @override
  String get restoreFailed => 'Ripristino non riuscito';
}

final class _En implements HistoryStrings {
  const _En();
  @override
  String title(String name) => '$name history';
  @override
  String get intro => 'Go back to any version without losing the others.';
  @override
  String get versions => 'Versions';
  @override
  String count(int n) => n == 1 ? '1 version' : '$n versions';
  @override
  String get filterLabel => 'Show';
  @override
  String get all => 'All';
  @override
  String get sessions => 'Saves';
  @override
  String get restores => 'Restores';
  @override
  String get searchLabel => 'Search the history';
  @override
  String get searchPlaceholder => 'Search by author or message';
  @override
  String listLabel(String name) => '$name versions';
  @override
  String get showOlder => 'Show older';
  @override
  String get loading => 'Loading history…';
  @override
  String get noMatch => 'No version matches.';
  @override
  String get empty => 'No versions yet.';
  @override
  String get loadError => 'Unable to read the history from the hub.';
  @override
  String get retry => 'Try again';

  @override
  String get detailTitle => 'Version';
  @override
  String get prev => 'Previous version';
  @override
  String get prevTip => 'Previous';
  @override
  String get next => 'Next version';
  @override
  String get nextTip => 'Next';
  @override
  String get size => 'Size';
  @override
  String filesN(int n) => n == 1 ? '1 file' : '$n files';
  @override
  String fromN(int n) => 'based on #$n';
  @override
  String get firstVersion => 'first version';
  @override
  String diffLabel(int n) => 'Differences from #$n';
  @override
  String get added => 'Added';
  @override
  String get changed => 'Changed';
  @override
  String get removed => 'Removed';
  @override
  String andMore(int n) => n == 1 ? 'and 1 more file' : 'and $n more files';
  @override
  String get noFiles => 'No files.';
  @override
  String get diffError => 'Unable to read the differences for this version.';
  @override
  String restoreQuestion(String name) => 'Restore $name to this version?';
  @override
  String restoreButton(int n) => 'Restore #$n…';

  @override
  String restoreTitle(int n) => 'Restore #$n?';
  @override
  Rich restoreBody({required int n, required int next, required int head, required String who}) => [
    ('This creates a new version ', false),
    ('#$next', true),
    (' identical to #$n by $who. ', false),
    ('No version is lost', true),
    (': #$head stays in the history and can be restored at any time.', false),
  ];
  @override
  String get nextPlayer => 'Whoever plays next';
  @override
  String get nextPlayerValue => 'starts from here';
  @override
  String lockFree(String name) => 'Only possible when nobody is playing. $name is free now.';
  @override
  String lockBusy(String name, String who) =>
      'Only possible when nobody is playing. $who is on $name now.';
  @override
  String restoreConfirm(int next) => 'Restore as #$next';
  @override
  String restored(int n, int next) => '#$n restored as #$next';
  @override
  String get restoreFailed => 'Restore failed';
}
