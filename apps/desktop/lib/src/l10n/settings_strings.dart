// Testi delle impostazioni: preferenze dell'app su questo PC, preferenze
// per server, rete e informazioni sull'app.
import 'package:ms_l10n/ms_l10n.dart';

abstract final class SettingsStrings {
  static SettingsStrings of(Lang l) => switch (l) {
    Lang.it => const _It(),
    Lang.en => const _En(),
  };

  String get title;
  String get intro;
  String get searchLabel;
  String get searchHint;
  String get sectionsLabel;
  String get autosaved;
  String get noMatch;

  // generali
  String get general;
  String get hub;
  String hubHint(String? address, String name, bool admin);
  String notConnectedTo(String address);
  String get notConnected;
  String get changeHub;
  String get language;
  String get italian;
  String get english;
  String get asSystem;
  String get theme;
  String get dark;
  String get light;
  String get style;
  // nulli: il titolo basta
  String? get styleHint;
  String get prato;
  String get abisso;
  String get size;
  String get sizeHint;
  String get sizeNormal;
  String get sizeLarge;
  String get sizeLarger;
  String get motion;
  String get motionHint;
  String get autostart;
  String get autostartHint;
  String get tray;
  String get trayHint;
  String get notifications;
  String? get notificationsHint;
  String get notifyFriendOpens;
  String get notifyServerFree;
  String get notifySessionProblems;
  String get notifyEverySave;
  String get notifyUpdate;

  // per server
  String get noServers;
  String get folder;
  String folderHint(String server);
  String get java;
  String javaHint(String? what, int? major);
  String get javaAuto;
  String get recommended;
  String get javaOk;
  String get javaSearching;
  String get memory;
  String get memoryHint;
  String get memorySet;
  String get memoryMax;
  String gb(int g);
  String get autostop;
  String autostopHint(int minutes);

  // rete
  String get network;
  String get bandwidth;
  String get bandwidthHint;
  String get bandwidthLabel;
  String get bwAuto;
  String bwAutoMeta(String? measured);
  String get bwPercent;
  String bwPercentMeta(int percent);
  String get bwFixed;
  String bwFixedMeta(int kib);
  String get kibLabel;
  String get kibUnit;
  String get bwNone;
  String get bwNoneMeta;

  // info
  String get info;
  String platform(String os);
  String ready(String version);
  String get restartUpdate;
  String get updates;
  String get updatesHint;
  String get checkNow;
  String get upToDate;
  String get diagnostics;
  String get diagnosticsHint;
  String get copyDiagnostics;
  String get copied;
}

final class _It implements SettingsStrings {
  const _It();
  @override
  String get title => 'Impostazioni';
  @override
  String get intro =>
      'Valide solo per questo PC. Le regole comuni (salvataggi, spazio) sono nell\'Admin '
      'dell\'hub.';
  @override
  String get searchLabel => 'Cerca nelle impostazioni';
  @override
  String get searchHint => 'Cerca';
  @override
  String get sectionsLabel => 'Sezioni delle impostazioni';
  @override
  String get autosaved => '';
  @override
  String get noMatch => 'Nessuna impostazione corrisponde alla ricerca.';
  @override
  String get general => 'Generali';
  @override
  String get hub => 'Hub';
  @override
  String hubHint(String? address, String name, bool admin) =>
      'Connesso${address == null ? '' : ' a $address'} come $name${admin ? ' (admin)' : ''}.';
  @override
  String notConnectedTo(String address) => 'Non connesso a $address.';
  @override
  String get notConnected => 'Non connesso.';
  @override
  String get changeHub => 'Cambia hub…';
  @override
  String get language => 'Lingua';
  @override
  String get italian => 'Italiano';
  @override
  String get english => 'English';
  @override
  String get asSystem => 'Come il sistema';
  @override
  String get theme => 'Tema';
  @override
  String get dark => 'Scuro';
  @override
  String get light => 'Chiaro';
  @override
  String get style => 'Stile';
  @override
  String? get styleHint => null;
  @override
  String get prato => 'Prato';
  @override
  String get abisso => 'Abisso';
  @override
  String get size => 'Dimensione dell\'interfaccia';
  @override
  String get sizeHint => 'Ingrandisce l\'interfaccia a passi interi, per mantenere la nitidezza.';
  @override
  String get sizeNormal => 'Normale';
  @override
  String get sizeLarge => 'Grande';
  @override
  String get sizeLarger => 'Più grande';
  @override
  String get motion => 'Meno animazioni';
  @override
  String get motionHint => 'Disattiva lampeggi e movimenti.';
  @override
  String get autostart => 'Avvia con il computer';
  @override
  String get autostartHint => 'MineSync si avvia nascosto e scarica in anticipo gli aggiornamenti.';
  @override
  String get tray => 'Tieni MineSync in background quando chiudi la finestra';
  @override
  String get trayHint => 'Un server in esecuzione resta attivo.';
  @override
  String get notifications => 'Notifiche sul desktop';
  @override
  String? get notificationsHint => null;
  @override
  String get notifyFriendOpens => 'Un giocatore avvia un server';
  @override
  String get notifyServerFree => 'Un server atteso torna libero';
  @override
  String get notifySessionProblems => 'Problemi durante la sessione (crash, hub non raggiungibile)';
  @override
  String get notifyEverySave => 'Ogni salvataggio sull\'hub';
  @override
  String get notifyUpdate => 'Aggiornamento di MineSync pronto';
  @override
  String get noServers => 'Nessun server sull\'hub.';
  @override
  String get folder => 'Cartella su questo PC';
  @override
  String folderHint(String server) => 'Posizione della copia locale di $server.';
  @override
  String get java => 'Java';
  @override
  String javaHint(String? what, int? major) => major == null
      ? 'Versione scelta automaticamente in base al server.'
      : '${what ?? 'Il server'} richiede Java $major.';
  @override
  String get javaAuto => 'Automatico';
  @override
  String get recommended => 'consigliato';
  @override
  String get javaOk => 'va bene';
  @override
  String get javaSearching => 'Ricerca…';
  @override
  String get memory => 'Memoria per il server';
  @override
  String get memoryHint => 'Facoltativa. Se disattivata, si usa quella indicata dallo script.';
  @override
  String get memorySet => 'Imposta la memoria manualmente';
  @override
  String get memoryMax => 'Memoria massima';
  @override
  String gb(int g) => '$g GB';
  @override
  String get autostop => 'Arresto automatico senza giocatori';
  @override
  String autostopHint(int minutes) => 'Dopo $minutes min senza giocatori, con salvataggio.';
  @override
  String get network => 'Rete';
  @override
  String get bandwidth => 'Limite di banda per i caricamenti';
  @override
  String get bandwidthHint =>
      'Durante il gioco i salvataggi vengono caricati sull\'hub senza saturare la connessione.';
  @override
  String get bandwidthLabel => 'Limite di banda';
  @override
  String get bwAuto => 'Automatico';
  @override
  String bwAutoMeta(String? measured) => measured == null
      ? '70% della velocità misurata (la misura avviene al primo caricamento)'
      : '70% della velocità misurata, ora circa $measured/s';
  @override
  String get bwPercent => 'Percentuale';
  @override
  String bwPercentMeta(int percent) => '$percent% della velocità misurata';
  @override
  String get bwFixed => 'Velocità fissa';
  @override
  String bwFixedMeta(int kib) => '$kib KB/s, sempre la stessa';
  @override
  String get kibLabel => 'KB al secondo';
  @override
  String get kibUnit => 'KB/s';
  @override
  String get bwNone => 'Nessun limite';
  @override
  String get bwNoneMeta => 'il più veloce possibile';
  @override
  String get info => 'Info';
  @override
  String platform(String os) => os;
  @override
  String ready(String version) => '$version pronto';
  @override
  String get restartUpdate => 'Riavvia e aggiorna';
  @override
  String get updates => 'Aggiornamenti automatici';
  @override
  String get updatesHint => 'Mai durante il gioco.';
  @override
  String get checkNow => 'Controlla ora';
  @override
  String get upToDate => 'aggiornato';
  @override
  String get diagnostics => 'Diagnostica';
  @override
  String get diagnosticsHint => 'Copia le informazioni tecniche e inviale a chi gestisce l\'hub.';
  @override
  String get copyDiagnostics => 'Copia info diagnostiche';
  @override
  String get copied => 'Copiato negli appunti';
}

final class _En implements SettingsStrings {
  const _En();
  @override
  String get title => 'Settings';
  @override
  String get intro => 'Apply to this PC only. Shared rules (saves, space) are in the hub\'s Admin.';
  @override
  String get searchLabel => 'Search the settings';
  @override
  String get searchHint => 'Search';
  @override
  String get sectionsLabel => 'Settings sections';
  @override
  String get autosaved => '';
  @override
  String get noMatch => 'No setting matches the search.';
  @override
  String get general => 'General';
  @override
  String get hub => 'Hub';
  @override
  String hubHint(String? address, String name, bool admin) =>
      'Connected${address == null ? '' : ' to $address'} as $name${admin ? ' (admin)' : ''}.';
  @override
  String notConnectedTo(String address) => 'Not connected to $address.';
  @override
  String get notConnected => 'Not connected.';
  @override
  String get changeHub => 'Change hub…';
  @override
  String get language => 'Language';
  @override
  String get italian => 'Italiano';
  @override
  String get english => 'English';
  @override
  String get asSystem => 'Same as the system';
  @override
  String get theme => 'Theme';
  @override
  String get dark => 'Dark';
  @override
  String get light => 'Light';
  @override
  String get style => 'Style';
  @override
  String? get styleHint => null;
  @override
  String get prato => 'Prato';
  @override
  String get abisso => 'Abisso';
  @override
  String get size => 'Interface size';
  @override
  String get sizeHint => 'Scales the interface in whole steps to keep it sharp.';
  @override
  String get sizeNormal => 'Normal';
  @override
  String get sizeLarge => 'Large';
  @override
  String get sizeLarger => 'Larger';
  @override
  String get motion => 'Less motion';
  @override
  String get motionHint => 'Turns off blinking and movement.';
  @override
  String get autostart => 'Start with the computer';
  @override
  String get autostartHint => 'MineSync starts hidden and downloads updates in advance.';
  @override
  String get tray => 'Keep running in the background when the window is closed';
  @override
  String get trayHint => 'A running server keeps running.';
  @override
  String get notifications => 'Desktop notifications';
  @override
  String? get notificationsHint => null;
  @override
  String get notifyFriendOpens => 'A player starts a server';
  @override
  String get notifyServerFree => 'An awaited server is free';
  @override
  String get notifySessionProblems => 'Problems during the session (crash, hub not reachable)';
  @override
  String get notifyEverySave => 'Every save on the hub';
  @override
  String get notifyUpdate => 'MineSync update ready';
  @override
  String get noServers => 'No servers on the hub.';
  @override
  String get folder => 'Folder on this PC';
  @override
  String folderHint(String server) => 'Location of the local copy of $server.';
  @override
  String get java => 'Java';
  @override
  String javaHint(String? what, int? major) => major == null
      ? 'Version chosen automatically for the server.'
      : '${what ?? 'The server'} requires Java $major.';
  @override
  String get javaAuto => 'Automatic';
  @override
  String get recommended => 'recommended';
  @override
  String get javaOk => 'fine';
  @override
  String get javaSearching => 'Searching…';
  @override
  String get memory => 'Server memory';
  @override
  String get memoryHint => 'Optional. When off, the script\'s value is used.';
  @override
  String get memorySet => 'Set memory manually';
  @override
  String get memoryMax => 'Maximum memory';
  @override
  String gb(int g) => '$g GB';
  @override
  String get autostop => 'Stop automatically when empty';
  @override
  String autostopHint(int minutes) => 'After $minutes min with no players, after saving.';
  @override
  String get network => 'Network';
  @override
  String get bandwidth => 'Upload bandwidth limit';
  @override
  String get bandwidthHint =>
      'Saves are uploaded to the hub during play without saturating the connection.';
  @override
  String get bandwidthLabel => 'Bandwidth limit';
  @override
  String get bwAuto => 'Automatic';
  @override
  String bwAutoMeta(String? measured) => measured == null
      ? '70% of the measured speed (measured on the first upload)'
      : '70% of the measured speed, currently about $measured/s';
  @override
  String get bwPercent => 'Percentage';
  @override
  String bwPercentMeta(int percent) => '$percent% of the measured speed';
  @override
  String get bwFixed => 'Fixed speed';
  @override
  String bwFixedMeta(int kib) => '$kib KB/s, always the same';
  @override
  String get kibLabel => 'KB per second';
  @override
  String get kibUnit => 'KB/s';
  @override
  String get bwNone => 'No limit';
  @override
  String get bwNoneMeta => 'as fast as possible';
  @override
  String get info => 'About';
  @override
  String platform(String os) => os;
  @override
  String ready(String version) => '$version ready';
  @override
  String get restartUpdate => 'Restart and update';
  @override
  String get updates => 'Automatic updates';
  @override
  String get updatesHint => 'Never while playing.';
  @override
  String get checkNow => 'Check now';
  @override
  String get upToDate => 'up to date';
  @override
  String get diagnostics => 'Diagnostics';
  @override
  String get diagnosticsHint => 'Copy the technical details and send them to whoever runs the hub.';
  @override
  String get copyDiagnostics => 'Copy diagnostic info';
  @override
  String get copied => 'Copied to the clipboard';
}
