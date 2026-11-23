// Testi della pagina di un server: intestazione e schede Panoramica,
// Giocatori e Mod. La Storia e l'Amministrazione hanno i loro file
// (history_strings.dart, server_admin_strings.dart), raggiungibili da qui.
import 'package:ms_l10n/ms_l10n.dart';
import 'package:ms_protocol/ms_protocol.dart';

import 'format_strings.dart';
import 'history_strings.dart';
import 'server_admin_strings.dart';

export 'history_strings.dart';
export 'server_admin_strings.dart';

/// Numero con il separatore delle migliaia: 1.842 (IT) / 1,842 (EN).
String groupInt(Lang l, int n) {
  final d = n.abs().toString();
  final sep = l == Lang.it ? '.' : ',';
  final b = StringBuffer(n < 0 ? '−' : '');
  for (var i = 0; i < d.length; i++) {
    if (i > 0 && (d.length - i) % 3 == 0) b.write(sep);
    b.write(d[i]);
  }
  return b.toString();
}

/// Ore intere da tick di gioco (20 al secondo); sotto l'ora la durata.
String _hours(FormatStrings f, int ticks) =>
    ticks >= 72000 ? '${ticks ~/ 72000} h' : f.duration(Duration(seconds: ticks ~/ 20));

/// Distanza da centimetri: km sopra il chilometro, altrimenti metri.
String _distance(Lang l, int cm) =>
    cm >= 100000 ? '${groupInt(l, cm ~/ 100000)} km' : '${groupInt(l, cm ~/ 100)} m';

abstract final class ServerStrings {
  static ServerStrings of(Lang l) => switch (l) {
    Lang.it => const _It(),
    Lang.en => const _En(),
  };

  /// Scheda Storia.
  HistoryStrings get history;

  /// Scheda Amministrazione.
  ServerAdminStrings get admin;

  // intestazione e schede
  String get crumb;
  String tabsLabel(String server);
  String get tabOverview;
  String get tabPlayers;
  String get tabMods;
  String get tabHistory;
  String get tabAdmin;
  String onHub(String size);
  String zipHead(int n);
  String get loadError;
  String get noMatch;
  String changesLabel(int added, int changed, int removed);
  String step(int i, int of);

  // Panoramica: sessione e indirizzo
  String get lockTitle;
  String get lockPush;
  String get sessionSince;
  String get pushSince;
  String onlineList(int n);
  String host(String name);
  String get joinOn;
  String get fixedAddress;
  String get directIp;
  String get copyFixed;
  String get copyDirect;
  String portState(PortState s);
  String portText(PortState s, int port, String? at);
  String get portRetry;
  String get forceRelease;
  String forceAdminNote(String who);
  String forceMemberNote(String who);
  String forceTitle(String server);
  String forceBody1(String who, int players);
  String get forceContinue;
  String get forceTitle2;
  String forceBody2(String who, String head);
  String get releaseStale;
  String get releaseStaleNote;
  String releaseStaleTitle(String who);
  String releaseStaleBody(String who, String head);
  String released(String server);
  String staleSince(String? since);
  String staleTitle(String who);
  String staleText(String head, String? at, String who);
  String get nobodyHosts;
  String lastSession(String who, String start, String? end);
  String get freeHowTo1;
  String get play;
  String freeHowTo2(String? address);

  // Panoramica: mondo e server
  String get worldTitle;
  String fromLevel(String gen);
  String get noSaveYet;
  String get noLevel;
  String get worldName;
  String get worldVersion;
  String get difficulty;
  String difficultyName(Difficulty d);
  String hardcore(bool on);
  String get gameMode;
  String gameModeName(GameMode m);
  String get worldTime;
  String dayLine(String day, int? hours);
  String get spawn;
  String get seed;
  String get copySeed;
  String get propsTitle;
  String get fromProperties;
  String get noProperties;
  String get propsNote;
  String get motd;
  String get maxPlayers;
  String get pvp;
  String yesNo(bool v);
  String get whitelist;
  String onOff(bool v);
  String names(int n);
  String get viewDistance;
  String get simulationDistance;
  String chunks(int n);

  // Panoramica: statistiche, storia recente, spazio
  String get statsTitle;
  String get noSessions;
  String get playHours;
  String get playHoursNote;
  String get hostHours;
  String get hostHoursNote;
  String get noRanking;
  String get sessionsTitle;
  String sessionsLabel(int n);
  String get average;
  String get longest;
  String get lastOne;
  String get ongoing;
  String keptNote(int n);
  String get recentTitle;
  String get recentLabel;
  String get allHistory;
  String get spaceTitle;
  String get readOnly;
  String get keepTitle;
  String get hubRules;
  String ownRules(String server, int last, int hours, int days);
  String get versionsKept;
  String versionsRange(int n, String from, String to);
  String spaceOf(String server);
  String get hubFree;
  String get hubDiskBar;
  String diskUsed(String pct, String minFree);
  String get adminChanges;
  String get editRules;

  // Giocatori
  String playersCount(int n);
  String playersLead(int online, int ops, bool whitelist, String gen, String? at);
  String get searchPlayer;
  String get sortBy;
  String get sortTime;
  String get sortDeaths;
  String get sortMobs;
  String get sortDistance;
  String get noPlayersTitle;
  String get noPlayersText;
  String get playingNow;
  String get hostShort;
  String get notWhitelisted;
  String get online;
  String get op;
  String get outsideWhitelist;
  String get playTime;
  String playTimeValue(FormatStrings f, int ticks);
  String hoursValue(FormatStrings f, int ticks);
  String get deaths;
  String get mobKills;
  String get distance;
  String get distanceWalked;
  String distanceValue(Lang l, int cm);
  String get boardsTitle;
  String get boardsNote;

  // Mod
  String get modsLabel;
  String get modsTotal;
  String loaderLabel(String? version);
  String get bareLabel;
  String get searchMods;
  String get searchModsLabel;
  String get sortMods;
  String get sortName;
  String get sortSize;
  String get sortRecent;
  String filterAll(int n);
  String filterMeta(int n);
  String filterBare(int n);
  String filterChanged(String head, int n);
  String get modsListLabel;
  String get noMetaShort;
  String shownOf(int n, int total);
  String get noModsTitle;
  String get noModsText;
  String get detailTitle;
  String detailOf(String mod);
  String get closeDetail;
  String get authors;
  String get site;
  String openSite(String host);
  String get license;
  String get file;
  String get size;
  String get presentSince;
  String updatedIn(String gen);
  String sinceGen(String gen);
  String get modNote;
  String get noMetaTitle;
  String get noMetaText;
}

final class _It implements ServerStrings {
  const _It();
  @override
  HistoryStrings get history => HistoryStrings.of(Lang.it);
  @override
  ServerAdminStrings get admin => ServerAdminStrings.of(Lang.it);
  @override
  String get crumb => 'Server';
  @override
  String tabsLabel(String server) => 'Sezioni del server $server';
  @override
  String get tabOverview => 'Panoramica';
  @override
  String get tabPlayers => 'Giocatori';
  @override
  String get tabMods => 'Mod';
  @override
  String get tabHistory => 'Storia';
  @override
  String get tabAdmin => 'Amministrazione';
  @override
  String onHub(String size) => "$size sull'hub";
  @override
  String zipHead(int n) => 'Scarica zip';
  @override
  String get loadError => 'Impossibile leggere questi dati';
  @override
  String get noMatch => 'Nessun risultato con questi filtri.';
  @override
  String changesLabel(int added, int changed, int removed) =>
      '$added aggiunti, $changed modificati, $removed rimossi';
  @override
  String step(int i, int of) => 'Conferma $i di $of';
  @override
  String get lockTitle => 'Sessione e indirizzo';
  @override
  String get lockPush => 'Salvataggio';
  @override
  String get sessionSince => 'in sessione da ';
  @override
  String get pushSince => "salvataggio dall'app in corso da ";
  @override
  String onlineList(int n) => '$n online:';
  @override
  String host(String name) => '$name (host)';
  @override
  String get joinOn => 'Entra in gioco su';
  @override
  String get fixedAddress => 'Indirizzo fisso, uguale per tutti, anche quando cambia chi ospita';
  @override
  String get directIp => 'IP diretto del PC di chi ospita, se il nome non funziona';
  @override
  String get copyFixed => 'Copia indirizzo fisso';
  @override
  String get copyDirect => 'Copia IP diretto';
  @override
  String portState(PortState s) => switch (s) {
    PortState.reachable => 'Raggiungibile',
    PortState.blocked => 'Non raggiungibile',
    PortState.pending => 'Verifica in corso',
    PortState.off => 'Verifica disattivata',
  };
  @override
  String portText(PortState s, int port, String? at) => switch (s) {
    PortState.reachable =>
      at == null ? "porta $port verificata dall'hub" : "porta $port verificata dall'hub alle $at",
    PortState.blocked =>
      "porta $port non raggiungibile dall'hub: controlla il firewall di chi ospita",
    PortState.pending => 'verifica della porta $port in corso',
    PortState.off => 'verifica della porta disattivata in Admin › Sessioni',
  };
  @override
  String get portRetry => 'Ripeti la verifica';
  @override
  String get forceRelease => 'Forza rilascio';
  @override
  String forceAdminNote(String who) =>
      'Interrompe la sessione di $who: il server si ferma e il mondo resta sul suo PC. Richiede due conferme.';
  @override
  String forceMemberNote(String who) =>
      "Solo un admin può forzare un lock attivo. Chiedi a $who di chiudere dall'app.";
  @override
  String forceTitle(String server) => 'Forzare il rilascio di $server?';
  @override
  String forceBody1(String who, int players) =>
      '$who sta ospitando${players > 0 ? ' con $players online' : ''}. Il server si ferma e il mondo resta sul suo PC: le modifiche non salvate non arrivano sull\'hub.';
  @override
  String get forceContinue => 'Continua';
  @override
  String get forceTitle2 => 'Confermare il rilascio forzato?';
  @override
  String forceBody2(String who, String head) =>
      'Chi gioca dopo riparte dall\'ultimo salvataggio sull\'hub. Le modifiche successive di $who restano solo sul suo PC.';
  @override
  String get releaseStale => 'Libera il lock';
  @override
  String get releaseStaleNote => 'Un lock che non risponde può essere liberato da chiunque.';
  @override
  String releaseStaleTitle(String who) => 'Liberare il lock di $who?';
  @override
  String releaseStaleBody(String who, String head) =>
      'Chi gioca dopo riparte dall\'ultimo salvataggio sull\'hub. Se l\'app di $who è ancora aperta, le modifiche successive restano sul suo PC.';
  @override
  String released(String server) => 'Lock di $server liberato';
  @override
  String staleSince(String? since) => since == null
      ? 'nessun segnale dal suo PC (limite 90 s)'
      : 'nessun segnale dal suo PC da $since (limite 90 s)';
  @override
  String staleTitle(String who) => "L'app di $who potrebbe essersi chiusa in modo anomalo";
  @override
  String staleText(String head, String? at, String who) =>
      "Sull'hub resta l'ultimo salvataggio${at == null ? '' : ' (alle $at)'}. Dopo il rilascio del lock, chi gioca riparte da lì; le modifiche successive restano solo sul PC di $who.";
  @override
  String get nobodyHosts => 'Nessuno ospita.';
  @override
  String lastSession(String who, String start, String? end) =>
      'Nessuno ospita. Ultima sessione: $who, $start${end == null ? '' : '–$end'}.';
  @override
  String get freeHowTo1 => "Apri l'app e premi ";
  @override
  String get play => 'Gioca';
  @override
  String freeHowTo2(String? address) =>
      ": l'app scarica l'ultima versione e il tuo PC diventa l'host.${address == null ? '' : ' Gli altri giocatori entrano su $address.'}";
  @override
  String get worldTitle => 'Mondo';
  @override
  String fromLevel(String gen) => 'da level.dat';
  @override
  String get noSaveYet => "Vuoto: i dati arrivano con il primo salvataggio dall'app.";
  @override
  String get noLevel => 'level.dat mancante o illeggibile in questa versione.';
  @override
  String get worldName => 'Nome';
  @override
  String get worldVersion => 'Versione';
  @override
  String get difficulty => 'Difficoltà';
  @override
  String difficultyName(Difficulty d) => switch (d) {
    Difficulty.peaceful => 'Pacifica',
    Difficulty.easy => 'Facile',
    Difficulty.normal => 'Normale',
    Difficulty.hard => 'Difficile',
  };
  @override
  String hardcore(bool on) => on ? 'hardcore sì' : 'hardcore no';
  @override
  String get gameMode => 'Modalità';
  @override
  String gameModeName(GameMode m) => switch (m) {
    GameMode.survival => 'Sopravvivenza',
    GameMode.creative => 'Creativa',
    GameMode.adventure => 'Avventura',
    GameMode.spectator => 'Spettatore',
  };
  @override
  String get worldTime => 'Tempo';
  @override
  String dayLine(String day, int? hours) =>
      hours == null ? 'giorno $day' : 'giorno $day, $hours h di mondo';
  @override
  String get spawn => 'Spawn';
  @override
  String get seed => 'Seed';
  @override
  String get copySeed => 'Copia seed';
  @override
  String get propsTitle => 'Server';
  @override
  String get fromProperties => 'da server.properties';
  @override
  String get noProperties => 'server.properties non presente in questa versione.';
  @override
  String get propsNote => "Si modificano nel file, dall'app o in gioco. Qui sono in sola lettura.";
  @override
  String get motd => 'Messaggio (motd)';
  @override
  String get maxPlayers => 'Max giocatori';
  @override
  String get pvp => 'PvP';
  @override
  String yesNo(bool v) => v ? 'Sì' : 'No';
  @override
  String get whitelist => 'Whitelist';
  @override
  String onOff(bool v) => v ? 'Attiva' : 'Spenta';
  @override
  String names(int n) => n == 1 ? '1 nome' : '$n nomi';
  @override
  String get viewDistance => 'Distanza di vista';
  @override
  String get simulationDistance => 'Distanza di simulazione';
  @override
  String chunks(int n) => '$n chunk';
  @override
  String get statsTitle => 'Statistiche';
  @override
  String get noSessions => 'Nessuna sessione di gioco. Le statistiche partono dalla prima.';
  @override
  String get playHours => 'Ore in gioco';
  @override
  String get playHoursNote => 'somma delle sessioni conservate';
  @override
  String get hostHours => 'Ore di hosting';
  @override
  String get hostHoursNote => 'chi ha tenuto acceso il server';
  @override
  String get noRanking => 'Nessun dato disponibile.';
  @override
  String get sessionsTitle => 'Sessioni';
  @override
  String sessionsLabel(int n) => n == 1 ? 'sessione' : 'sessioni';
  @override
  String get average => 'Media';
  @override
  String get longest => 'La più lunga';
  @override
  String get lastOne => 'Ultima';
  @override
  String get ongoing => 'in corso';
  @override
  String keptNote(int n) => 'Conservate le ultime $n per server.';
  @override
  String get recentTitle => 'Storia recente';
  @override
  String get recentLabel => 'Ultime versioni';
  @override
  String get allHistory => 'Tutta la storia';
  @override
  String get spaceTitle => 'Storia e spazio';
  @override
  String get readOnly => 'sola lettura';
  @override
  String get keepTitle => 'Conservazione';
  @override
  String get hubRules => "Regole dell'hub, uguali per tutti i server.";
  @override
  String ownRules(String server, int last, int hours, int days) =>
      "Regole personalizzate per $server. Per gli altri server valgono quelle dell'hub: $last versioni, $hours ore, $days giorni.";
  @override
  String get versionsKept => 'Versioni conservate';
  @override
  String versionsRange(int n, String from, String to) => '$n, dalla $from alla $to';
  @override
  String spaceOf(String server) => 'Spazio di $server';
  @override
  String get hubFree => "Spazio libero sull'hub";
  @override
  String get hubDiskBar => "Disco dell'hub usato";
  @override
  String diskUsed(String pct, String minFree) =>
      'usato il $pct, sotto $minFree i salvataggi vengono rifiutati';
  @override
  String get adminChanges => 'Regole e pulizia sono gestite dagli admin.';
  @override
  String get editRules => 'Modifica';
  @override
  String playersCount(int n) => n == 1 ? '1 giocatore' : '$n giocatori';
  @override
  String playersLead(int online, int ops, bool whitelist, String gen, String? at) =>
      '$online online, $ops OP${whitelist ? ', whitelist attiva' : ''}. Statistiche dall\'ultimo salvataggio${at == null ? '' : ' ($at)'}.';
  @override
  String get searchPlayer => 'Cerca giocatore';
  @override
  String get sortBy => 'Ordina per';
  @override
  String get sortTime => 'Tempo';
  @override
  String get sortDeaths => 'Morti';
  @override
  String get sortMobs => 'Mob';
  @override
  String get sortDistance => 'Distanza';
  @override
  String get noPlayersTitle => 'Nessun giocatore';
  @override
  String get noPlayersText =>
      'I giocatori compaiono dopo la prima partita salvata sull\'hub. Nomi e statistiche provengono dai file del mondo.';
  @override
  String get playingNow => 'in gioco ora';
  @override
  String get hostShort => 'host';
  @override
  String get notWhitelisted => 'non in whitelist';
  @override
  String get online => 'Online';
  @override
  String get op => 'OP';
  @override
  String get outsideWhitelist => 'Fuori whitelist';
  @override
  String get playTime => 'Tempo di gioco';
  @override
  String playTimeValue(FormatStrings f, int ticks) => f.duration(Duration(seconds: ticks ~/ 20));
  @override
  String hoursValue(FormatStrings f, int ticks) => _hours(f, ticks);
  @override
  String get deaths => 'Morti';
  @override
  String get mobKills => 'Mob uccisi';
  @override
  String get distance => 'Distanza';
  @override
  String get distanceWalked => 'Distanza percorsa';
  @override
  String distanceValue(Lang l, int cm) => _distance(l, cm);
  @override
  String get boardsTitle => 'Classifiche';
  @override
  String get boardsNote => 'totali dall\'inizio del mondo';
  @override
  String get modsLabel => 'Mod';
  @override
  String get modsTotal => 'Totale';
  @override
  String loaderLabel(String? version) => version == null ? 'Loader' : 'Loader $version';
  @override
  String get bareLabel => 'Senza metadati';
  @override
  String get searchMods => 'Cerca per nome, autore o file';
  @override
  String get searchModsLabel => 'Cerca mod';
  @override
  String get sortMods => 'Ordina';
  @override
  String get sortName => 'Nome A–Z';
  @override
  String get sortSize => 'Dimensione';
  @override
  String get sortRecent => 'Aggiunte di recente';
  @override
  String filterAll(int n) => 'Tutte $n';
  @override
  String filterMeta(int n) => 'Con metadati $n';
  @override
  String filterBare(int n) => 'Senza metadati $n';
  @override
  String filterChanged(String head, int n) => 'Cambiate nell\'ultima versione $n';
  @override
  String get modsListLabel => 'Elenco mod';
  @override
  String get noMetaShort => 'nessun metadato';
  @override
  String shownOf(int n, int total) => '$n di $total';
  @override
  String get noModsTitle => 'Nessuna mod';
  @override
  String get noModsText => 'Nessun jar nella cartella mods/ dell\'ultima versione.';
  @override
  String get detailTitle => 'Dettaglio';
  @override
  String detailOf(String mod) => 'Dettaglio di $mod';
  @override
  String get closeDetail => 'Chiudi il dettaglio';
  @override
  String get authors => 'Autori';
  @override
  String get site => 'Sito';
  @override
  String openSite(String host) => 'Apri $host in una nuova scheda';
  @override
  String get license => 'Licenza';
  @override
  String get file => 'File';
  @override
  String get size => 'Dimensione';
  @override
  String get presentSince => 'Presente da';
  @override
  String updatedIn(String gen) => 'aggiornata in $gen';
  @override
  String sinceGen(String gen) => 'da $gen';
  @override
  String get modNote =>
      'Dati letti dal file della mod. La mod serve anche sul PC di chi entra e l\'app la installa automaticamente.';
  @override
  String get noMetaTitle => 'Nessun metadato';
  @override
  String get noMetaText =>
      'Il jar non dichiara nome, versione né autori, come accade con mod fatte in casa o ricompilate. La mod funziona comunque.';
}

final class _En implements ServerStrings {
  const _En();
  @override
  HistoryStrings get history => HistoryStrings.of(Lang.en);
  @override
  ServerAdminStrings get admin => ServerAdminStrings.of(Lang.en);
  @override
  String get crumb => 'Servers';
  @override
  String tabsLabel(String server) => 'Sections of server $server';
  @override
  String get tabOverview => 'Overview';
  @override
  String get tabPlayers => 'Players';
  @override
  String get tabMods => 'Mods';
  @override
  String get tabHistory => 'History';
  @override
  String get tabAdmin => 'Administration';
  @override
  String onHub(String size) => '$size on the hub';
  @override
  String zipHead(int n) => 'Download zip';
  @override
  String get loadError => 'Unable to read this data';
  @override
  String get noMatch => 'No results with these filters.';
  @override
  String changesLabel(int added, int changed, int removed) =>
      '$added added, $changed changed, $removed removed';
  @override
  String step(int i, int of) => 'Confirmation $i of $of';
  @override
  String get lockTitle => 'Session and address';
  @override
  String get lockPush => 'Saving';
  @override
  String get sessionSince => 'in session for ';
  @override
  String get pushSince => 'saving from the app for ';
  @override
  String onlineList(int n) => '$n online:';
  @override
  String host(String name) => '$name (host)';
  @override
  String get joinOn => 'Join at';
  @override
  String get fixedAddress => 'Fixed address, the same for everyone, even when the host changes';
  @override
  String get directIp => "Direct IP of the host's PC, if the name does not work";
  @override
  String get copyFixed => 'Copy fixed address';
  @override
  String get copyDirect => 'Copy direct IP';
  @override
  String portState(PortState s) => switch (s) {
    PortState.reachable => 'Reachable',
    PortState.blocked => 'Unreachable',
    PortState.pending => 'Testing',
    PortState.off => 'Test off',
  };
  @override
  String portText(PortState s, int port, String? at) => switch (s) {
    PortState.reachable =>
      at == null ? 'port $port checked by the hub' : 'port $port checked by the hub at $at',
    PortState.blocked => "port $port not reachable from the hub: check the host's firewall",
    PortState.pending => 'testing port $port',
    PortState.off => 'port test turned off in Admin › Sessions',
  };
  @override
  String get portRetry => 'Test again';
  @override
  String get forceRelease => 'Force release';
  @override
  String forceAdminNote(String who) =>
      "Ends $who's session: the server stops and the world stays on their PC. Requires two confirmations.";
  @override
  String forceMemberNote(String who) =>
      'Only an admin can force a live lock. Ask $who to close from the app.';
  @override
  String forceTitle(String server) => 'Force release of $server?';
  @override
  String forceBody1(String who, int players) =>
      "$who is hosting${players > 0 ? ' with $players online' : ''}. The server stops and the world stays on their PC: unsaved changes do not reach the hub.";
  @override
  String get forceContinue => 'Continue';
  @override
  String get forceTitle2 => 'Confirm forced release?';
  @override
  String forceBody2(String who, String head) =>
      "Whoever plays next starts from the last save on the hub. $who's later changes stay only on their PC.";
  @override
  String get releaseStale => 'Release the lock';
  @override
  String get releaseStaleNote => 'Anyone can release a lock that is not responding.';
  @override
  String releaseStaleTitle(String who) => "Release $who's lock?";
  @override
  String releaseStaleBody(String who, String head) =>
      "Whoever plays next starts from the last save on the hub. If $who's app is still open, later changes stay on their PC.";
  @override
  String released(String server) => '$server lock released';
  @override
  String staleSince(String? since) => since == null
      ? 'no signal from their PC (limit 90 s)'
      : 'no signal from their PC for $since (limit 90 s)';
  @override
  String staleTitle(String who) => "$who's app may have closed unexpectedly";
  @override
  String staleText(String head, String? at, String who) =>
      "The hub keeps the last save${at == null ? '' : ' (at $at)'}. Once the lock is released, whoever plays next starts from there; later changes stay only on $who's PC.";
  @override
  String get nobodyHosts => 'Nobody is hosting.';
  @override
  String lastSession(String who, String start, String? end) =>
      'Nobody is hosting. Last session: $who, $start${end == null ? '' : '–$end'}.';
  @override
  String get freeHowTo1 => 'Open the app and press ';
  @override
  String get play => 'Play';
  @override
  String freeHowTo2(String? address) =>
      ': the app downloads the latest version and your PC becomes the host.${address == null ? '' : ' Other players join at $address.'}';
  @override
  String get worldTitle => 'World';
  @override
  String fromLevel(String gen) => 'from level.dat';
  @override
  String get noSaveYet => 'Empty: the data arrives with the first save from the app.';
  @override
  String get noLevel => 'level.dat is missing or unreadable in this version.';
  @override
  String get worldName => 'Name';
  @override
  String get worldVersion => 'Version';
  @override
  String get difficulty => 'Difficulty';
  @override
  String difficultyName(Difficulty d) => switch (d) {
    Difficulty.peaceful => 'Peaceful',
    Difficulty.easy => 'Easy',
    Difficulty.normal => 'Normal',
    Difficulty.hard => 'Hard',
  };
  @override
  String hardcore(bool on) => on ? 'hardcore yes' : 'hardcore no';
  @override
  String get gameMode => 'Game mode';
  @override
  String gameModeName(GameMode m) => switch (m) {
    GameMode.survival => 'Survival',
    GameMode.creative => 'Creative',
    GameMode.adventure => 'Adventure',
    GameMode.spectator => 'Spectator',
  };
  @override
  String get worldTime => 'Time';
  @override
  String dayLine(String day, int? hours) =>
      hours == null ? 'day $day' : 'day $day, $hours h of world time';
  @override
  String get spawn => 'Spawn';
  @override
  String get seed => 'Seed';
  @override
  String get copySeed => 'Copy seed';
  @override
  String get propsTitle => 'Server';
  @override
  String get fromProperties => 'from server.properties';
  @override
  String get noProperties => 'server.properties is not in this version.';
  @override
  String get propsNote => 'Changed in the file, from the app or in game. Read-only here.';
  @override
  String get motd => 'Message (motd)';
  @override
  String get maxPlayers => 'Max players';
  @override
  String get pvp => 'PvP';
  @override
  String yesNo(bool v) => v ? 'Yes' : 'No';
  @override
  String get whitelist => 'Whitelist';
  @override
  String onOff(bool v) => v ? 'On' : 'Off';
  @override
  String names(int n) => n == 1 ? '1 name' : '$n names';
  @override
  String get viewDistance => 'View distance';
  @override
  String get simulationDistance => 'Simulation distance';
  @override
  String chunks(int n) => n == 1 ? '1 chunk' : '$n chunks';
  @override
  String get statsTitle => 'Statistics';
  @override
  String get noSessions => 'No game sessions yet. Statistics start with the first one.';
  @override
  String get playHours => 'Hours in game';
  @override
  String get playHoursNote => 'sum of the kept sessions';
  @override
  String get hostHours => 'Hosting hours';
  @override
  String get hostHoursNote => 'who kept the server running';
  @override
  String get noRanking => 'No data yet.';
  @override
  String get sessionsTitle => 'Sessions';
  @override
  String sessionsLabel(int n) => n == 1 ? 'session' : 'sessions';
  @override
  String get average => 'Average';
  @override
  String get longest => 'Longest';
  @override
  String get lastOne => 'Last';
  @override
  String get ongoing => 'ongoing';
  @override
  String keptNote(int n) => 'The last $n per server are kept.';
  @override
  String get recentTitle => 'Recent history';
  @override
  String get recentLabel => 'Latest versions';
  @override
  String get allHistory => 'All history';
  @override
  String get spaceTitle => 'History and space';
  @override
  String get readOnly => 'read only';
  @override
  String get keepTitle => 'Retention';
  @override
  String get hubRules => "The hub's rules, the same for every server.";
  @override
  String ownRules(String server, int last, int hours, int days) =>
      "Custom rules for $server. The other servers use the hub's: $last versions, $hours hours, $days days.";
  @override
  String get versionsKept => 'Versions kept';
  @override
  String versionsRange(int n, String from, String to) => '$n, from $from to $to';
  @override
  String spaceOf(String server) => '$server space';
  @override
  String get hubFree => 'Free space on the hub';
  @override
  String get hubDiskBar => "Hub's disk used";
  @override
  String diskUsed(String pct, String minFree) => '$pct used, below $minFree saves are refused';
  @override
  String get adminChanges => 'Rules and cleanup are managed by admins.';
  @override
  String get editRules => 'Edit';
  @override
  String playersCount(int n) => n == 1 ? '1 player' : '$n players';
  @override
  String playersLead(int online, int ops, bool whitelist, String gen, String? at) =>
      '$online online, $ops OP${whitelist ? ', whitelist on' : ''}. Statistics from the last save${at == null ? '' : ' ($at)'}.';
  @override
  String get searchPlayer => 'Search player';
  @override
  String get sortBy => 'Sort by';
  @override
  String get sortTime => 'Time';
  @override
  String get sortDeaths => 'Deaths';
  @override
  String get sortMobs => 'Mobs';
  @override
  String get sortDistance => 'Distance';
  @override
  String get noPlayersTitle => 'No players yet';
  @override
  String get noPlayersText =>
      'Players appear after the first game saved to the hub. Names and statistics come from the world files.';
  @override
  String get playingNow => 'playing now';
  @override
  String get hostShort => 'host';
  @override
  String get notWhitelisted => 'not whitelisted';
  @override
  String get online => 'Online';
  @override
  String get op => 'OP';
  @override
  String get outsideWhitelist => 'Not whitelisted';
  @override
  String get playTime => 'Play time';
  @override
  String playTimeValue(FormatStrings f, int ticks) => f.duration(Duration(seconds: ticks ~/ 20));
  @override
  String hoursValue(FormatStrings f, int ticks) => _hours(f, ticks);
  @override
  String get deaths => 'Deaths';
  @override
  String get mobKills => 'Mobs killed';
  @override
  String get distance => 'Distance';
  @override
  String get distanceWalked => 'Distance travelled';
  @override
  String distanceValue(Lang l, int cm) => _distance(l, cm);
  @override
  String get boardsTitle => 'Leaderboards';
  @override
  String get boardsNote => 'totals since the world began';
  @override
  String get modsLabel => 'Mods';
  @override
  String get modsTotal => 'Total';
  @override
  String loaderLabel(String? version) => version == null ? 'Loader' : 'Loader $version';
  @override
  String get bareLabel => 'Without metadata';
  @override
  String get searchMods => 'Search by name, author or file';
  @override
  String get searchModsLabel => 'Search mods';
  @override
  String get sortMods => 'Sort';
  @override
  String get sortName => 'Name A–Z';
  @override
  String get sortSize => 'Size';
  @override
  String get sortRecent => 'Recently added';
  @override
  String filterAll(int n) => 'All $n';
  @override
  String filterMeta(int n) => 'With metadata $n';
  @override
  String filterBare(int n) => 'Without metadata $n';
  @override
  String filterChanged(String head, int n) => 'Changed in the latest version $n';
  @override
  String get modsListLabel => 'Mod list';
  @override
  String get noMetaShort => 'no metadata';
  @override
  String shownOf(int n, int total) => '$n of $total';
  @override
  String get noModsTitle => 'No mods';
  @override
  String get noModsText => 'No jars in the mods/ folder of the latest version.';
  @override
  String get detailTitle => 'Details';
  @override
  String detailOf(String mod) => '$mod details';
  @override
  String get closeDetail => 'Close the details';
  @override
  String get authors => 'Authors';
  @override
  String get site => 'Website';
  @override
  String openSite(String host) => 'Open $host in a new tab';
  @override
  String get license => 'Licence';
  @override
  String get file => 'File';
  @override
  String get size => 'Size';
  @override
  String get presentSince => 'Present since';
  @override
  String updatedIn(String gen) => 'updated in $gen';
  @override
  String sinceGen(String gen) => 'since $gen';
  @override
  String get modNote =>
      'Data read from the mod file. Players who join need it too, and the app installs it automatically.';
  @override
  String get noMetaTitle => 'No metadata';
  @override
  String get noMetaText =>
      'The jar declares no name, version or authors, as with home-made or rebuilt mods. The mod works anyway.';
}
