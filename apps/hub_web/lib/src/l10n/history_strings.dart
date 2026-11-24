// Testi della scheda Storia di un server: elenco delle generazioni, filtri,
// differenze, file danneggiati, conferme di ripristino ed eliminazione.
import 'package:ms_l10n/ms_l10n.dart';
import 'package:ms_protocol/ms_protocol.dart';

abstract final class HistoryStrings {
  static HistoryStrings of(Lang l) => switch (l) {
    Lang.it => const _It(),
    Lang.en => const _En(),
  };

  // elenco
  String title(GenerationSummary g);
  String count(int n);
  String lead(String logical, String referenced);
  String get search;

  /// La versione attuale (la testa), come nell'app.
  String get current;
  String get searchLabel;
  String get filterLabel;
  String get filterAll;
  String get filterSaves;
  String get filterRestores;
  String get filterDamaged;
  List<String> rules(HistorySettings h);
  String retention(HistorySettings h);
  String get changeRules;
  String listLabel(String server);
  String rowLabel(String n);
  String restoreOf(String gen);
  String fileRestoreOf(String path, String gen);
  String damagedCount(int n, bool regions);
  String files(String n);
  String get sizeBar;
  String get zip;
  String zipOf(String n);
  String get restore;
  String restoreLabel(String n);
  String deleteLabel(String n);
  String showDiff(String n);
  String hideDiff(String n);
  String loadMore(int? remaining);
  String get emptyTitle;
  String get emptyText;

  // differenze
  String diffWith(String gen);
  String get diffWithEmpty;
  String diffLimit(int n);
  String get diffError;
  String get added;
  String get changed;
  String get removed;
  String get noneAdded;
  String get noneChanged;
  String get noneRemoved;
  String shownOf(String shown, String total);
  String get allShown;
  String damagedTitle(int n);
  String get damagedText;
  String get colFile;
  String get colChunks;
  String get colIntact;
  String get colAction;
  String chunksOf(String bad, String total);
  String get noIntact;
  String get needsAdmin;
  String get restoreIntact;
  String restoreIntactLabel(String path, String gen);

  // conferme e risultati
  String restoreTitle(String gen);
  String get restoreBody1;
  String restoreBody2(String who, String when);
  String restoreBody3(String kept);
  String rangeKept(String from, String to);
  String oneKept(String gen);
  String get nextPlayer;
  String startsFrom(String gen);
  String get notNowTitle;
  String notNowText(String who, String server, String what);
  String get restoreWhat;
  String get restoreFileWhat;
  String restored(String from, String to);
  String deleteTitle(String gen);
  String get irreversible;
  String get deleteBody1;
  String deleteBody2(String who);
  String deleteConfirm(String gen);
  String deleted(String gen);
  String freedText(String size);
  String get restoreFileTitle;
  String restoreFileBody(String from, String head, String next);
  String get restoreFileConfirm;
  String fileRestored(String path);
  String newGen(String gen);
}

final class _It implements HistoryStrings {
  const _It();
  @override
  String title(GenerationSummary g) => g.message.isNotEmpty
      ? Strings.of(Lang.it).autoMessage(g.message) ?? g.message
      : switch (g.kind) {
          GenerationKind.autosave => 'Salvataggio automatico',
          GenerationKind.push => 'Salvataggio',
          GenerationKind.restore => g.restoredPath == null ? 'Ripristino' : 'Ripristino di un file',
        };
  @override
  String count(int n) => n == 1 ? '1 versione' : '$n versioni';
  @override
  String lead(String logical, String referenced) =>
      "$logical in totale, $referenced occupati sull'hub (i file identici sono salvati una sola volta)";
  @override
  String get search => 'Cerca per messaggio, autore, #N';
  @override
  String get current => 'Attuale';
  @override
  String get searchLabel => 'Cerca nella storia';
  @override
  String get filterLabel => 'Filtro';
  @override
  String get filterAll => 'Tutte';
  @override
  String get filterSaves => 'Salvataggi';
  @override
  String get filterRestores => 'Ripristini';
  @override
  String get filterDamaged => 'Con problemi';
  @override
  List<String> rules(HistorySettings h) => [
    'sempre le ultime ${h.keepLast} versioni',
    if (h.keepHours > 0) 'tutte quelle delle ultime ${h.keepHours} ore',
    if (h.keepDays > 0) 'poi una al giorno per ${h.keepDays} giorni',
  ];
  @override
  String retention(HistorySettings h) =>
      'Conservazione: ${rules(h).join(', ')}. Le più vecchie vengono eliminate alla pulizia.';
  @override
  String get changeRules => 'Modifica le regole';
  @override
  String listLabel(String server) => 'Versioni di $server';
  @override
  String rowLabel(String n) => 'Versione $n';
  @override
  String restoreOf(String gen) => 'ripristino di $gen';
  @override
  String fileRestoreOf(String path, String gen) => '$path da $gen';
  @override
  String damagedCount(int n, bool regions) => regions
      ? (n == 1 ? '1 region danneggiato' : '$n region danneggiati')
      : (n == 1 ? '1 file danneggiato' : '$n file danneggiati');
  @override
  String files(String n) => '$n file';
  @override
  String get sizeBar => 'Dimensione rispetto alla più grande';
  @override
  String get zip => 'Zip';
  @override
  String zipOf(String n) => 'Scarica lo zip di $n';
  @override
  String get restore => 'Ripristina';
  @override
  String restoreLabel(String n) => 'Ripristina $n';
  @override
  String deleteLabel(String n) => 'Elimina la versione $n';
  @override
  String showDiff(String n) => 'Mostra le differenze di $n';
  @override
  String hideDiff(String n) => 'Nascondi le differenze di $n';
  @override
  String loadMore(int? remaining) => remaining == null || remaining <= 0
      ? 'Carica le precedenti'
      : 'Carica le precedenti ($remaining)';
  @override
  String get emptyTitle => 'Nessuna versione';
  @override
  String get emptyText => "Il primo salvataggio dall'app crea la #1.";
  @override
  String diffWith(String gen) => 'Differenze con $gen';
  @override
  String get diffWithEmpty => 'Differenze con il mondo vuoto';
  @override
  String diffLimit(int n) => 'fino a $n file per gruppo';
  @override
  String get diffError => 'Impossibile leggere le differenze';
  @override
  String get added => 'Aggiunti';
  @override
  String get changed => 'Modificati';
  @override
  String get removed => 'Rimossi';
  @override
  String get noneAdded => 'Nessun file aggiunto';
  @override
  String get noneChanged => 'Nessun file modificato';
  @override
  String get noneRemoved => 'Nessun file rimosso';
  @override
  String shownOf(String shown, String total) => 'mostrati $shown di $total';
  @override
  String get allShown => 'tutti';
  @override
  String damagedTitle(int n) =>
      n == 1 ? '1 file danneggiato in questa versione' : '$n file danneggiati in questa versione';
  @override
  String get damagedText =>
      'Alcuni chunk non sono più leggibili. Si possono ripristinare solo questi file dall\'ultima versione in cui erano integri: il resto del mondo non cambia e viene creata una nuova versione.';
  @override
  String get colFile => 'File';
  @override
  String get colChunks => 'Chunk illeggibili';
  @override
  String get colIntact => 'Ultima integra';
  @override
  String get colAction => 'Azione';
  @override
  String chunksOf(String bad, String total) => '$bad su $total';
  @override
  String get noIntact => 'nessuna';
  @override
  String get needsAdmin => 'richiede un admin';
  @override
  String get restoreIntact => 'Ripristina integro';
  @override
  String restoreIntactLabel(String path, String gen) => 'Ripristina $path da $gen';
  @override
  String restoreTitle(String gen) => 'Ripristinare $gen?';
  @override
  String get restoreBody1 => 'Lo stato di ';
  @override
  String restoreBody2(String who, String when) => ' ($who, $when) diventa la nuova versione ';
  @override
  String restoreBody3(String kept) => '. Nessun dato si perde: $kept.';
  @override
  String rangeKept(String from, String to) => '$from–$to restano nella storia';
  @override
  String oneKept(String gen) => '$gen resta nella storia';
  @override
  String get nextPlayer => 'Chi gioca dopo';
  @override
  String startsFrom(String gen) => 'riparte da $gen';
  @override
  String get notNowTitle => 'Operazione non disponibile';
  @override
  String notNowText(String who, String server, String what) =>
      '$who sta giocando su $server. $what è possibile quando il lock è libero.';
  @override
  String get restoreWhat => 'Il ripristino';
  @override
  String get restoreFileWhat => 'Il ripristino di un file';
  @override
  String restored(String from, String to) => '$from ripristinata come $to';
  @override
  String deleteTitle(String gen) => 'Eliminare $gen?';
  @override
  String get irreversible => 'Irreversibile';
  @override
  String get deleteBody1 => 'La versione ';
  @override
  String deleteBody2(String who) =>
      ' di $who viene rimossa dalla storia. I file condivisi con altre versioni restano; si liberano circa ';
  @override
  String deleteConfirm(String gen) => 'Elimina $gen';
  @override
  String deleted(String gen) => '$gen eliminata';
  @override
  String freedText(String size) => 'Liberati $size';
  @override
  String get restoreFileTitle => 'Ripristinare il file integro?';
  @override
  String restoreFileBody(String from, String head, String next) =>
      'Viene creata la versione $next: uguale alla $head, con solo questo file ripreso dalla $from. Il resto del mondo non cambia.';
  @override
  String get restoreFileConfirm => 'Ripristina il file';
  @override
  String fileRestored(String path) => '$path ripristinato';
  @override
  String newGen(String gen) => 'Nuova versione $gen';
}

final class _En implements HistoryStrings {
  const _En();
  @override
  String title(GenerationSummary g) => g.message.isNotEmpty
      ? Strings.of(Lang.en).autoMessage(g.message) ?? g.message
      : switch (g.kind) {
          GenerationKind.autosave => 'Autosave',
          GenerationKind.push => 'Save',
          GenerationKind.restore => g.restoredPath == null ? 'Restore' : 'File restore',
        };
  @override
  String count(int n) => n == 1 ? '1 version' : '$n versions';
  @override
  String lead(String logical, String referenced) =>
      '$logical in total, $referenced used on the hub (identical files are stored once)';
  @override
  String get search => 'Search by message, author, #N';
  @override
  String get current => 'Current';
  @override
  String get searchLabel => 'Search the history';
  @override
  String get filterLabel => 'Filter';
  @override
  String get filterAll => 'All';
  @override
  String get filterSaves => 'Saves';
  @override
  String get filterRestores => 'Restores';
  @override
  String get filterDamaged => 'With problems';
  @override
  List<String> rules(HistorySettings h) => [
    'always the last ${h.keepLast} versions',
    if (h.keepHours > 0) 'all those of the last ${h.keepHours} hours',
    if (h.keepDays > 0) 'then one a day for ${h.keepDays} days',
  ];
  @override
  String retention(HistorySettings h) =>
      'Retention: ${rules(h).join(', ')}. Older ones are deleted at cleanup.';
  @override
  String get changeRules => 'Change rules';
  @override
  String listLabel(String server) => '$server versions';
  @override
  String rowLabel(String n) => 'Version $n';
  @override
  String restoreOf(String gen) => 'restore of $gen';
  @override
  String fileRestoreOf(String path, String gen) => '$path from $gen';
  @override
  String damagedCount(int n, bool regions) => regions
      ? (n == 1 ? '1 damaged region' : '$n damaged regions')
      : (n == 1 ? '1 damaged file' : '$n damaged files');
  @override
  String files(String n) => '$n files';
  @override
  String get sizeBar => 'Size compared with the largest';
  @override
  String get zip => 'Zip';
  @override
  String zipOf(String n) => 'Download the zip of $n';
  @override
  String get restore => 'Restore';
  @override
  String restoreLabel(String n) => 'Restore $n';
  @override
  String deleteLabel(String n) => 'Delete version $n';
  @override
  String showDiff(String n) => 'Show the changes of $n';
  @override
  String hideDiff(String n) => 'Hide the changes of $n';
  @override
  String loadMore(int? remaining) =>
      remaining == null || remaining <= 0 ? 'Load older' : 'Load older ($remaining)';
  @override
  String get emptyTitle => 'No versions yet';
  @override
  String get emptyText => 'The first save from the app creates #1.';
  @override
  String diffWith(String gen) => 'Changes from $gen';
  @override
  String get diffWithEmpty => 'Changes from the empty world';
  @override
  String diffLimit(int n) => 'up to $n files per group';
  @override
  String get diffError => 'Unable to read the changes';
  @override
  String get added => 'Added';
  @override
  String get changed => 'Changed';
  @override
  String get removed => 'Removed';
  @override
  String get noneAdded => 'No file added';
  @override
  String get noneChanged => 'No file changed';
  @override
  String get noneRemoved => 'No file removed';
  @override
  String shownOf(String shown, String total) => 'showing $shown of $total';
  @override
  String get allShown => 'all';
  @override
  String damagedTitle(int n) =>
      n == 1 ? '1 damaged file in this version' : '$n damaged files in this version';
  @override
  String get damagedText =>
      'Some chunks are no longer readable. Only these files can be restored from the last version in which they were intact: the rest of the world does not change and a new version is created.';
  @override
  String get colFile => 'File';
  @override
  String get colChunks => 'Unreadable chunks';
  @override
  String get colIntact => 'Last intact';
  @override
  String get colAction => 'Action';
  @override
  String chunksOf(String bad, String total) => '$bad of $total';
  @override
  String get noIntact => 'none';
  @override
  String get needsAdmin => 'requires an admin';
  @override
  String get restoreIntact => 'Restore intact';
  @override
  String restoreIntactLabel(String path, String gen) => 'Restore $path from $gen';
  @override
  String restoreTitle(String gen) => 'Restore $gen?';
  @override
  String get restoreBody1 => 'The state of ';
  @override
  String restoreBody2(String who, String when) => ' ($who, $when) becomes the new version ';
  @override
  String restoreBody3(String kept) => '. No data is lost: $kept.';
  @override
  String rangeKept(String from, String to) => '$from–$to stay in the history';
  @override
  String oneKept(String gen) => '$gen stays in the history';
  @override
  String get nextPlayer => 'Whoever plays next';
  @override
  String startsFrom(String gen) => 'starts from $gen';
  @override
  String get notNowTitle => 'Not available now';
  @override
  String notNowText(String who, String server, String what) =>
      '$who is playing on $server. $what is possible when the lock is free.';
  @override
  String get restoreWhat => 'Restoring';
  @override
  String get restoreFileWhat => 'Restoring a file';
  @override
  String restored(String from, String to) => '$from restored as $to';
  @override
  String deleteTitle(String gen) => 'Delete $gen?';
  @override
  String get irreversible => 'Irreversible';
  @override
  String get deleteBody1 => 'Version ';
  @override
  String deleteBody2(String who) =>
      ' by $who is removed from the history. Files shared with other versions stay; this frees about ';
  @override
  String deleteConfirm(String gen) => 'Delete $gen';
  @override
  String deleted(String gen) => '$gen deleted';
  @override
  String freedText(String size) => '$size freed';
  @override
  String get restoreFileTitle => 'Restore the intact file?';
  @override
  String restoreFileBody(String from, String head, String next) =>
      'Version $next is created: the same as $head, with only this file taken from $from. The rest of the world does not change.';
  @override
  String get restoreFileConfirm => 'Restore the file';
  @override
  String fileRestored(String path) => '$path restored';
  @override
  String newGen(String gen) => 'New version $gen';
}
