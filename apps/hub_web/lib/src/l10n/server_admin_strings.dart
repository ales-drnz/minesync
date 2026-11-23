// Testi della scheda Amministrazione di un server (solo admin): identità,
// valori propri o ereditati, esclusioni, disco e pulizia, eliminazione.
// Diversi dall'area Admin dell'hub (admin_strings.dart).
import 'package:ms_l10n/ms_l10n.dart';
import 'package:ms_protocol/ms_protocol.dart';

abstract final class ServerAdminStrings {
  static ServerAdminStrings of(Lang l) => switch (l) {
    Lang.it => const _It(),
    Lang.en => const _En(),
  };

  // identità
  String get identityTitle;
  String get name;
  String get nameHint;
  String get nameRequired;
  String get rename;
  String renamed(String name);
  String get idLabel;
  String get profile;
  String profileName(Profile p);
  String get readOnly;
  String get profileHint;

  // valori per questo server
  String get overridesTitle;
  String get overridesNote;
  String get overridesSaved;
  String get inherit;
  String get customize;
  String originOf(String what);
  String get fromGlobal;
  String globalIs(String v);
  String get notANumber;
  String fieldLabel(String k);
  String get autosave;
  String minutes(int n);
  String get minutesUnit;
  String get autostop;
  String autostopOn(int n);
  String get autostopSwitch;
  String get autostopUnit;
  String get crashRestarts;
  String get portTest;
  String get portTestSwitch;
  String get on;
  String get off;
  String get retention;
  String retentionValue(int last, int hours, int days);
  String get keepLastUnit;
  String get keepHoursUnit;
  String get keepDaysUnit;
  String get protection;
  String protectionValue(int pct, int min);
  String get ratioUnit;
  String get minFilesUnit;

  // esclusioni
  String get exclusionsTitle;
  String get system;
  String get fromProfile;
  String moreFromProfile(int n, String profile);
  String removePattern(String p);
  String get newPattern;
  String get patternPlaceholder;
  String get add;
  String get alreadyThere;
  String patternAdded(String p);
  String patternRemoved(String p);
  String exclusionsNote(String server);

  // disco e pulizia
  String get diskTitle;
  String get usagePending;
  String generations(int n);
  String get reallyUsed;
  String get shareBar;
  String shareOfHub(String pct);
  String hubTotal(String size);
  String get keepBefore;
  String get keepAfter;
  String get keepLabel;
  String get keepInvalid;
  String gcButton(String server);
  String gcWould(int n, String size);
  String get gcNothing;
  String gcTitle(String server);
  String get irreversible;
  String gcBody(int keep, int n, String size);
  String get gcConfirm;
  String get gcDone;
  String gcDoneText(int n, String size);

  // eliminazione
  String get dangerTitle;
  String get deleteServer;
  String deleteText(String server, int? gens, String? size);
  String deleteButton(String server);
  String deleteTitle(String server);
  String deleteBody(String server);
  String get deleteHelp;
  String deleteConfirm(String server);
  String deleted(String server);
  String get blockedTitle;
  String blockedText(String who, String since);
}

final class _It implements ServerAdminStrings {
  const _It();
  @override
  String get identityTitle => 'Identità';
  @override
  String get name => 'Nome';
  @override
  String get nameHint => "L'indirizzo fisso non cambia: usa l'id del server.";
  @override
  String get nameRequired => 'Scrivi un nome';
  @override
  String get rename => 'Rinomina';
  @override
  String renamed(String name) => 'Nome cambiato in $name';
  @override
  String get idLabel => 'id';
  @override
  String get profile => 'Profilo';
  @override
  String profileName(Profile p) => p == Profile.minecraft ? 'Minecraft' : 'Cartella generica';
  @override
  String get readOnly => 'sola lettura';
  @override
  String get profileHint =>
      'Scelto alla creazione. Determina il profilo da cui vengono ereditate le esclusioni.';
  @override
  String get overridesTitle => 'Valori per questo server';
  @override
  String get overridesNote => 'Le sessioni aperte li applicano dal prossimo salvataggio.';
  @override
  String get overridesSaved => 'Salvato e attivo';
  @override
  String get inherit => 'Eredita';
  @override
  String get customize => 'Personalizza';
  @override
  String originOf(String what) => '$what: origine';
  @override
  String get fromGlobal => "dal valore globale dell'hub";
  @override
  String globalIs(String v) => 'Globale: $v';
  @override
  String get notANumber => 'Inserisci un numero intero';
  @override
  String fieldLabel(String k) => switch (k) {
    'autosaveMinutes' => 'Minuti tra un salvataggio e l\'altro',
    'autostopMinutes' => 'Minuti senza giocatori',
    'crashRestarts' => 'Riavvii dopo un crash',
    'keepLast' => 'Ultime versioni',
    'keepHours' => 'Ore in cui tenerle tutte',
    'keepDays' => 'Giorni con una al giorno',
    'massDeleteRatio' => 'Percentuale di file tolti',
    _ => 'File minimi',
  };
  @override
  String get autosave => 'Salvataggio automatico';
  @override
  String minutes(int n) => 'ogni $n min';
  @override
  String get minutesUnit => 'minuti';
  @override
  String get autostop => 'Arresto se vuoto';
  @override
  String autostopOn(int n) => 'attivo, $n min';
  @override
  String get autostopSwitch => 'Arresta il server senza giocatori';
  @override
  String get autostopUnit => 'minuti senza giocatori';
  @override
  String get crashRestarts => 'Riavvii dopo un crash';
  @override
  String get portTest => 'Verifica della porta';
  @override
  String get portTestSwitch => "L'hub verifica la porta di chi ospita";
  @override
  String get on => 'attiva';
  @override
  String get off => 'disattivata';
  @override
  String get retention => 'Conservazione della storia';
  @override
  String retentionValue(int last, int hours, int days) => 'ultime $last, $hours h, $days giorni';
  @override
  String get keepLastUnit => 'ultime versioni';
  @override
  String get keepHoursUnit => 'ore tutte';
  @override
  String get keepDaysUnit => 'giorni, una al giorno';
  @override
  String get protection => 'Protezione dalle cancellazioni';
  @override
  String protectionValue(int pct, int min) => 'oltre il $pct % dei file, con almeno $min file';
  @override
  String get ratioUnit => '% dei file al massimo';
  @override
  String get minFilesUnit => 'file almeno';
  @override
  String get exclusionsTitle => 'Esclusioni';
  @override
  String get system => 'di sistema';
  @override
  String get fromProfile => 'dal profilo';
  @override
  String moreFromProfile(int n, String profile) => '… altre $n dal profilo $profile';
  @override
  String removePattern(String p) => 'Rimuovi $p';
  @override
  String get newPattern => 'Nuovo pattern';
  @override
  String get patternPlaceholder => 'es. bluemap/ oppure *.bak';
  @override
  String get add => 'Aggiungi';
  @override
  String get alreadyThere => 'Pattern già presente';
  @override
  String patternAdded(String p) => '$p escluso';
  @override
  String patternRemoved(String p) => '$p di nuovo sincronizzato';
  @override
  String exclusionsNote(String server) =>
      'Quelle in grigio sono ereditate dal profilo e seguono Admin › Esclusioni. Le altre valgono solo per $server.';
  @override
  String get diskTitle => 'Disco e pulizia';
  @override
  String get usagePending => "Calcolo dello spazio occupato in corso.";
  @override
  String generations(int n) => n == 1 ? '1 versione' : '$n versioni';
  @override
  String get reallyUsed => 'occupati effettivamente';
  @override
  String get shareBar => "Quota dello spazio dell'hub";
  @override
  String shareOfHub(String pct) => "$pct dello spazio dell'hub";
  @override
  String hubTotal(String size) => '$size in totale';
  @override
  String get keepBefore => 'Pulizia: mantieni le ultime';
  @override
  String get keepAfter => 'versioni';
  @override
  String get keepLabel => 'Versioni da mantenere';
  @override
  String get keepInvalid => 'Inserisci un numero maggiore di 0';
  @override
  String gcButton(String server) => 'Pulisci $server…';
  @override
  String gcWould(int n, String size) =>
      n == 1 ? 'eliminerebbe 1 versione, ~$size' : 'eliminerebbe $n versioni, ~$size';
  @override
  String get gcNothing => 'nessuna versione da eliminare';
  @override
  String gcTitle(String server) => 'Pulire $server?';
  @override
  String get irreversible => 'Irreversibile';
  @override
  String gcBody(int keep, int n, String size) =>
      'Restano le ultime $keep versioni: ne vengono eliminate $n e si liberano circa $size. Operazione irreversibile.';
  @override
  String get gcConfirm => 'Pulisci';
  @override
  String get gcDone => 'Pulizia completata';
  @override
  String gcDoneText(int n, String size) =>
      n == 1 ? 'Eliminata 1 versione, liberati $size' : 'Eliminate $n versioni, liberati $size';
  @override
  String get dangerTitle => 'Zona pericolosa';
  @override
  String get deleteServer => 'Elimina il server';
  @override
  String deleteText(String server, int? gens, String? size) =>
      "Elimina $server dall'hub${gens == null ? '' : ' con tutte le $gens versioni'}${size == null ? '' : ' ($size)'}. Le copie sui PC dei giocatori restano. Operazione irreversibile.";
  @override
  String deleteButton(String server) => 'Elimina $server…';
  @override
  String deleteTitle(String server) => 'Eliminare $server?';
  @override
  String deleteBody(String server) =>
      "$server viene eliminato dall'hub con tutta la sua storia. Le copie sui PC dei giocatori restano.";
  @override
  String get deleteHelp => 'Il pulsante si attiva quando il nome corrisponde.';
  @override
  String deleteConfirm(String server) => 'Elimina $server';
  @override
  String deleted(String server) => '$server eliminato';
  @override
  String get blockedTitle => 'Non disponibile durante una partita';
  @override
  String blockedText(String who, String since) =>
      '$who ospita il server da $since. Attendi la chiusura o forza il rilascio dalla Panoramica.';
}

final class _En implements ServerAdminStrings {
  const _En();
  @override
  String get identityTitle => 'Identity';
  @override
  String get name => 'Name';
  @override
  String get nameHint => "The fixed address does not change: it uses the server's id.";
  @override
  String get nameRequired => 'Type a name';
  @override
  String get rename => 'Rename';
  @override
  String renamed(String name) => 'Renamed to $name';
  @override
  String get idLabel => 'id';
  @override
  String get profile => 'Profile';
  @override
  String profileName(Profile p) => p == Profile.minecraft ? 'Minecraft' : 'Generic folder';
  @override
  String get readOnly => 'read only';
  @override
  String get profileHint =>
      'Chosen at creation. Determines the profile the exclusions are inherited from.';
  @override
  String get overridesTitle => 'Values for this server';
  @override
  String get overridesNote => 'Open sessions apply them from the next save.';
  @override
  String get overridesSaved => 'Saved and active';
  @override
  String get inherit => 'Inherit';
  @override
  String get customize => 'Customise';
  @override
  String originOf(String what) => '$what: source';
  @override
  String get fromGlobal => 'from the hub global value';
  @override
  String globalIs(String v) => 'Global: $v';
  @override
  String get notANumber => 'Enter a whole number';
  @override
  String fieldLabel(String k) => switch (k) {
    'autosaveMinutes' => 'Minutes between saves',
    'autostopMinutes' => 'Minutes without players',
    'crashRestarts' => 'Restarts after a crash',
    'keepLast' => 'Last versions',
    'keepHours' => 'Hours keeping all',
    'keepDays' => 'Days with one a day',
    'massDeleteRatio' => 'Percentage of files removed',
    _ => 'Minimum files',
  };
  @override
  String get autosave => 'Autosave';
  @override
  String minutes(int n) => 'every $n min';
  @override
  String get minutesUnit => 'minutes';
  @override
  String get autostop => 'Stop when empty';
  @override
  String autostopOn(int n) => 'on, $n min';
  @override
  String get autostopSwitch => 'Stop the server without players';
  @override
  String get autostopUnit => 'minutes without players';
  @override
  String get crashRestarts => 'Restarts after a crash';
  @override
  String get portTest => 'Port test';
  @override
  String get portTestSwitch => 'The hub tests the host port';
  @override
  String get on => 'on';
  @override
  String get off => 'off';
  @override
  String get retention => 'History retention';
  @override
  String retentionValue(int last, int hours, int days) => 'last $last, $hours h, $days days';
  @override
  String get keepLastUnit => 'last versions';
  @override
  String get keepHoursUnit => 'hours, all of them';
  @override
  String get keepDaysUnit => 'days, one a day';
  @override
  String get protection => 'Mass delete protection';
  @override
  String protectionValue(int pct, int min) => 'over $pct % of the files, with at least $min files';
  @override
  String get ratioUnit => '% of the files at most';
  @override
  String get minFilesUnit => 'files at least';
  @override
  String get exclusionsTitle => 'Exclusions';
  @override
  String get system => 'system';
  @override
  String get fromProfile => 'from the profile';
  @override
  String moreFromProfile(int n, String profile) => '… $n more from the $profile profile';
  @override
  String removePattern(String p) => 'Remove $p';
  @override
  String get newPattern => 'New pattern';
  @override
  String get patternPlaceholder => 'e.g. bluemap/ or *.bak';
  @override
  String get add => 'Add';
  @override
  String get alreadyThere => 'Pattern already present';
  @override
  String patternAdded(String p) => '$p excluded';
  @override
  String patternRemoved(String p) => '$p synced again';
  @override
  String exclusionsNote(String server) =>
      'The grey ones are inherited from the profile and follow Admin › Exclusions. The others apply only to $server.';
  @override
  String get diskTitle => 'Disk and cleanup';
  @override
  String get usagePending => 'Calculating the space used.';
  @override
  String generations(int n) => n == 1 ? '1 version' : '$n versions';
  @override
  String get reallyUsed => 'actually used';
  @override
  String get shareBar => "Share of the hub's space";
  @override
  String shareOfHub(String pct) => "$pct of the hub's space";
  @override
  String hubTotal(String size) => '$size in total';
  @override
  String get keepBefore => 'Cleanup: keep the last';
  @override
  String get keepAfter => 'versions';
  @override
  String get keepLabel => 'Versions to keep';
  @override
  String get keepInvalid => 'Enter a number greater than 0';
  @override
  String gcButton(String server) => 'Clean $server…';
  @override
  String gcWould(int n, String size) =>
      n == 1 ? 'would delete 1 version, ~$size' : 'would delete $n versions, ~$size';
  @override
  String get gcNothing => 'no versions to delete';
  @override
  String gcTitle(String server) => 'Clean $server?';
  @override
  String get irreversible => 'Irreversible';
  @override
  String gcBody(int keep, int n, String size) =>
      'The last $keep versions stay: $n are deleted and about $size is freed. This cannot be undone.';
  @override
  String get gcConfirm => 'Clean';
  @override
  String get gcDone => 'Cleanup done';
  @override
  String gcDoneText(int n, String size) =>
      n == 1 ? '1 version deleted, $size freed' : '$n versions deleted, $size freed';
  @override
  String get dangerTitle => 'Danger zone';
  @override
  String get deleteServer => 'Delete the server';
  @override
  String deleteText(String server, int? gens, String? size) =>
      'Deletes $server from the hub${gens == null ? '' : ' with all its $gens versions'}${size == null ? '' : ' ($size)'}. Copies on the players\' PCs are kept. This cannot be undone.';
  @override
  String deleteButton(String server) => 'Delete $server…';
  @override
  String deleteTitle(String server) => 'Delete $server?';
  @override
  String deleteBody(String server) =>
      '$server is deleted from the hub with all its history. Copies on the players\' PCs are kept.';
  @override
  String get deleteHelp => 'The button is enabled when the name matches.';
  @override
  String deleteConfirm(String server) => 'Delete $server';
  @override
  String deleted(String server) => '$server deleted';
  @override
  String get blockedTitle => 'Not available during a game';
  @override
  String blockedText(String who, String since) =>
      '$who has been hosting the server for $since. Wait for it to close or force the release from the Overview.';
}
