// Testi del catalogo dei modpack nella procedura «Nuovo server»: elenco di
// Modrinth con ricerca, ordinamento e filtri, dettagli e versioni del
// modpack, divisione fra server e giocatori dei modpack solo client.
import 'package:ms_l10n/ms_l10n.dart';

abstract final class PackBrowserStrings {
  const PackBrowserStrings();

  static PackBrowserStrings of(Lang l) => switch (l) {
    Lang.it => const _It(),
    Lang.en => const _En(),
  };

  String get sourceLabel;
  String get sourceBrowse;
  String get sourceFile;
  String get fileIntro;

  String get search;
  String get searchPlaceholder;
  String get sort;

  /// `downloads`, `relevance`, `newest`, `updated`.
  String sortName(String s);
  String get loader;
  String get anyLoader;
  String get minecraft;
  String get anyMc;
  String get listLabel;
  String results(int n);
  String by(String author);
  String downloads(int n);
  String get loadMore;
  String get moreError;
  String get retry;
  String get emptyTitle;
  String get emptyText;
  String get clearFilters;
  String get errorTitle;
  String get errorText;
  String get useFile;

  String get clientOnlyChip;
  String get pickHint;
  String get backToList;
  String get detailsError;
  String get version;
  String get showBeta;
  String versionOption(String number, String mc, String loaders, String? type);
  String get noVersions;
  String get versionsError;
  String get use;

  /// Download del modpack; [progress] è «45 MB / 101 MB» quando si sa.
  String downloading(String? done, String? total);
  String get openPage;
  String get links;
  String get issues;
  String get source;
  String get wiki;
  String get discord;
  String get noDescription;
  String get clientOnlyNote;

  String get chosenTitle;
  String get change;
  String splitTitle(int server, int client);
  String get splitWhyClientOnly;
  String get splitWhy;
  String get showList;
  String get hideList;
  String get onServer;
  String get clientOnly;

  /// `packIndex`, `modrinth`, `jar`, `clientContent`, `none`.
  String reason(String r);
  String unknownTitle(int n);
  String get unknownText;
  String get keepOnServer;
}

String _group(int n, String sep) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(sep);
    b.write(s[i]);
  }
  return b.toString();
}

/// 41,2 / 41.2 con una cifra decimale sotto 100.
String _short(double v, String dec) =>
    (v < 100 ? v.toStringAsFixed(1) : v.toStringAsFixed(0)).replaceAll('.', dec);

final class _It extends PackBrowserStrings {
  const _It();

  @override
  String get sourceLabel => 'Da dove';
  @override
  String get sourceBrowse => 'Sfoglia Modrinth';
  @override
  String get sourceFile => 'Da un file .mrpack';
  @override
  String get fileIntro =>
      'Un .mrpack scaricato da Modrinth o esportato da Prism Launcher: indica dove si trova.';

  @override
  String get search => 'Cerca';
  @override
  String get searchPlaceholder => 'Cerca un modpack…';
  @override
  String get sort => 'Ordina';
  @override
  String sortName(String s) => switch (s) {
    'downloads' => 'Più scaricati',
    'relevance' => 'Rilevanza',
    'newest' => 'Più recenti',
    _ => 'Aggiornati di recente',
  };
  @override
  String get loader => 'Tipo di server';
  @override
  String get anyLoader => 'Tutti';
  @override
  String get minecraft => 'Minecraft';
  @override
  String get anyMc => 'Tutte';
  @override
  String get listLabel => 'Modpack su Modrinth';
  @override
  String results(int n) => n == 1 ? '1 modpack' : '${_group(n, '.')} modpack';
  @override
  String by(String author) => 'di $author';
  @override
  String downloads(int n) {
    if (n >= 1000000) return '${_short(n / 1000000, ',')} mln download';
    if (n >= 1000) return '${_short(n / 1000, ',')} mila download';
    return '$n download';
  }

  @override
  String get loadMore => 'Carica altri';
  @override
  String get moreError => 'Impossibile caricare altri modpack.';
  @override
  String get retry => 'Riprova';
  @override
  String get emptyTitle => 'Nessun modpack trovato';
  @override
  String get emptyText => 'Prova con meno parole o rimuovi i filtri.';
  @override
  String get clearFilters => 'Cancella ricerca e filtri';
  @override
  String get errorTitle => 'Modrinth non risponde';
  @override
  String get errorText =>
      'Controlla la connessione e riprova. In alternativa, usa un file .mrpack già scaricato.';
  @override
  String get useFile => 'Usa un file .mrpack';

  @override
  String get clientOnlyChip => 'solo giocatori';
  @override
  String get pickHint => 'Scegli un modpack dall\'elenco per vederne descrizione e versioni.';
  @override
  String get backToList => 'Torna all\'elenco';
  @override
  String get detailsError => 'Impossibile leggere questo modpack da Modrinth.';
  @override
  String get version => 'Versione del modpack';
  @override
  String get showBeta => 'Mostra anche le beta';
  @override
  String versionOption(String number, String mc, String loaders, String? type) =>
      '$number per Minecraft $mc${loaders.isEmpty ? '' : ' con $loaders'}${type == null ? '' : ' ($type)'}';
  @override
  String get noVersions => 'Questo modpack non ha versioni da scaricare.';
  @override
  String get versionsError => 'Impossibile leggere le versioni.';
  @override
  String get use => 'Usa questo modpack';
  @override
  String downloading(String? done, String? total) => done == null || total == null
      ? 'Download del modpack…'
      : 'Download del modpack ($done di $total)';
  @override
  String get openPage => 'Pagina su Modrinth';
  @override
  String get links => 'Link';
  @override
  String get issues => 'Segnalazioni';
  @override
  String get source => 'Sorgente';
  @override
  String get wiki => 'Wiki';
  @override
  String get discord => 'Discord';
  @override
  String get noDescription => 'Nessuna descrizione.';
  @override
  String get clientOnlyNote =>
      'Pubblicato solo per i giocatori: il server viene preparato automaticamente, escludendo le mod che servono solo a chi gioca.';

  @override
  String get chosenTitle => 'Modpack scelto';
  @override
  String get change => 'Scegli un altro modpack';
  @override
  String splitTitle(int server, int client) =>
      '${server == 1 ? '1 mod' : '$server mod'} sul server, $client solo per i giocatori (esclusi dal server)';
  @override
  String get splitWhyClientOnly =>
      'Questo modpack è pubblicato solo per chi gioca, senza un pacchetto per il server: le mod che funzionano solo sul PC dei giocatori vengono escluse dal server e restano nel loro pacchetto.';
  @override
  String get splitWhy =>
      'Le mod che servono solo a chi gioca non vanno sul server: restano nel pacchetto per i giocatori.';
  @override
  String get showList => 'Vedi elenco';
  @override
  String get hideList => 'Nascondi elenco';
  @override
  String get onServer => 'Sul server';
  @override
  String get clientOnly => 'Solo per i giocatori';
  @override
  String reason(String r) => switch (r) {
    'packIndex' => 'indicato dal modpack',
    'modrinth' => 'indicato da Modrinth',
    'jar' => 'indicato dal file della mod',
    'clientContent' => 'resource pack o shader',
    _ => 'nessuna indicazione',
  };
  @override
  String unknownTitle(int n) => n == 1
      ? '1 mod senza indicazioni: scelta manuale'
      : '$n mod senza indicazioni: scelta manuale';
  @override
  String get unknownText =>
      'Né il modpack né Modrinth indicano se servono al server. Di base restano sul server; escludi quelle solo per chi gioca (grafica, minimappe, menu).';
  @override
  String get keepOnServer => 'Sul server';
}

final class _En extends PackBrowserStrings {
  const _En();

  @override
  String get sourceLabel => 'Source';
  @override
  String get sourceBrowse => 'Browse Modrinth';
  @override
  String get sourceFile => 'From a .mrpack file';
  @override
  String get fileIntro =>
      'A .mrpack downloaded from Modrinth or exported from Prism Launcher: enter its location.';

  @override
  String get search => 'Search';
  @override
  String get searchPlaceholder => 'Search modpacks…';
  @override
  String get sort => 'Sort';
  @override
  String sortName(String s) => switch (s) {
    'downloads' => 'Most downloaded',
    'relevance' => 'Relevance',
    'newest' => 'Newest',
    _ => 'Recently updated',
  };
  @override
  String get loader => 'Server type';
  @override
  String get anyLoader => 'All';
  @override
  String get minecraft => 'Minecraft';
  @override
  String get anyMc => 'All';
  @override
  String get listLabel => 'Modpacks on Modrinth';
  @override
  String results(int n) => n == 1 ? '1 modpack' : '${_group(n, ',')} modpacks';
  @override
  String by(String author) => 'by $author';
  @override
  String downloads(int n) {
    if (n >= 1000000) return '${_short(n / 1000000, '.')}M downloads';
    if (n >= 1000) return '${_short(n / 1000, '.')}K downloads';
    return n == 1 ? '1 download' : '$n downloads';
  }

  @override
  String get loadMore => 'Load more';
  @override
  String get moreError => 'Unable to load more modpacks.';
  @override
  String get retry => 'Try again';
  @override
  String get emptyTitle => 'No modpack found';
  @override
  String get emptyText => 'Try fewer words or remove the filters.';
  @override
  String get clearFilters => 'Clear search and filters';
  @override
  String get errorTitle => 'Modrinth not responding';
  @override
  String get errorText =>
      'Check the connection and try again. Alternatively, use a .mrpack file you already have.';
  @override
  String get useFile => 'Use a .mrpack file';

  @override
  String get clientOnlyChip => 'players only';
  @override
  String get pickHint => 'Choose a modpack from the list to see its description and versions.';
  @override
  String get backToList => 'Back to the list';
  @override
  String get detailsError => 'Unable to read this modpack from Modrinth.';
  @override
  String get version => 'Modpack version';
  @override
  String get showBeta => 'Show betas too';
  @override
  String versionOption(String number, String mc, String loaders, String? type) =>
      '$number for Minecraft $mc${loaders.isEmpty ? '' : ' with $loaders'}${type == null ? '' : ' ($type)'}';
  @override
  String get noVersions => 'This modpack has no downloadable versions.';
  @override
  String get versionsError => 'Unable to read the versions.';
  @override
  String get use => 'Use this modpack';
  @override
  String downloading(String? done, String? total) => done == null || total == null
      ? 'Downloading the modpack…'
      : 'Downloading the modpack ($done of $total)';
  @override
  String get openPage => 'Page on Modrinth';
  @override
  String get links => 'Links';
  @override
  String get issues => 'Issues';
  @override
  String get source => 'Source';
  @override
  String get wiki => 'Wiki';
  @override
  String get discord => 'Discord';
  @override
  String get noDescription => 'No description.';
  @override
  String get clientOnlyNote =>
      'Published for players only: the server is built automatically, leaving out the mods only players need.';

  @override
  String get chosenTitle => 'Chosen modpack';
  @override
  String get change => 'Choose another modpack';
  @override
  String splitTitle(int server, int client) =>
      '${server == 1 ? '1 mod' : '$server mods'} on the server, $client for players only (left off the server)';
  @override
  String get splitWhyClientOnly =>
      'This modpack is published for players only, with no server pack: mods that only work on the players\' PCs are left off the server and stay in their pack.';
  @override
  String get splitWhy =>
      'Mods only players need do not go on the server: they stay in the players pack.';
  @override
  String get showList => 'See the list';
  @override
  String get hideList => 'Hide the list';
  @override
  String get onServer => 'On the server';
  @override
  String get clientOnly => 'Players only';
  @override
  String reason(String r) => switch (r) {
    'packIndex' => 'stated by the modpack',
    'modrinth' => 'stated by Modrinth',
    'jar' => 'stated by the mod file',
    'clientContent' => 'resource pack or shader',
    _ => 'no information',
  };
  @override
  String unknownTitle(int n) => n == 1
      ? '1 mod with no information: manual choice'
      : '$n mods with no information: manual choice';
  @override
  String get unknownText =>
      'Neither the modpack nor Modrinth states whether the server needs them. They stay on the server by default; remove the ones only for players (graphics, minimaps, menus).';
  @override
  String get keepOnServer => 'On the server';
}
