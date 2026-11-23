// Testi dell'area Admin: cornice (menu, strip di stato, ricerca, barra delle
// modifiche), parti comuni dei campi e le sezioni Generale, Storia e disco,
// Sessioni, Protezioni, Statistiche. Membri e Sistema stanno in
// admin_access_strings.dart, Telegram ed Esclusioni in admin_bot_strings.dart.
import 'package:ms_l10n/ms_l10n.dart';

import 'admin_access_strings.dart';
import 'admin_bot_strings.dart';

export 'admin_access_strings.dart';
export 'admin_bot_strings.dart';

abstract final class AdminStrings {
  const AdminStrings();

  static AdminStrings of(Lang l) => switch (l) {
    Lang.it => const _It(),
    Lang.en => const _En(),
  };

  /// Accesso e membri, Sistema.
  AdminAccessStrings get access;

  /// Telegram, Esclusioni.
  AdminBotStrings get bot;

  String get title;
  String get navLabel;
  String get general;
  String get members;
  String get history;
  String get sessions;

  /// Voce del menu laterale: [sessions] per intero non entra nei 256 px.
  String get sessionsNav;
  String get protection;
  String get exclusions;
  String get telegram;
  String get stats;
  String get system;

  // --- cornice -------------------------------------------------------------
  String eyebrow(String hub);
  String get leadHot;
  String lastChange(String who, String when);
  String get searchLabel;
  String get searchPlaceholder;
  String get searchNone;
  String get navHub;
  String get navServers;
  String get hotChip;
  String get loadError;
  String get statusLabel;
  String get statusZtnet;
  String ztnetSummary(int members, int admins);
  String get pillOk;
  String get pillError;
  String get pillOff;
  String get statusDisk;
  String diskFree(String size);
  String get statusTelegram;
  String tgLast(String time);
  String get tgNever;
  String get tgIncomplete;
  String get statusUpdates;
  String updatesSigned(int apps);
  String get updatesUnsigned;
  String get updatesNone;
  String get navActive;
  String navOwn(int servers);

  // --- campi ---------------------------------------------------------------
  String defaultIs(String v);
  String get modified;
  String was(String v);
  String get restore;
  String get useDefault;
  String rangeError(int min, int max);
  String get invalid;
  String get on;
  String get off;
  String get envSet;

  // --- barra delle modifiche -----------------------------------------------
  String unsaved(int n);
  String get autosaveSoon;
  String get saving;
  String get discard;
  String get saveNow;
  String get savedTitle;
  String savedText(int n);
  String get unsavedRegion;

  // --- unità e valori ------------------------------------------------------
  String get unitHours;
  String get unitSeconds;
  String get unitMinutes;
  String get unitGenerations;
  String get unitDays;
  String get unitFiles;
  String get unitAttempts;
  String get unitSessions;
  String get unitPercentFiles;
  String get unitPercentDisk;
  String hours(int n) => '$n h';
  String seconds(int n) => '$n s';
  String minutes(int n) => '$n min';
  String days(int n);
  String percent(int n) => '$n %';
  String gib(int n) => '$n GiB';

  /// Numero intero con il separatore delle migliaia: 1.284 / 1,284.
  String number(int n) {
    final s = n.abs().toString();
    final b = StringBuffer(n < 0 ? '-' : '');
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(_thousands);
      b.write(s[i]);
    }
    return b.toString();
  }

  String get _thousands;

  // --- Generale ------------------------------------------------------------
  String get nameLabel;
  String get nameHint;
  String nameCount(int n, int max);
  String get nameRequired;
  String get langLabel;
  String get langHint;
  String get langAuto;
  String get langIt;
  String get langEn;

  // --- Storia e disco ------------------------------------------------------
  String get historyTitle;
  String get historyLead;
  String get diskCard;
  String get diskAlmostFull;
  String get diskFull;
  String get diskOk;
  List<(String, bool)> diskFreeOf(String free, String total);
  String diskThreshold(String size);
  String hubUses(String size);
  String get perServer;
  String get other;
  String get usagePending;
  String get keepLast;
  String get keepLastHint;
  String get keepHours;
  String get keepHoursHint;
  String get keepDays;
  String get keepDaysHint;
  String get preview;
  String get previewLead;
  String get previewKeeps;
  String get previewDrops;
  String previewRow(String name, int now, int after);
  String get colServer;
  String get colNow;
  String get colAfter;
  String get colFreed;
  String get ownRules;
  String get total;
  String approx(String size);
  String get previewNote;
  String get previewError;
  String get minFree;
  String get minFreeHint;
  String get or;
  String todayWorth(String size, String rule);
  String ruleGiB(int gib);
  String rulePercent(int pct, String total);
  String minFreeDefault(int gib, int pct);
  String minFreeEnv(String size);
  String get manual;
  String get manualHint;
  String get keepN;
  String get manualButton;
  String wouldFree(String size);
  String get nothingToFree;
  String get gcTitle;
  String gcBody(int keep, int generations, String size);
  String get gcConfirm;
  String gcDone(int generations, String size);

  // --- Sessioni ------------------------------------------------------------
  String get sessionsLead;
  String get autosave;
  String get autosaveHint;
  String get autostop;
  String get autostopHint;
  String get autostopAfter;
  String get autostopUnit;
  String autostopDefault(int min);
  String get crash;
  String get crashHint;
  String get portTest;
  String get portTestHint;
  String get defaultOn;
  String ownValues(int n);
  String ownValuesText(String list);
  String ovAutosave(int m);
  String get ovAutostopOff;
  String ovAutostop(int m);
  String ovCrash(int n);
  String ovPort(bool on);
  String ovHistory(int last, int hours, int days);
  String ovProtection(int pct);
  String openServer(String name);

  // --- Protezioni ----------------------------------------------------------
  String get protectionLead;
  String get ratio;
  String get ratioHint;
  String get ratioSlider;
  List<(String, bool)> example(String name, String files, String limit);
  String exampleSmall(String name, String files, String min);
  String get minFiles;
  String get minFilesHint;

  // --- Statistiche ---------------------------------------------------------
  String get statsKept;
  String get statsKeptHint;
}

final class _It extends AdminStrings {
  const _It();
  @override
  AdminAccessStrings get access => AdminAccessStrings.of(Lang.it);
  @override
  AdminBotStrings get bot => AdminBotStrings.of(Lang.it);
  @override
  String get title => 'Amministrazione';
  @override
  String get navLabel => 'Sezioni dell\'amministrazione';
  @override
  String get general => 'Generale';
  @override
  String get members => 'Accesso e membri';
  @override
  String get history => 'Storia e disco';
  @override
  String get sessions => 'Sessioni di gioco';
  @override
  String get sessionsNav => 'Sessioni';
  @override
  String get protection => 'Protezioni';
  @override
  String get exclusions => 'Esclusioni';
  @override
  String get telegram => 'Telegram';
  @override
  String get stats => 'Statistiche';
  @override
  String get system => 'Sistema';

  @override
  String eyebrow(String hub) => 'Admin di $hub';
  @override
  String get leadHot => 'Le modifiche si applicano subito, senza riavvio.';
  @override
  String lastChange(String who, String when) =>
      'Ultima modifica: $who, $when (salvataggio automatico).';
  @override
  String get searchLabel => 'Cerca un\'impostazione';
  @override
  String get searchPlaceholder => 'Cerca: autosave, telegram, disco…';
  @override
  String get searchNone => 'Nessuna impostazione trovata';
  @override
  String get navHub => 'Hub';
  @override
  String get navServers => 'Per server';
  @override
  String get hotChip => 'senza riavvio';
  @override
  String get loadError => 'Impossibile leggere le impostazioni';
  @override
  String get statusLabel => 'Stato dell\'hub';
  @override
  String get statusZtnet => 'ZTNET';
  @override
  String ztnetSummary(int members, int admins) =>
      '${members == 1 ? '1 membro' : '$members membri'}, $admins admin';
  @override
  String get pillOk => 'ok';
  @override
  String get pillError => 'errore';
  @override
  String get pillOff => 'disattivato';
  @override
  String get statusDisk => 'Disco';
  @override
  String diskFree(String size) => 'liberi $size';
  @override
  String get statusTelegram => 'Telegram';
  @override
  String tgLast(String time) => 'ultimo $time';
  @override
  String get tgNever => 'nessun messaggio';
  @override
  String get tgIncomplete => 'incompleto';
  @override
  String get statusUpdates => 'Aggiornamenti';
  @override
  String updatesSigned(int apps) => 'firmati ($apps app)';
  @override
  String get updatesUnsigned => 'non firmati';
  @override
  String get updatesNone => 'nessuno su /dl';
  @override
  String get navActive => 'attivo';
  @override
  String navOwn(int servers) => '$servers server';

  @override
  String defaultIs(String v) => 'Predefinito: $v';
  @override
  String get modified => 'Modificato';
  @override
  String was(String v) => 'era $v';
  @override
  String get restore => 'Ripristina';
  @override
  String get useDefault => 'Usa il predefinito';
  @override
  String rangeError(int min, int max) => 'Scrivi un numero da ${number(min)} a ${number(max)}';
  @override
  String get invalid => 'Valore non accettato dall\'hub';
  @override
  String get on => 'Attivo';
  @override
  String get off => 'Disattivato';
  @override
  String get envSet => 'impostato all\'avvio';

  @override
  String unsaved(int n) => n == 1 ? '1 modifica non salvata' : '$n modifiche non salvate';
  @override
  String get autosaveSoon =>
      'Salvataggio automatico a breve. Le modifiche si applicano senza riavviare l\'hub.';
  @override
  String get saving => 'Salvataggio…';
  @override
  String get discard => 'Annulla';
  @override
  String get saveNow => 'Salva e applica';
  @override
  String get savedTitle => 'Salvato e attivo';
  @override
  String savedText(int n) =>
      '${n == 1 ? '1 impostazione applicata' : '$n impostazioni applicate'} senza riavvio. '
      'Le sessioni aperte le applicano dal prossimo salvataggio.';
  @override
  String get unsavedRegion => 'Modifiche non salvate';

  @override
  String get unitHours => 'ore';
  @override
  String get unitSeconds => 'secondi';
  @override
  String get unitMinutes => 'minuti';
  @override
  String get unitGenerations => 'versioni';
  @override
  String get unitDays => 'giorni';
  @override
  String get unitFiles => 'file';
  @override
  String get unitAttempts => 'tentativi';
  @override
  String get unitSessions => 'sessioni';
  @override
  String get unitPercentFiles => '% dei file';
  @override
  String get unitPercentDisk => '% del disco';
  @override
  String days(int n) => n == 1 ? '1 giorno' : '$n giorni';
  @override
  String get _thousands => '.';

  @override
  String get nameLabel => 'Nome dell\'hub';
  @override
  String get nameHint => 'Compare nell\'intestazione del web, nell\'app e nei messaggi del bot.';
  @override
  String nameCount(int n, int max) => '$n di $max caratteri';
  @override
  String get nameRequired => 'Inserisci un nome';
  @override
  String get langLabel => 'Lingua predefinita dei messaggi';
  @override
  String get langHint =>
      'Per il bot e per chi non ha scelto una lingua. Automatica: lingua del browser o dell\'app.';
  @override
  String get langAuto => 'Automatica';
  @override
  String get langIt => 'Italiano';
  @override
  String get langEn => 'English';

  @override
  String get historyTitle => 'Storia e spazio su disco';
  @override
  String get historyLead =>
      'Versioni da conservare e soglia oltre la quale i salvataggi vengono rifiutati.';
  @override
  String get diskCard => 'Disco dell\'hub';
  @override
  String get diskAlmostFull => 'Quasi pieno';
  @override
  String get diskFull => 'Pieno';
  @override
  String get diskOk => 'Spazio sufficiente';
  @override
  List<(String, bool)> diskFreeOf(String free, String total) => [
    ('liberi ', false),
    (free, true),
    (' su $total', false),
  ];
  @override
  String diskThreshold(String size) => 'soglia di blocco: $size';
  @override
  String hubUses(String size) => 'L\'hub occupa $size; il resto è usato da altri programmi.';
  @override
  String get perServer => 'Spazio per server';
  @override
  String get other => 'Altro (app su /dl)';
  @override
  String get usagePending => 'Calcolo dello spazio in corso…';
  @override
  String get keepLast => 'Conserva sempre le ultime';
  @override
  String get keepLastHint => 'Indipendentemente dall\'età.';
  @override
  String get keepHours => 'Tieni tutte quelle delle ultime';
  @override
  String get keepHoursHint => 'Permette di tornare indietro di pochi minuti dopo un errore.';
  @override
  String get keepDays => 'Poi una al giorno per';
  @override
  String get keepDaysHint => 'La più recente di ogni giorno.';
  @override
  String get preview => 'Anteprima';
  @override
  String get previewLead => 'con queste regole, alla prossima pulizia';
  @override
  String get previewKeeps => 'resta';
  @override
  String get previewDrops => 'si elimina';
  @override
  String previewRow(String name, int now, int after) => '$name: da $now a $after versioni';
  @override
  String approx(String size) => 'circa $size';
  @override
  String get colServer => 'Server';
  @override
  String get colNow => 'Ora';
  @override
  String get colAfter => 'Dopo';
  @override
  String get colFreed => 'Spazio liberato';
  @override
  String get ownRules => 'regole proprie';
  @override
  String get total => 'Totale';
  @override
  String get previewNote =>
      'La più recente e quelle in uso non vengono mai eliminate. Una versione eliminata non '
      'si può ripristinare.';
  @override
  String get previewError => 'Anteprima non disponibile';
  @override
  String get minFree => 'Spazio libero minimo';
  @override
  String get minFreeHint =>
      'Sotto questa soglia l\'hub rifiuta i salvataggi per non riempire il disco; l\'app avvisa '
      'in anticipo. Vale il più alto dei due valori.';
  @override
  String get or => 'oppure';
  @override
  String todayWorth(String size, String rule) => 'attualmente $size ($rule)';
  @override
  String ruleGiB(int gib) => 'i $gib GiB';
  @override
  String rulePercent(int pct, String total) => 'il $pct % di $total';
  @override
  String minFreeDefault(int gib, int pct) => 'Predefinito: $gib GiB o $pct %';
  @override
  String minFreeEnv(String size) =>
      'MINESYNC_MIN_FREE è impostato a $size e ha la precedenza su questi due valori.';
  @override
  String get manual => 'Pulizia manuale';
  @override
  String get manualHint =>
      'Libera spazio subito: su ogni server conserva solo le ultime N, ignorando una tantum le '
      'regole sopra.';
  @override
  String get keepN => 'mantieni le ultime';
  @override
  String get manualButton => 'Pulisci tutti i server…';
  @override
  String wouldFree(String size) => 'libererebbe circa $size, richiede conferma';
  @override
  String get nothingToFree => 'non eliminerebbe nulla';
  @override
  String get gcTitle => 'Pulire tutti i server?';
  @override
  String gcBody(int keep, int generations, String size) =>
      'Su ogni server restano le ultime $keep versioni: se ne eliminano $generations e si '
      'liberano circa $size. Operazione irreversibile.';
  @override
  String get gcConfirm => 'Pulisci ora';
  @override
  String gcDone(int generations, String size) =>
      'Pulizia completata: $generations versioni eliminate, $size liberati';

  @override
  String get sessionsLead =>
      'Valori predefiniti per tutti i server. Ogni server può cambiarli nella sua scheda '
      'Amministrazione.';
  @override
  String get autosave => 'Salvataggio automatico ogni';
  @override
  String get autosaveHint =>
      'Il mondo viene salvato sull\'hub anche durante la partita, non solo alla fine.';
  @override
  String get autostop => 'Arresta il server se resta vuoto';
  @override
  String get autostopHint =>
      'Salva, carica sull\'hub e libera il lock. Chi ospita può disattivarlo per una singola '
      'sessione dall\'app.';
  @override
  String get autostopAfter => 'dopo';
  @override
  String get autostopUnit => 'minuti senza giocatori';
  @override
  String autostopDefault(int min) => 'Predefinito: attivo, $min min';
  @override
  String get crash => 'Riavvii automatici dopo un crash';
  @override
  String get crashHint => 'Oltre questo limite la sessione si ferma e l\'app mostra la causa.';
  @override
  String get portTest => 'Verifica la porta di chi ospita';
  @override
  String get portTestHint =>
      'L\'hub verifica che gli altri giocatori possano entrare e mostra a tutti l\'esito: '
      'raggiungibile o bloccata dal firewall.';
  @override
  String get defaultOn => 'attivo';
  @override
  String ownValues(int n) => n == 1 ? '1 server ha valori propri' : '$n server hanno valori propri';
  @override
  String ownValuesText(String list) => '$list. Gli altri ereditano questi.';
  @override
  String ovAutosave(int m) => 'salvataggio ogni $m min';
  @override
  String get ovAutostopOff => 'arresto automatico disattivato';
  @override
  String ovAutostop(int m) => 'arresto dopo $m min';
  @override
  String ovCrash(int n) => n == 1 ? '1 riavvio' : '$n riavvii';
  @override
  String ovPort(bool on) => on ? 'verifica della porta attiva' : 'verifica della porta disattivata';
  @override
  String ovHistory(int last, int hours, int days) =>
      'storia (ultime $last, $hours h, ${this.days(days)})';
  @override
  String ovProtection(int pct) => 'soglia $pct %';
  @override
  String openServer(String name) => 'Apri $name';

  @override
  String get protectionLead =>
      'Blocca i salvataggi che cancellerebbero gran parte del mondo per errore (cartella '
      'sbagliata, copia incompleta).';
  @override
  String get ratio => 'Rifiuta i salvataggi che tolgono più del';
  @override
  String get ratioHint =>
      'Prima dell\'invio l\'app chiede conferma alla stessa soglia: un solo valore per hub e app.';
  @override
  String get ratioSlider => 'Soglia in percentuale';
  @override
  List<(String, bool)> example(String name, String files, String limit) => [
    ('Su $name ($files file) un salvataggio che ne toglie più di ', false),
    (limit, true),
    (' viene rifiutato.', false),
  ];
  @override
  String exampleSmall(String name, String files, String min) =>
      'Su $name ($files file) la regola non si applica: servono almeno $min file.';
  @override
  String get minFiles => 'Solo se il server ha almeno';
  @override
  String get minFilesHint =>
      'Sotto questo numero di file (server appena creato) la regola non si applica.';

  @override
  String get statsKept => 'Sessioni conservate per server';
  @override
  String get statsKeptHint =>
      'Usate per le classifiche di ore in gioco e di hosting. Le più vecchie vengono scartate.';
}

final class _En extends AdminStrings {
  const _En();
  @override
  AdminAccessStrings get access => AdminAccessStrings.of(Lang.en);
  @override
  AdminBotStrings get bot => AdminBotStrings.of(Lang.en);
  @override
  String get title => 'Administration';
  @override
  String get navLabel => 'Administration sections';
  @override
  String get general => 'General';
  @override
  String get members => 'Access and members';
  @override
  String get history => 'History and disk';
  @override
  String get sessions => 'Game sessions';
  @override
  String get sessionsNav => 'Sessions';
  @override
  String get protection => 'Protection';
  @override
  String get exclusions => 'Exclusions';
  @override
  String get telegram => 'Telegram';
  @override
  String get stats => 'Statistics';
  @override
  String get system => 'System';

  @override
  String eyebrow(String hub) => '$hub admin';
  @override
  String get leadHot => 'Changes apply immediately, with no restart.';
  @override
  String lastChange(String who, String when) => 'Last change: $who, $when (saved automatically).';
  @override
  String get searchLabel => 'Search a setting';
  @override
  String get searchPlaceholder => 'Search: autosave, telegram, disk…';
  @override
  String get searchNone => 'No setting found';
  @override
  String get navHub => 'Hub';
  @override
  String get navServers => 'Per server';
  @override
  String get hotChip => 'no restart';
  @override
  String get loadError => 'Unable to read the settings';
  @override
  String get statusLabel => 'Hub status';
  @override
  String get statusZtnet => 'ZTNET';
  @override
  String ztnetSummary(int members, int admins) =>
      '${members == 1 ? '1 member' : '$members members'}, $admins admin${admins == 1 ? '' : 's'}';
  @override
  String get pillOk => 'ok';
  @override
  String get pillError => 'error';
  @override
  String get pillOff => 'off';
  @override
  String get statusDisk => 'Disk';
  @override
  String diskFree(String size) => '$size free';
  @override
  String get statusTelegram => 'Telegram';
  @override
  String tgLast(String time) => 'last $time';
  @override
  String get tgNever => 'no messages';
  @override
  String get tgIncomplete => 'incomplete';
  @override
  String get statusUpdates => 'Updates';
  @override
  String updatesSigned(int apps) => 'signed ($apps app${apps == 1 ? '' : 's'})';
  @override
  String get updatesUnsigned => 'not signed';
  @override
  String get updatesNone => 'none on /dl';
  @override
  String get navActive => 'active';
  @override
  String navOwn(int servers) => '$servers server${servers == 1 ? '' : 's'}';

  @override
  String defaultIs(String v) => 'Default: $v';
  @override
  String get modified => 'Changed';
  @override
  String was(String v) => 'was $v';
  @override
  String get restore => 'Restore';
  @override
  String get useDefault => 'Use the default';
  @override
  String rangeError(int min, int max) => 'Enter a number from ${number(min)} to ${number(max)}';
  @override
  String get invalid => 'Value not accepted by the hub';
  @override
  String get on => 'On';
  @override
  String get off => 'Off';
  @override
  String get envSet => 'set at start';

  @override
  String unsaved(int n) => n == 1 ? '1 unsaved change' : '$n unsaved changes';
  @override
  String get autosaveSoon => 'Saving automatically shortly. Changes apply with no hub restart.';
  @override
  String get saving => 'Saving…';
  @override
  String get discard => 'Cancel';
  @override
  String get saveNow => 'Save and apply';
  @override
  String get savedTitle => 'Saved and active';
  @override
  String savedText(int n) =>
      '${n == 1 ? '1 setting applied' : '$n settings applied'} with no restart. '
      'Open sessions apply them from their next save.';
  @override
  String get unsavedRegion => 'Unsaved changes';

  @override
  String get unitHours => 'hours';
  @override
  String get unitSeconds => 'seconds';
  @override
  String get unitMinutes => 'minutes';
  @override
  String get unitGenerations => 'versions';
  @override
  String get unitDays => 'days';
  @override
  String get unitFiles => 'files';
  @override
  String get unitAttempts => 'attempts';
  @override
  String get unitSessions => 'sessions';
  @override
  String get unitPercentFiles => '% of the files';
  @override
  String get unitPercentDisk => '% of the disk';
  @override
  String days(int n) => n == 1 ? '1 day' : '$n days';
  @override
  String get _thousands => ',';

  @override
  String get nameLabel => 'Hub name';
  @override
  String get nameHint => 'Shown in the web header, in the app and in the bot messages.';
  @override
  String nameCount(int n, int max) => '$n of $max characters';
  @override
  String get nameRequired => 'Enter a name';
  @override
  String get langLabel => 'Default message language';
  @override
  String get langHint =>
      'For the bot and for users who have not chosen a language. Automatic: browser or app '
      'language.';
  @override
  String get langAuto => 'Automatic';
  @override
  String get langIt => 'Italiano';
  @override
  String get langEn => 'English';

  @override
  String get historyTitle => 'History and disk space';
  @override
  String get historyLead => 'Versions to keep and the threshold beyond which saves are refused.';
  @override
  String get diskCard => 'Hub disk';
  @override
  String get diskAlmostFull => 'Almost full';
  @override
  String get diskFull => 'Full';
  @override
  String get diskOk => 'Enough space';
  @override
  List<(String, bool)> diskFreeOf(String free, String total) => [
    (free, true),
    (' free of $total', false),
  ];
  @override
  String diskThreshold(String size) => 'blocking threshold: $size';
  @override
  String hubUses(String size) => 'The hub uses $size; the rest is used by other programs.';
  @override
  String get perServer => 'Space per server';
  @override
  String get other => 'Other (apps on /dl)';
  @override
  String get usagePending => 'Computing the space used…';
  @override
  String get keepLast => 'Always keep the last';
  @override
  String get keepLastHint => 'Regardless of age.';
  @override
  String get keepHours => 'Keep all those of the last';
  @override
  String get keepHoursHint => 'Allows going back a few minutes after a mistake.';
  @override
  String get keepDays => 'Then one a day for';
  @override
  String get keepDaysHint => 'The newest of each day.';
  @override
  String get preview => 'Preview';
  @override
  String get previewLead => 'with these rules, at the next cleanup';
  @override
  String get previewKeeps => 'stays';
  @override
  String get previewDrops => 'is deleted';
  @override
  String previewRow(String name, int now, int after) => '$name: from $now to $after versions';
  @override
  String approx(String size) => 'about $size';
  @override
  String get colServer => 'Server';
  @override
  String get colNow => 'Now';
  @override
  String get colAfter => 'After';
  @override
  String get colFreed => 'Space freed';
  @override
  String get ownRules => 'own rules';
  @override
  String get total => 'Total';
  @override
  String get previewNote =>
      'The newest one and those in use are never deleted. A deleted version cannot be '
      'restored.';
  @override
  String get previewError => 'Preview not available';
  @override
  String get minFree => 'Minimum free space';
  @override
  String get minFreeHint =>
      'Below this threshold the hub refuses saves so the disk does not fill up; the app warns '
      'in advance. The higher of the two values applies.';
  @override
  String get or => 'or';
  @override
  String todayWorth(String size, String rule) => 'currently $size ($rule)';
  @override
  String ruleGiB(int gib) => 'the $gib GiB';
  @override
  String rulePercent(int pct, String total) => '$pct % of $total';
  @override
  String minFreeDefault(int gib, int pct) => 'Default: $gib GiB or $pct %';
  @override
  String minFreeEnv(String size) =>
      'MINESYNC_MIN_FREE is set to $size and takes precedence over these two values.';
  @override
  String get manual => 'Manual cleanup';
  @override
  String get manualHint =>
      'Frees space now: keeps only the last N on every server, ignoring the rules above this '
      'once.';
  @override
  String get keepN => 'keep the last';
  @override
  String get manualButton => 'Clean every server…';
  @override
  String wouldFree(String size) => 'would free about $size, requires confirmation';
  @override
  String get nothingToFree => 'would delete nothing';
  @override
  String get gcTitle => 'Clean every server?';
  @override
  String gcBody(int keep, int generations, String size) =>
      'Every server keeps its last $keep versions: $generations are deleted and about $size '
      'is freed. This cannot be undone.';
  @override
  String get gcConfirm => 'Clean now';
  @override
  String gcDone(int generations, String size) =>
      'Cleanup completed: $generations versions deleted, $size freed';

  @override
  String get sessionsLead =>
      'Default values for every server. Each server can change them in its Administration tab.';
  @override
  String get autosave => 'Autosave every';
  @override
  String get autosaveHint =>
      'The world is saved to the hub during the game too, not only at the end.';
  @override
  String get autostop => 'Stop the server when it is empty';
  @override
  String get autostopHint =>
      'Saves, uploads to the hub and frees the lock. The host can turn it off for one session '
      'from the app.';
  @override
  String get autostopAfter => 'after';
  @override
  String get autostopUnit => 'minutes without players';
  @override
  String autostopDefault(int min) => 'Default: on, $min min';
  @override
  String get crash => 'Automatic restarts after a crash';
  @override
  String get crashHint => 'Beyond this limit the session stops and the app shows the cause.';
  @override
  String get portTest => 'Test the host\'s port';
  @override
  String get portTestHint =>
      'The hub checks that other players can join and shows the result to everyone: reachable '
      'or blocked by the firewall.';
  @override
  String get defaultOn => 'on';
  @override
  String ownValues(int n) =>
      n == 1 ? '1 server has its own values' : '$n servers have their own values';
  @override
  String ownValuesText(String list) => '$list. The others inherit these.';
  @override
  String ovAutosave(int m) => 'autosave every $m min';
  @override
  String get ovAutostopOff => 'automatic stop off';
  @override
  String ovAutostop(int m) => 'stops after $m min';
  @override
  String ovCrash(int n) => n == 1 ? '1 restart' : '$n restarts';
  @override
  String ovPort(bool on) => on ? 'port test on' : 'port test off';
  @override
  String ovHistory(int last, int hours, int days) =>
      'history (last $last, $hours h, ${this.days(days)})';
  @override
  String ovProtection(int pct) => 'threshold $pct %';
  @override
  String openServer(String name) => 'Open $name';

  @override
  String get protectionLead =>
      'Blocks saves that would delete a large part of the world by mistake (wrong folder, incomplete copy).';
  @override
  String get ratio => 'Refuse saves that remove more than';
  @override
  String get ratioHint =>
      'Before sending, the app asks for confirmation at the same threshold: one value for hub '
      'and app.';
  @override
  String get ratioSlider => 'Threshold in percent';
  @override
  List<(String, bool)> example(String name, String files, String limit) => [
    ('On $name ($files files) a save that removes more than ', false),
    (limit, true),
    (' is refused.', false),
  ];
  @override
  String exampleSmall(String name, String files, String min) =>
      'On $name ($files files) the rule does not apply: it needs at least $min files.';
  @override
  String get minFiles => 'Only if the server has at least';
  @override
  String get minFilesHint =>
      'Below this number of files (a server just created) the rule does not apply.';

  @override
  String get statsKept => 'Sessions kept per server';
  @override
  String get statsKeptHint =>
      'Used for the rankings of hours played and hosting. The oldest are discarded.';
}
