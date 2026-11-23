// Testi della schermata della sessione: stato, salvataggi, giocatori,
// console, avvisi gravi e notifiche del desktop durante il gioco.
import 'package:ms_l10n/ms_l10n.dart';

String _two(int v) => v.toString().padLeft(2, '0');

/// Ora `hh:mm`.
String hhmm(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';

/// Ora `hh:mm:ss`.
String hhmmss(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

/// Conto alla rovescia `mm:ss`.
String mmss(Duration d) {
  final s = d.inSeconds.clamp(0, 359999);
  return '${_two(s ~/ 60)}:${_two(s % 60)}';
}

abstract final class SessionStrings {
  static SessionStrings of(Lang l) => switch (l) {
    Lang.it => const _It(),
    Lang.en => const _En(),
  };

  // schede del server
  String get tabOverview;
  String get tabHistory;
  String get tabsLabel;

  // stato
  String get statusLabel;
  String get pillSyncing;
  String get pillStarting;
  String get pillRunning;
  String get pillSaving;
  String pillUploading(int percent);
  String get pillStopping;
  String get pillFinalPush;
  String get pillStopped;
  String get pillEnded;
  String get pillFailed;
  String headSyncing(String server);
  String get subSyncing;
  String headStarting(String server);
  String get subStarting;
  String headRunning(String server);
  String get subRunning;
  String get headSaving;
  String get subSaving;
  String get headUploading;
  String get subUploading;
  String headStopping(String server);
  String get subStopping;
  String get headStopped;
  String subStopped(String server);
  String headEnded(String server);
  String get subEnded;
  String headFailed(String server);
  String get headConflict;
  String get subConflict;
  String sinceStarted(String duration, String time);
  String get stepsLabel;
  String get stepSync;
  String get stepStart;
  String get stepPlay;
  String get stepSave;
  String get stepHub;
  String get stepStop;
  String get saveNow;
  String get saveNowTip;
  String get saveQueued;
  String get stopAndSave;
  String get stopAndSaveTip;
  String get stopping;
  String get backToServer;
  String get retry;
  String get playAgain;

  // pannello sessione
  String get panelSession;
  String get onHub;
  String onHubValue(String ago, String time);
  String uploadingValue(int percent);
  String get nothingYet;
  String get nextSave;
  String inTime(String mmss);
  String get autostopTerm;
  String autostopValue(int minutes);
  String get autostopOff;
  String uploadMeta(String done, String total, String speed);
  String secondsLeft(int s);
  String get uploadProgress;
  String get lagTitle;
  String lagText(double seconds);

  // indirizzi
  String get panelAddress;
  String get directIp;
  String get copy;
  String copyAddress(String a);
  String get copyDirectIp;
  String get copied;
  String get noAddress;
  String portState(String state);
  String portChecked(String ago);
  String portPendingMeta(int port);
  String portBlockedHint(int port);
  String get portOffMeta;
  String get portRetry;
  String get portRetryTip;
  String get portRetrying;
  String get portTooSoon;
  String get portNotLocked;
  String get portFeatureOff;

  // giocatori
  String get panelOnline;
  String playersCount(int n, int? max);
  String since(String duration);
  String get nobodyYet;
  String avatarOf(String name);

  // server
  String get panelServer;
  String get launchTerm;
  String get javaTerm;
  String get memoryTerm;
  String get portTerm;
  String get folderTerm;
  String get memoryFromScript;
  String get javaFromScript;
  String gib(double g);

  // console
  String get consoleLabel;
  String get filterLabel;
  String get filterAll;
  String get filterWarn;
  String get filterErr;
  String get searchLabel;
  String get searchHint;
  String results(int n);
  String get copyLog;
  String liveLabel(int n);
  String get commandLabel;
  String get commandHint;
  String get send;
  String get quick;
  String note(String kind, List<Object?> args);

  // avvisi recenti
  String get panelNotices;
  String noticeText(String code, List<String> paths, Strings common);

  // avvisi gravi
  String lockLostTitle(String server);
  String lockLostText(String server);
  String spaceGoneTitle(String server);
  String spaceGoneText(String server);
  String get hubFullTitle;
  String get hubFullText;
  String get safeOnHub;
  String safeOnHubValue(String? time);
  String get onlyHere;
  String onlyHereValue(String folder);
  String get whatToDo;
  String get lockLostTodo;
  String get details;
  String get detailsLabel;
  String get hubLostTitle;
  String get hubLostText;
  String get hubLostKeepOpen;
  String get hubBackTitle;
  String get hubBackText;

  // notifiche del desktop
  String get notifySaved;
  String notifyOpened(String who);
  String get notifyFree;
  String notifyCrashed(bool restarting);
  String notifyAlert(String kind, String server);

  // tempi
  String duration(Duration d);
  String ago(Duration d);
}

final class _It implements SessionStrings {
  const _It();
  @override
  String get tabOverview => 'Panoramica';
  @override
  String get tabHistory => 'Storia';
  @override
  String get tabsLabel => 'Sezioni del server';
  @override
  String get statusLabel => 'Stato della sessione';
  @override
  String get pillSyncing => 'Aggiornamento';
  @override
  String get pillStarting => 'Avvio';
  @override
  String get pillRunning => 'In gioco';
  @override
  String get pillSaving => 'Salvataggio';
  @override
  String pillUploading(int percent) => 'Caricamento $percent%';
  @override
  String get pillStopping => 'Arresto';
  @override
  String get pillFinalPush => 'Caricamento';
  @override
  String get pillStopped => 'Arrestato';
  @override
  String get pillEnded => 'Terminata';
  @override
  String get pillFailed => 'Non avviata';
  @override
  String headSyncing(String server) => 'Preparazione di $server…';
  @override
  String get subSyncing => 'Acquisizione del server e download degli aggiornamenti dall\'hub.';
  @override
  String headStarting(String server) => 'Avvio di $server…';
  @override
  String get subStarting => 'Server in avvio. I giocatori potranno entrare a breve.';
  @override
  String headRunning(String server) => '$server in esecuzione su questo PC';
  @override
  String get subRunning => 'I giocatori possono entrare.';
  @override
  String get headSaving => 'Salvataggio del mondo…';
  @override
  String get subSaving => 'Il gioco continua. Il server scrive su disco per qualche secondo.';
  @override
  String get headUploading => 'Caricamento del mondo sull\'hub…';
  @override
  String get subUploading =>
      'Il gioco continua. In caso di chiusura, il caricamento viene completato prima.';
  @override
  String headStopping(String server) => 'Chiusura di $server…';
  @override
  String get subStopping =>
      'Salvataggio, caricamento sull\'hub e rilascio del server. Non spegnere il PC.';
  @override
  String get headStopped => 'Server arrestato';
  @override
  String subStopped(String server) => 'Il controllo di $server è passato a un altro PC.';
  @override
  String headEnded(String server) => '$server di nuovo libero';
  @override
  String get subEnded => 'Mondo salvato sull\'hub.';
  @override
  String headFailed(String server) => 'Impossibile avviare $server';
  @override
  String get headConflict => 'Modifiche non salvate su questo PC';
  @override
  String get subConflict => 'Scegli cosa tenere prima di giocare.';
  @override
  String sinceStarted(String duration, String time) => 'da $duration (avviata alle $time)';
  @override
  String get stepsLabel => 'Fasi della sessione';
  @override
  String get stepSync => 'Aggiornamento';
  @override
  String get stepStart => 'Avvio';
  @override
  String get stepPlay => 'In gioco';
  @override
  String get stepSave => 'Salvataggio';
  @override
  String get stepHub => 'Caricamento';
  @override
  String get stepStop => 'Arresto';
  @override
  String get saveNow => 'Salva ora';
  @override
  String get saveNowTip => 'Salva ora e carica sull\'hub';
  @override
  String get saveQueued => 'Salvataggio al termine del caricamento in corso.';
  @override
  String get stopAndSave => 'Arresta e salva';
  @override
  String get stopAndSaveTip => 'Salva, carica sull\'hub e arresta il server';
  @override
  String get stopping => 'Arresto…';
  @override
  String get backToServer => 'Torna al server';
  @override
  String get retry => 'Riprova';
  @override
  String get playAgain => 'Gioca ancora';
  @override
  String get panelSession => 'Sessione';
  @override
  String get onHub => 'Sull\'hub';
  @override
  String onHubValue(String ago, String time) => '$time ($ago)';
  @override
  String uploadingValue(int percent) => 'in caricamento… $percent%';
  @override
  String get nothingYet => 'nessun salvataggio';
  @override
  String get nextSave => 'Prossimo salvataggio';
  @override
  String inTime(String mmss) => 'tra $mmss';
  @override
  String get autostopTerm => 'Arresto automatico';
  @override
  String autostopValue(int minutes) => '$minutes min senza giocatori';
  @override
  String get autostopOff => 'disattivato';
  @override
  String uploadMeta(String done, String total, String speed) => '$done di $total, $speed/s';
  @override
  String secondsLeft(int s) => 'circa $s s';
  @override
  String get uploadProgress => 'Caricamento sull\'hub';
  @override
  String get lagTitle => 'Server sovraccarico';
  @override
  String lagText(double seconds) =>
      'Ritardo di ${seconds.toStringAsFixed(1).replaceAll('.', ',')} s: i giocatori possono notare scatti. Chiudi i '
      'programmi pesanti o riduci la distanza visiva.';
  @override
  String get panelAddress => 'Come entrare';
  @override
  String get directIp => 'IP diretto';
  @override
  String get copy => 'Copia';
  @override
  String copyAddress(String a) => 'Copia indirizzo $a';
  @override
  String get copyDirectIp => 'Copia IP diretto';
  @override
  String get copied => 'Copiato negli appunti';
  @override
  String get noAddress => 'Indirizzo di questo PC non trovato. Controlla la rete.';
  @override
  String portState(String state) => switch (state) {
    'reachable' => 'Porta raggiungibile',
    'blocked' => 'Porta chiusa',
    'off' => 'Verifica della porta disattivata',
    _ => 'Verifica della porta…',
  };
  @override
  String portChecked(String ago) => 'verificata dall\'hub $ago';
  @override
  String portPendingMeta(int port) => 'connessione dall\'hub alla porta $port in corso';
  @override
  String portBlockedHint(int port) =>
      'L\'hub non riesce a collegarsi alla porta $port di questo PC: i giocatori potrebbero non '
      'riuscire a entrare. Controlla il firewall e che il server ascolti su questa porta.';
  @override
  String get portOffMeta => 'disattivata da un admin';
  @override
  String get portRetry => 'Riprova';
  @override
  String get portRetryTip => 'Ripeti la verifica della porta';
  @override
  String get portRetrying => 'Nuova verifica della porta in corso.';
  @override
  String get portTooSoon => 'Verifica appena eseguita. Attendi qualche secondo.';
  @override
  String get portNotLocked =>
      'Il server non è in esecuzione su questo PC: nessuna porta da verificare.';
  @override
  String get portFeatureOff => 'Verifica della porta disattivata sull\'hub.';
  @override
  String get panelOnline => 'Online';
  @override
  String playersCount(int n, int? max) => max == null ? '$n' : '$n / $max';
  @override
  String since(String duration) => 'da $duration';
  @override
  String get nobodyYet => 'Nessun giocatore. Condividi l\'indirizzo qui sopra.';
  @override
  String avatarOf(String name) => 'Avatar di $name';
  @override
  String get panelServer => 'Server';
  @override
  String get launchTerm => 'Avvio';
  @override
  String get javaTerm => 'Java';
  @override
  String get memoryTerm => 'Memoria';
  @override
  String get portTerm => 'Porta';
  @override
  String get folderTerm => 'Cartella';
  @override
  String get memoryFromScript => 'automatica';
  @override
  String get javaFromScript => 'automatico';
  @override
  String gib(double g) => '${g == g.roundToDouble() ? g.toInt() : g.toStringAsFixed(1)} GB';
  @override
  String get consoleLabel => 'Console del server';
  @override
  String get filterLabel => 'Filtra per livello';
  @override
  String get filterAll => 'Tutto';
  @override
  String get filterWarn => 'Avvisi + errori';
  @override
  String get filterErr => 'Errori';
  @override
  String get searchLabel => 'Cerca nella console';
  @override
  String get searchHint => 'Cerca';
  @override
  String results(int n) => n == 1 ? '1 risultato' : '$n risultati';
  @override
  String get copyLog => 'Copia tutto il log';
  @override
  String liveLabel(int n) =>
      n == 1 ? '1 riga nuova, torna in fondo' : '$n righe nuove, torna in fondo';
  @override
  String get commandLabel => 'Comando per il server';
  @override
  String get commandHint => 'Comando, es. say ciao';
  @override
  String get send => 'Invia';
  @override
  String get quick => 'Comandi rapidi';
  @override
  String note(String kind, List<Object?> a) => switch (kind) {
    'starting' => _starting('Avvio', 'con Java', a, gib),
    'ready' => '[MineSync] Server pronto: i giocatori possono entrare',
    'autosaved' => '[MineSync] Salvataggio automatico completato',
    'uploaded' => '[MineSync] Salvato sull\'hub',
    'crashed' =>
      '[MineSync] Il server si è chiuso in modo imprevisto (codice ${a.firstOrNull ?? '?'})',
    'stopping' => '[MineSync] Arresto: salvataggio, caricamento sull\'hub e rilascio del server',
    'recovered' => '[MineSync] Modifiche locali in sospeso caricate',
    _ => '[MineSync]',
  };
  @override
  String get panelNotices => 'Note della sessione';
  @override
  String noticeText(String code, List<String> paths, Strings common) => switch (code) {
    'keptMine' => 'Le modifiche locali sono sull\'hub come nuova versione.',
    'unreadableKept' =>
      '${paths.length} file in uso non letti: mantenuta la versione precedente '
          '(${paths.firstOrNull ?? ''}).',
    'autostop' => 'Nessun giocatore da tempo: server arrestato dopo il salvataggio.',
    _ => common.playWarning(code),
  };
  @override
  String lockLostTitle(String server) => 'Controllo di $server perso: server arrestato';
  @override
  String lockLostText(String server) =>
      'Un altro PC ha forzato $server. Il server è stato arrestato subito per evitare due mondi '
      'diversi.';
  @override
  String spaceGoneTitle(String server) => '$server è stato eliminato dall\'hub';
  @override
  String spaceGoneText(String server) =>
      'Un admin ha eliminato $server durante la sessione. Il server è stato arrestato e la copia '
      'locale resta su questo PC.';
  @override
  String get hubFullTitle => 'Hub pieno: i salvataggi restano su questo PC';
  @override
  String get hubFullText =>
      'Il gioco continua. Il caricamento riprende quando un admin libera spazio sull\'hub.';
  @override
  String get safeOnHub => 'Al sicuro sull\'hub';
  @override
  String safeOnHubValue(String? time) => time == null
      ? 'l\'ultima versione prima di questa sessione'
      : 'tutto fino al salvataggio delle $time';
  @override
  String get onlyHere => 'Solo su questo PC';
  @override
  String onlyHereValue(String folder) => 'le modifiche successive, nella cartella $folder';
  @override
  String get whatToDo => 'Cosa fare';
  @override
  String get lockLostTodo =>
      'non riavviare. Contatta chi ha forzato: al prossimo avvio potrai scegliere se tenere o '
      'scartare queste modifiche.';
  @override
  String get details => 'Dettagli';
  @override
  String get detailsLabel => 'Copia i dettagli per un admin';
  @override
  String get hubLostTitle => 'Hub non raggiungibile: il gioco continua';
  @override
  String get hubLostText =>
      'La partita può continuare. I salvataggi restano su questo PC e vengono caricati quando '
      'l\'hub torna raggiungibile.';
  @override
  String get hubLostKeepOpen =>
      'Se possibile, non chiudere MineSync finché l\'hub non torna raggiungibile.';
  @override
  String get hubBackTitle => 'Hub di nuovo raggiungibile';
  @override
  String get hubBackText => 'I salvataggi in attesa sono sull\'hub.';
  @override
  String get notifySaved => 'Salvato sull\'hub';
  @override
  String notifyOpened(String who) => '$who ha avviato il server. Puoi entrare.';
  @override
  String get notifyFree => 'Il server è libero.';
  @override
  String notifyCrashed(bool restarting) => restarting
      ? 'Il server si è chiuso in modo imprevisto. Riavvio in corso.'
      : 'Il server si è chiuso in modo imprevisto e non verrà riavviato automaticamente.';
  @override
  String notifyAlert(String kind, String server) => switch (kind) {
    'lockLost' => 'Controllo di $server perso: server arrestato.',
    'spaceGone' => '$server eliminato dall\'hub: server arrestato.',
    _ => 'Hub pieno: i salvataggi restano su questo PC.',
  };
  @override
  String duration(Duration d) {
    if (d.inMinutes < 1) return 'meno di 1 min';
    if (d.inHours < 1) return '${d.inMinutes} min';
    final m = d.inMinutes % 60;
    return m == 0 ? '${d.inHours} h' : '${d.inHours} h ${_two(m)} min';
  }

  @override
  String ago(Duration d) => d.inMinutes < 1 ? 'adesso' : '${duration(d)} fa';
}

final class _En implements SessionStrings {
  const _En();
  @override
  String get tabOverview => 'Overview';
  @override
  String get tabHistory => 'History';
  @override
  String get tabsLabel => 'Server sections';
  @override
  String get statusLabel => 'Session status';
  @override
  String get pillSyncing => 'Updating';
  @override
  String get pillStarting => 'Starting';
  @override
  String get pillRunning => 'Playing';
  @override
  String get pillSaving => 'Saving';
  @override
  String pillUploading(int percent) => 'Uploading $percent%';
  @override
  String get pillStopping => 'Stopping';
  @override
  String get pillFinalPush => 'Uploading';
  @override
  String get pillStopped => 'Stopped';
  @override
  String get pillEnded => 'Ended';
  @override
  String get pillFailed => 'Not started';
  @override
  String headSyncing(String server) => 'Preparing $server…';
  @override
  String get subSyncing => 'Taking control of the server and downloading updates from the hub.';
  @override
  String headStarting(String server) => 'Starting $server…';
  @override
  String get subStarting => 'Server starting. Players can join shortly.';
  @override
  String headRunning(String server) => '$server running on this PC';
  @override
  String get subRunning => 'Players can join.';
  @override
  String get headSaving => 'Saving the world…';
  @override
  String get subSaving => 'The game continues. The server writes to disk for a few seconds.';
  @override
  String get headUploading => 'Uploading the world to the hub…';
  @override
  String get subUploading =>
      'The game continues. If the server is closed, the upload completes first.';
  @override
  String headStopping(String server) => 'Closing $server…';
  @override
  String get subStopping => 'Saving, uploading to the hub and freeing the server. Keep the PC on.';
  @override
  String get headStopped => 'Server stopped';
  @override
  String subStopped(String server) => 'Control of $server has moved to another PC.';
  @override
  String headEnded(String server) => '$server is free again';
  @override
  String get subEnded => 'World saved to the hub.';
  @override
  String headFailed(String server) => 'Unable to start $server';
  @override
  String get headConflict => 'Unsaved changes on this PC';
  @override
  String get subConflict => 'Choose what to keep before playing.';
  @override
  String sinceStarted(String duration, String time) => 'for $duration (started at $time)';
  @override
  String get stepsLabel => 'Session steps';
  @override
  String get stepSync => 'Update';
  @override
  String get stepStart => 'Start';
  @override
  String get stepPlay => 'Playing';
  @override
  String get stepSave => 'Saving';
  @override
  String get stepHub => 'Uploading';
  @override
  String get stepStop => 'Stop';
  @override
  String get saveNow => 'Save now';
  @override
  String get saveNowTip => 'Save now and upload to the hub';
  @override
  String get saveQueued => 'Save queued until the current upload finishes.';
  @override
  String get stopAndSave => 'Stop and save';
  @override
  String get stopAndSaveTip => 'Save, upload to the hub and stop the server';
  @override
  String get stopping => 'Stopping…';
  @override
  String get backToServer => 'Back to the server';
  @override
  String get retry => 'Try again';
  @override
  String get playAgain => 'Play again';
  @override
  String get panelSession => 'Session';
  @override
  String get onHub => 'On the hub';
  @override
  String onHubValue(String ago, String time) => '$time ($ago)';
  @override
  String uploadingValue(int percent) => 'uploading… $percent%';
  @override
  String get nothingYet => 'no saves yet';
  @override
  String get nextSave => 'Next save';
  @override
  String inTime(String mmss) => 'in $mmss';
  @override
  String get autostopTerm => 'Auto shutdown';
  @override
  String autostopValue(int minutes) => 'after $minutes min with no players';
  @override
  String get autostopOff => 'off';
  @override
  String uploadMeta(String done, String total, String speed) => '$done of $total, $speed/s';
  @override
  String secondsLeft(int s) => 'about $s s';
  @override
  String get uploadProgress => 'Uploading to the hub';
  @override
  String get lagTitle => 'Server overloaded';
  @override
  String lagText(double seconds) =>
      '${seconds.toStringAsFixed(1)} s behind: players may notice stutters. Close heavy programs or lower the '
      'view distance.';
  @override
  String get panelAddress => 'How to join';
  @override
  String get directIp => 'Direct IP';
  @override
  String get copy => 'Copy';
  @override
  String copyAddress(String a) => 'Copy address $a';
  @override
  String get copyDirectIp => 'Copy direct IP';
  @override
  String get copied => 'Copied to the clipboard';
  @override
  String get noAddress => 'Address of this PC not found. Check the network.';
  @override
  String portState(String state) => switch (state) {
    'reachable' => 'Port reachable',
    'blocked' => 'Port closed',
    'off' => 'Port test off',
    _ => 'Testing the port…',
  };
  @override
  String portChecked(String ago) => 'tested by the hub $ago';
  @override
  String portPendingMeta(int port) => 'the hub is trying to connect to $port';
  @override
  String portBlockedHint(int port) =>
      'The hub cannot connect to port $port on this PC: players may not be able to join. Check '
      'the firewall and that the server listens on this port.';
  @override
  String get portOffMeta => 'switched off by an admin';
  @override
  String get portRetry => 'Try again';
  @override
  String get portRetryTip => 'Run the port test again';
  @override
  String get portRetrying => 'Testing the port again.';
  @override
  String get portTooSoon => 'Test just run. Wait a few seconds.';
  @override
  String get portNotLocked => 'The server is not running on this PC: no port to test.';
  @override
  String get portFeatureOff => 'The port test is switched off on the hub.';
  @override
  String get panelOnline => 'Online';
  @override
  String playersCount(int n, int? max) => max == null ? '$n' : '$n / $max';
  @override
  String since(String duration) => 'for $duration';
  @override
  String get nobodyYet => 'No players. Share the address above.';
  @override
  String avatarOf(String name) => '$name\'s avatar';
  @override
  String get panelServer => 'Server';
  @override
  String get launchTerm => 'Launch';
  @override
  String get javaTerm => 'Java';
  @override
  String get memoryTerm => 'Memory';
  @override
  String get portTerm => 'Port';
  @override
  String get folderTerm => 'Folder';
  @override
  String get memoryFromScript => 'automatic';
  @override
  String get javaFromScript => 'automatic';
  @override
  String gib(double g) => '${g == g.roundToDouble() ? g.toInt() : g.toStringAsFixed(1)} GB';
  @override
  String get consoleLabel => 'Server console';
  @override
  String get filterLabel => 'Filter by level';
  @override
  String get filterAll => 'All';
  @override
  String get filterWarn => 'Warnings + errors';
  @override
  String get filterErr => 'Errors';
  @override
  String get searchLabel => 'Search the console';
  @override
  String get searchHint => 'Search';
  @override
  String results(int n) => n == 1 ? '1 result' : '$n results';
  @override
  String get copyLog => 'Copy the whole log';
  @override
  String liveLabel(int n) => n == 1 ? '1 new line, jump to latest' : '$n new lines, jump to latest';
  @override
  String get commandLabel => 'Server command';
  @override
  String get commandHint => 'Command, e.g. say hi';
  @override
  String get send => 'Send';
  @override
  String get quick => 'Quick commands';
  @override
  String note(String kind, List<Object?> a) => switch (kind) {
    'starting' => _starting('Starting', 'with Java', a, gib),
    'ready' => '[MineSync] Server ready: players can join',
    'autosaved' => '[MineSync] Autosave completed',
    'uploaded' => '[MineSync] Saved to the hub',
    'crashed' => '[MineSync] The server closed unexpectedly (code ${a.firstOrNull ?? '?'})',
    'stopping' => '[MineSync] Stopping: saving, uploading to the hub and freeing the server',
    'recovered' => '[MineSync] Pending local changes uploaded',
    _ => '[MineSync]',
  };
  @override
  String get panelNotices => 'Session notes';
  @override
  String noticeText(String code, List<String> paths, Strings common) => switch (code) {
    'keptMine' => 'The local changes are on the hub as a new version.',
    'unreadableKept' =>
      '${paths.length} files in use could not be read: previous version kept '
          '(${paths.firstOrNull ?? ''}).',
    'autostop' => 'No players for a while: server stopped after saving.',
    _ => common.playWarning(code),
  };
  @override
  String lockLostTitle(String server) => 'Control of $server lost: server stopped';
  @override
  String lockLostText(String server) =>
      'Another PC forced $server. The server was stopped immediately to avoid two different '
      'worlds.';
  @override
  String spaceGoneTitle(String server) => '$server was deleted from the hub';
  @override
  String spaceGoneText(String server) =>
      'An admin deleted $server during the session. The server was stopped and the local copy '
      'stays on this PC.';
  @override
  String get hubFullTitle => 'Hub full: saves stay on this PC';
  @override
  String get hubFullText =>
      'The game continues. Uploads resume when an admin frees space on the hub.';
  @override
  String get safeOnHub => 'Safe on the hub';
  @override
  String safeOnHubValue(String? time) =>
      time == null ? 'the last version before this session' : 'everything up to the save at $time';
  @override
  String get onlyHere => 'Only on this PC';
  @override
  String onlyHereValue(String folder) => 'later changes, in the folder $folder';
  @override
  String get whatToDo => 'What to do';
  @override
  String get lockLostTodo =>
      'do not restart. Contact whoever forced it: on the next start you can choose whether to '
      'keep or discard these changes.';
  @override
  String get details => 'Details';
  @override
  String get detailsLabel => 'Copy the details for an admin';
  @override
  String get hubLostTitle => 'Hub not reachable: the game continues';
  @override
  String get hubLostText =>
      'The game can continue. Saves stay on this PC and are uploaded when the hub is reachable '
      'again.';
  @override
  String get hubLostKeepOpen => 'If possible, keep MineSync open until the hub is reachable again.';
  @override
  String get hubBackTitle => 'Hub reachable again';
  @override
  String get hubBackText => 'The pending saves are on the hub.';
  @override
  String get notifySaved => 'Saved to the hub';
  @override
  String notifyOpened(String who) => '$who started the server. You can join.';
  @override
  String get notifyFree => 'The server is free.';
  @override
  String notifyCrashed(bool restarting) => restarting
      ? 'The server closed unexpectedly. Restarting.'
      : 'The server closed unexpectedly and will not restart automatically.';
  @override
  String notifyAlert(String kind, String server) => switch (kind) {
    'lockLost' => 'Control of $server lost: server stopped.',
    'spaceGone' => '$server deleted from the hub: server stopped.',
    _ => 'Hub full: saves stay on this PC.',
  };
  @override
  String duration(Duration d) {
    if (d.inMinutes < 1) return 'less than 1 min';
    if (d.inHours < 1) return '${d.inMinutes} min';
    final m = d.inMinutes % 60;
    return m == 0 ? '${d.inHours} h' : '${d.inHours} h ${_two(m)} min';
  }

  @override
  String ago(Duration d) => d.inMinutes < 1 ? 'just now' : '${duration(d)} ago';
}

/// Nota di avvio in console: «[MineSync] Avvio con Java 21 (Fabric, 6,0 GB)».
/// [a]: avvio usato, versione di Java, memoria in MiB.
String _starting(String word, String withJava, List<Object?> a, String Function(double) gib) {
  final extra = [
    if (a.isNotEmpty && a[0] != null) '${a[0]}',
    if (a.length > 2 && a[2] != null) gib((a[2]! as int) / 1024),
  ];
  return [
    '[MineSync] $word',
    if (a.length > 1 && a[1] != null) '$withJava ${a[1]}',
    if (extra.isNotEmpty) '(${extra.join(', ')})',
  ].join(' ');
}
