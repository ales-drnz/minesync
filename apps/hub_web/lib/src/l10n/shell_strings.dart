// Testi della cornice: header, stato della connessione, hub offline,
// accesso negato, pagina non trovata, area riservata, titoli delle pagine.
import 'package:ms_l10n/ms_l10n.dart';

abstract final class ShellStrings {
  static ShellStrings of(Lang l) => switch (l) {
    Lang.it => const _It(),
    Lang.en => const _En(),
  };

  String version(String v);
  String get navLabel;
  String get navServers;
  String get navDownload;
  String get navAdmin;
  String live(int latencyMs);
  String get liveShort;
  String get liveTip;
  String get offline;
  String get connecting;
  String get roleAdmin;
  String get roleMember;
  String get langLabel;
  String get toLight;
  String get toDark;
  String get close;
  String get copied;

  /// Titolo della scheda del browser: "Hub di casa · Server".
  String pageTitle(String page, String? hub);

  String get offlineTitle;
  String offlineText(int retrySeconds);
  String get retry;

  String get deniedTitle;
  String get deniedText;
  String get deniedAddress;
  String get deniedNetwork;
  String get deniedStep1;
  String get deniedStep1Text;
  String get deniedStep2;
  String get deniedStep2Text;
  String get deniedStep3;
  String get deniedStep3Text;
  String get whatIsZeroTier;
  String get deniedPage;

  String get notFoundTitle;
  String get notFoundText;
  String get backToServers;

  String get adminOnlyTitle;
  String get adminOnlyText;

  String get comingSoon;
}

final class _It implements ShellStrings {
  const _It();
  @override
  String version(String v) => 'MineSync $v';
  @override
  String get navLabel => 'Principale';
  @override
  String get navServers => 'Server';
  @override
  String get navDownload => 'Download';
  @override
  String get navAdmin => 'Admin';
  @override
  String live(int latencyMs) => '$latencyMs ms';
  @override
  String get liveShort => 'Online';
  @override
  String get liveTip => 'Aggiornamenti in tempo reale attivi';
  @override
  String get offline => 'Offline';
  @override
  String get connecting => 'Connessione…';
  @override
  String get roleAdmin => 'admin';
  @override
  String get roleMember => 'membro';
  @override
  String get langLabel => 'Lingua';
  @override
  String get toLight => 'Passa al tema chiaro';
  @override
  String get toDark => 'Passa al tema scuro';
  @override
  String get close => 'Chiudi';
  @override
  String get copied => 'Copiato negli appunti';
  @override
  String pageTitle(String page, String? hub) => '$page (${hub ?? 'MineSync'})';
  @override
  String get offlineTitle => 'Hub non raggiungibile';
  @override
  String offlineText(int retrySeconds) =>
      'Controlla che ZeroTier sia attivo su questo dispositivo. Nuovo tentativo ogni '
      '$retrySeconds s. I dati mostrati sono gli ultimi ricevuti.';
  @override
  String get retry => 'Riprova';
  @override
  String get deniedTitle => 'Dispositivo non riconosciuto';
  @override
  String get deniedText =>
      'Questo hub non usa password: riconosce i dispositivi della rete ZeroTier. '
      'La richiesta arriva da fuori della rete.';
  @override
  String get deniedAddress => 'Il tuo indirizzo';
  @override
  String get deniedNetwork => 'Rete attesa';
  @override
  String get deniedStep1 => 'Attiva ZeroTier su questo dispositivo';
  @override
  String get deniedStep1Text => 'Telefono o PC: l\'app ZeroTier deve risultare connessa.';
  @override
  String get deniedStep2 => 'Unisciti alla rete dell\'hub';
  @override
  String get deniedStep2Text => 'Il codice della rete lo fornisce chi gestisce l\'hub.';
  @override
  String get deniedStep3 => 'Richiedi l\'autorizzazione';
  @override
  String get deniedStep3Text =>
      'Dopo l\'approvazione di un admin, il dispositivo viene riconosciuto.';
  @override
  String get whatIsZeroTier => 'Cos\'è ZeroTier?';
  @override
  String get deniedPage => 'Accesso negato';
  @override
  String get notFoundTitle => 'Pagina non trovata';
  @override
  String get notFoundText => 'Il link non è valido o il server è stato eliminato.';
  @override
  String get backToServers => 'Torna ai server';
  @override
  String get adminOnlyTitle => 'Area riservata agli admin';
  @override
  String get adminOnlyText =>
      'Solo gli admin possono modificare le impostazioni dell\'hub. Per richieste, rivolgiti a un admin.';
  @override
  String get comingSoon => 'Sezione non ancora disponibile.';
}

final class _En implements ShellStrings {
  const _En();
  @override
  String version(String v) => 'MineSync $v';
  @override
  String get navLabel => 'Main';
  @override
  String get navServers => 'Servers';
  @override
  String get navDownload => 'Download';
  @override
  String get navAdmin => 'Admin';
  @override
  String live(int latencyMs) => '$latencyMs ms';
  @override
  String get liveShort => 'Online';
  @override
  String get liveTip => 'Real-time updates on';
  @override
  String get offline => 'Offline';
  @override
  String get connecting => 'Connecting…';
  @override
  String get roleAdmin => 'admin';
  @override
  String get roleMember => 'member';
  @override
  String get langLabel => 'Language';
  @override
  String get toLight => 'Switch to light theme';
  @override
  String get toDark => 'Switch to dark theme';
  @override
  String get close => 'Close';
  @override
  String get copied => 'Copied to the clipboard';
  @override
  String pageTitle(String page, String? hub) => '$page (${hub ?? 'MineSync'})';
  @override
  String get offlineTitle => 'Hub not reachable';
  @override
  String offlineText(int retrySeconds) =>
      'Check that ZeroTier is running on this device. Retrying every $retrySeconds s. '
      'The data shown is the last received.';
  @override
  String get retry => 'Retry';
  @override
  String get deniedTitle => 'Device not recognised';
  @override
  String get deniedText =>
      'This hub uses no passwords: it recognises the devices on the ZeroTier network. '
      'The request comes from outside the network.';
  @override
  String get deniedAddress => 'Your address';
  @override
  String get deniedNetwork => 'Expected network';
  @override
  String get deniedStep1 => 'Turn on ZeroTier on this device';
  @override
  String get deniedStep1Text => 'Phone or PC: the ZeroTier app must show as connected.';
  @override
  String get deniedStep2 => 'Join the hub\'s network';
  @override
  String get deniedStep2Text => 'The network ID is provided by whoever runs the hub.';
  @override
  String get deniedStep3 => 'Request authorisation';
  @override
  String get deniedStep3Text => 'Once an admin approves it, the device is recognised.';
  @override
  String get whatIsZeroTier => 'What is ZeroTier?';
  @override
  String get deniedPage => 'Access denied';
  @override
  String get notFoundTitle => 'Page not found';
  @override
  String get notFoundText => 'The link is not valid or the server was deleted.';
  @override
  String get backToServers => 'Back to servers';
  @override
  String get adminOnlyTitle => 'Admins only';
  @override
  String get adminOnlyText =>
      'Only admins can change the hub settings. For requests, contact an admin.';
  @override
  String get comingSoon => 'Section not available yet.';
}
