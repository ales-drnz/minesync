// Testi della Panoramica: intestazione, riepilogo, card dei server, feed
// Attività, dialogo "Nuovo server".
import 'package:ms_l10n/ms_l10n.dart';

abstract final class OverviewStrings {
  static OverviewStrings of(Lang l) => switch (l) {
    Lang.it => const _It(),
    Lang.en => const _En(),
  };

  String get pageTitle;
  String get title;
  String get newServer;

  String get diskTitle;
  String diskText(String free, String total, String pct, String minFree);
  String get diskMemberNote;
  String get diskAction;

  String get statsLabel;
  String get statServers;
  String get statOpen;
  String get statPlayers;
  String get statDisk;
  String get statDiskBar;
  String diskFreeOf(String free, String total);

  String get worlds;
  String openServer(String name);
  String minecraft(String? version);
  String loader(String loader, String? version);
  String mods(int n);
  String get genericFolder;
  String get lockFree;
  String get lockPlay;
  String get lockStale;
  String online(int n);
  String get openSince;
  String lastSave(String ago);
  String get lastSaved;
  String get neverSaved;
  String staleText(String who, String? since);
  String get addHint;

  String get emptyTitle;
  String get emptyAdmin;
  String get emptyMember;

  String get activity;
  String get filterLabel;
  String get filterAll;
  String get filterSessions;
  String get filterSaves;
  String get filterAdmin;
  String get activityList;
  String get noActivity;
  String get showOlder;

  String get nsTitle;
  String get nsName;
  String get nsNameHint;
  String nsCounter(int n, int max);
  String get nsType;
  String get nsMinecraft;
  String get nsGeneric;
  String get nsMinecraftHint;
  String get nsGenericHint;
  String get nsAfter;
  String get nsCreate;
  String get nsNameRequired;
  String nsCreated(String name);
}

final class _It implements OverviewStrings {
  const _It();
  @override
  String get pageTitle => 'Server';
  @override
  String get title => 'Server';
  @override
  String get newServer => 'Nuovo server';
  @override
  String get diskTitle => 'Disco dell\'hub quasi pieno';
  @override
  String diskText(String free, String total, String pct, String minFree) =>
      'Liberi $free su $total ($pct). Sotto $minFree i salvataggi vengono rifiutati.';
  @override
  String get diskMemberNote =>
      'Le regole di pulizia sono gestite dagli admin e sono visibili nella scheda «Storia» di ogni server.';
  @override
  String get diskAction => 'Storia e disco';
  @override
  String get statsLabel => 'Riepilogo dell\'hub';
  @override
  String get statServers => 'Server';
  @override
  String get statOpen => 'Aperti ora';
  @override
  String get statPlayers => 'Giocatori ora';
  @override
  String get statDisk => 'Disco hub';
  @override
  String get statDiskBar => 'Disco dell\'hub usato';
  @override
  String diskFreeOf(String free, String total) => 'liberi $free su $total';
  @override
  String get worlds => 'I tuoi mondi';
  @override
  String openServer(String name) => 'Apri $name';
  @override
  String minecraft(String? version) => version == null ? 'Minecraft' : 'Minecraft $version';
  @override
  String loader(String loader, String? version) => version == null ? loader : '$loader $version';
  @override
  String mods(int n) => '$n mod';
  @override
  String get genericFolder => 'Cartella generica';
  @override
  String get lockFree => 'Libero';
  @override
  String get lockPlay => 'In gioco';
  @override
  String get lockStale => 'Stale';
  @override
  String online(int n) => '$n online';
  @override
  String get openSince => 'Aperto da ';
  @override
  String lastSave(String ago) => ', ultimo salvataggio $ago';
  @override
  String get lastSaved => 'Ultimo salvataggio';
  @override
  String get neverSaved => 'Vuoto: il mondo arriva con il primo salvataggio dall\'app.';
  @override
  String staleText(String who, String? since) =>
      'Nessun segnale dal PC di $who${since == null ? '' : ' da $since'}. '
      'Si può liberare dalla pagina del server.';
  @override
  String get addHint =>
      'Nome fino a 40 caratteri. Il mondo arriva con il primo salvataggio dall\'app.';
  @override
  String get emptyTitle => 'Ancora nessun server';
  @override
  String get emptyAdmin =>
      'Crea il primo server. Il mondo arriva qui alla prima apertura dall\'app.';
  @override
  String get emptyMember => 'I server creati dagli admin compaiono qui.';
  @override
  String get activity => 'Attività';
  @override
  String get filterLabel => 'Filtra attività';
  @override
  String get filterAll => 'Tutto';
  @override
  String get filterSessions => 'Sessioni';
  @override
  String get filterSaves => 'Salvataggi';
  @override
  String get filterAdmin => 'Admin';
  @override
  String get activityList => 'Attività recenti';
  @override
  String get noActivity => 'Nessuna attività per ora.';
  @override
  String get showOlder => 'Mostra le precedenti';
  @override
  String get nsTitle => 'Nuovo server';
  @override
  String get nsName => 'Nome';
  @override
  String get nsNameHint => 'Visibile a tutti, nell\'app e qui. Modificabile in seguito.';
  @override
  String nsCounter(int n, int max) => '$n/$max';
  @override
  String get nsType => 'Tipo';
  @override
  String get nsMinecraft => 'Minecraft';
  @override
  String get nsGeneric => 'Cartella generica';
  @override
  String get nsMinecraftHint => 'Esclude log, cache e file di sessione di Minecraft.';
  @override
  String get nsGenericHint => 'Sincronizza qualsiasi cartella, senza esclusioni di Minecraft.';
  @override
  String get nsAfter => 'Il mondo arriva con il primo salvataggio dall\'app.';
  @override
  String get nsCreate => 'Crea';
  @override
  String get nsNameRequired => 'Scrivi un nome';
  @override
  String nsCreated(String name) => 'Server $name creato';
}

final class _En implements OverviewStrings {
  const _En();
  @override
  String get pageTitle => 'Servers';
  @override
  String get title => 'Servers';
  @override
  String get newServer => 'New server';
  @override
  String get diskTitle => 'Hub disk nearly full';
  @override
  String diskText(String free, String total, String pct, String minFree) =>
      '$free free of $total ($pct). Below $minFree saves are refused.';
  @override
  String get diskMemberNote =>
      'Cleanup rules are managed by admins and shown in the «History» tab of each server.';
  @override
  String get diskAction => 'History and disk';
  @override
  String get statsLabel => 'Hub summary';
  @override
  String get statServers => 'Servers';
  @override
  String get statOpen => 'Open now';
  @override
  String get statPlayers => 'Players now';
  @override
  String get statDisk => 'Hub disk';
  @override
  String get statDiskBar => 'Hub disk used';
  @override
  String diskFreeOf(String free, String total) => '$free free of $total';
  @override
  String get worlds => 'Your worlds';
  @override
  String openServer(String name) => 'Open $name';
  @override
  String minecraft(String? version) => version == null ? 'Minecraft' : 'Minecraft $version';
  @override
  String loader(String loader, String? version) => version == null ? loader : '$loader $version';
  @override
  String mods(int n) => n == 1 ? '1 mod' : '$n mods';
  @override
  String get genericFolder => 'Generic folder';
  @override
  String get lockFree => 'Free';
  @override
  String get lockPlay => 'Playing';
  @override
  String get lockStale => 'Stale';
  @override
  String online(int n) => '$n online';
  @override
  String get openSince => 'Open for ';
  @override
  String lastSave(String ago) => ', last save $ago';
  @override
  String get lastSaved => 'Last save';
  @override
  String get neverSaved => 'Empty: the world arrives with the first save from the app.';
  @override
  String staleText(String who, String? since) =>
      'No signal from $who\'s PC${since == null ? '' : ' for $since'}. '
      'It can be freed from the server page.';
  @override
  String get addHint =>
      'Name up to 40 characters. The world arrives with the first save from the app.';
  @override
  String get emptyTitle => 'No servers yet';
  @override
  String get emptyAdmin =>
      'Create the first server. The world arrives here the first time it is opened from the app.';
  @override
  String get emptyMember => 'Servers created by admins appear here.';
  @override
  String get activity => 'Activity';
  @override
  String get filterLabel => 'Filter activity';
  @override
  String get filterAll => 'All';
  @override
  String get filterSessions => 'Sessions';
  @override
  String get filterSaves => 'Saves';
  @override
  String get filterAdmin => 'Admin';
  @override
  String get activityList => 'Recent activity';
  @override
  String get noActivity => 'No activity yet.';
  @override
  String get showOlder => 'Show older';
  @override
  String get nsTitle => 'New server';
  @override
  String get nsName => 'Name';
  @override
  String get nsNameHint => 'Visible to everyone, in the app and here. Can be changed later.';
  @override
  String nsCounter(int n, int max) => '$n/$max';
  @override
  String get nsType => 'Type';
  @override
  String get nsMinecraft => 'Minecraft';
  @override
  String get nsGeneric => 'Generic folder';
  @override
  String get nsMinecraftHint => 'Leaves out Minecraft logs, caches and session files.';
  @override
  String get nsGenericHint => 'Syncs any folder, without the Minecraft exclusions.';
  @override
  String get nsAfter => 'The world arrives with the first save from the app.';
  @override
  String get nsCreate => 'Create';
  @override
  String get nsNameRequired => 'Type a name';
  @override
  String nsCreated(String name) => 'Server $name created';
}
