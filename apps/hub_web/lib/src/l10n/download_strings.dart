// Testi della pagina Download dell'app desktop.
import 'package:ms_l10n/ms_l10n.dart';
import 'package:ms_protocol/ms_protocol.dart';

abstract final class DownloadStrings {
  static DownloadStrings of(Lang l) => switch (l) {
    Lang.it => const _It(),
    Lang.en => const _En(),
  };

  String get pageTitle;
  String get eyebrow;
  String get title;
  String get lead;
  String forThisPc(String os);
  String appFor(String os);
  String osName(DlOs os);
  String osDetail(DlOs os);
  String downloadFor(String os);
  String get download;
  String get signedSums;
  String get stepsTitle;
  String get step1;
  String get step1Text;
  String get step2;
  String step2Text(String hub);
  String get step3;
  String get step3Text;
  String get allPlatforms;
  String get integrity;
  String get integrityHide;
  String get copyHash;
  String get requirements;
  String get zeroTier;
  String get zeroTierOk;
  String get zeroTierText;
  String get java;
  List<String> get javaVersions;
  String get javaText;
  String get diskSpace;
  String diskText(String list);
  String get diskNone;
  String get updatesTitle;
  String get updatesText;
  String get phoneTitle;
  String get phoneText;
  String get noneTitle;
  String get noneAdmin;
  String get noneMember;
  String get loadError;
}

final class _It implements DownloadStrings {
  const _It();
  @override
  String get pageTitle => 'Download';
  @override
  String get eyebrow => 'App desktop';
  @override
  String get title => 'Scarica MineSync';
  @override
  String get lead =>
      'Con Gioca l\'app scarica l\'ultima versione del mondo dall\'hub, avvia il server '
      'e al termine salva le modifiche sull\'hub.';
  @override
  String forThisPc(String os) => 'Per questo PC: $os';
  @override
  String appFor(String os) => 'MineSync per $os';
  @override
  String osName(DlOs os) => switch (os) {
    DlOs.windows => 'Windows',
    DlOs.macos => 'macOS',
    DlOs.linux => 'Linux',
  };
  @override
  String osDetail(DlOs os) => switch (os) {
    DlOs.windows => 'Windows 10 e 11, 64 bit',
    DlOs.macos => 'macOS 12 o più recente',
    DlOs.linux => 'Qualsiasi distribuzione recente',
  };
  @override
  String downloadFor(String os) => 'Scarica per $os';
  @override
  String get download => 'Scarica';
  @override
  String get signedSums => 'Checksum firmati';
  @override
  String get stepsTitle => 'Primi passi';
  @override
  String get step1 => 'Installa e apri';
  @override
  String get step1Text => 'Avvia il file scaricato. Su Linux rendi eseguibile l\'AppImage.';
  @override
  String get step2 => 'Conferma l\'hub';
  @override
  String step2Text(String hub) => 'L\'app propone già questo hub ($hub). Premi Connetti.';
  @override
  String get step3 => 'Scegli il server e premi Gioca';
  @override
  String get step3Text =>
      'L\'app scarica il mondo, avvia il server e mostra l\'indirizzo da condividere con gli altri giocatori.';
  @override
  String get allPlatforms => 'Tutte le piattaforme';
  @override
  String get integrity => 'Verifica l\'integrità (SHA-256)';
  @override
  String get integrityHide => 'Nascondi SHA-256';
  @override
  String get copyHash => 'Copia SHA-256';
  @override
  String get requirements => 'Requisiti';
  @override
  String get zeroTier => 'ZeroTier';
  @override
  String get zeroTierOk => 'Connesso';
  @override
  String get zeroTierText =>
      'Necessario su ogni PC che gioca: è la rete privata che collega giocatori e hub. '
      'L\'accesso si basa sulla rete, senza password.';
  @override
  String get java => 'Java';
  @override
  List<String> get javaVersions => const ['8', '17', '21', '25'];
  @override
  String get javaText =>
      'Solo per chi ospita. Minecraft 26.x richiede Java 25, dalla 1.20.5 Java 21, dalla 1.17 '
      'Java 17, le versioni precedenti Java 8. L\'app rileva i Java installati, indica quale '
      'serve a ogni server e, se manca, dove scaricarlo.';
  @override
  String get diskSpace => 'Spazio su disco';
  @override
  String diskText(String list) => 'Pari alla dimensione del mondo: $list.';
  @override
  String get diskNone => 'Pari alla dimensione del mondo, indicata nella pagina del server.';
  @override
  String get updatesTitle => 'Aggiornamenti automatici dall\'hub';
  @override
  String get updatesText =>
      'Il download serve una sola volta. Le nuove versioni arrivano firmate da questo hub e si '
      'installano al riavvio, mai durante una partita.';
  @override
  String get phoneTitle => 'Da telefono';
  @override
  String get phoneText =>
      'Da qui si seguono server, storia e giocatori. Per giocare e ospitare serve l\'app su '
      'un PC.';
  @override
  String get noneTitle => 'Nessun download su questo hub';
  @override
  String get noneAdmin =>
      'Copia i file dell\'app nella cartella indicata da MINESYNC_DL sull\'hub: compaiono qui automaticamente.';
  @override
  String get noneMember => 'L\'app non è ancora stata caricata sull\'hub. Chiedi a un admin.';
  @override
  String get loadError => 'Impossibile leggere l\'elenco dei download';
}

final class _En implements DownloadStrings {
  const _En();
  @override
  String get pageTitle => 'Download';
  @override
  String get eyebrow => 'Desktop app';
  @override
  String get title => 'Download MineSync';
  @override
  String get lead =>
      'With Play the app downloads the latest version of the world from the hub, starts the '
      'server and saves the changes to the hub when it stops.';
  @override
  String forThisPc(String os) => 'For this PC: $os';
  @override
  String appFor(String os) => 'MineSync for $os';
  @override
  String osName(DlOs os) => switch (os) {
    DlOs.windows => 'Windows',
    DlOs.macos => 'macOS',
    DlOs.linux => 'Linux',
  };
  @override
  String osDetail(DlOs os) => switch (os) {
    DlOs.windows => 'Windows 10 and 11, 64 bit',
    DlOs.macos => 'macOS 12 or later',
    DlOs.linux => 'Any recent distribution',
  };
  @override
  String downloadFor(String os) => 'Download for $os';
  @override
  String get download => 'Download';
  @override
  String get signedSums => 'Signed checksums';
  @override
  String get stepsTitle => 'Getting started';
  @override
  String get step1 => 'Install and open';
  @override
  String get step1Text => 'Run the downloaded file. On Linux make the AppImage executable.';
  @override
  String get step2 => 'Confirm the hub';
  @override
  String step2Text(String hub) => 'The app already suggests this hub ($hub). Press Connect.';
  @override
  String get step3 => 'Pick the server and press Play';
  @override
  String get step3Text =>
      'The app downloads the world, starts the server and shows the address to share with the other players.';
  @override
  String get allPlatforms => 'All platforms';
  @override
  String get integrity => 'Check integrity (SHA-256)';
  @override
  String get integrityHide => 'Hide SHA-256';
  @override
  String get copyHash => 'Copy SHA-256';
  @override
  String get requirements => 'Requirements';
  @override
  String get zeroTier => 'ZeroTier';
  @override
  String get zeroTierOk => 'Connected';
  @override
  String get zeroTierText =>
      'Required on every PC that plays: it is the private network that links players and the '
      'hub. Access is based on the network, with no passwords.';
  @override
  String get java => 'Java';
  @override
  List<String> get javaVersions => const ['8', '17', '21', '25'];
  @override
  String get javaText =>
      'Only for hosts. Minecraft 26.x requires Java 25, 1.20.5 and later Java 21, 1.17 and later '
      'Java 17, older versions Java 8. The app detects the installed Java versions, shows which '
      'one each server needs and, if missing, where to download it.';
  @override
  String get diskSpace => 'Disk space';
  @override
  String diskText(String list) => 'The size of the world: $list.';
  @override
  String get diskNone => 'The size of the world, shown on the server page.';
  @override
  String get updatesTitle => 'Automatic updates from the hub';
  @override
  String get updatesText =>
      'Download once. New versions come signed from this hub and install on restart, never '
      'during a game.';
  @override
  String get phoneTitle => 'On a phone';
  @override
  String get phoneText =>
      'Servers, history and players can be followed from here. Playing and hosting require the '
      'app on a PC.';
  @override
  String get noneTitle => 'No downloads on this hub';
  @override
  String get noneAdmin =>
      'Copy the app files to the folder set by MINESYNC_DL on the hub: they appear here automatically.';
  @override
  String get noneMember => 'The app has not been uploaded to the hub yet. Ask an admin.';
  @override
  String get loadError => 'Unable to read the list of downloads';
}
