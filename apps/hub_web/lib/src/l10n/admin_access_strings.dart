// Testi dell'area Admin: Accesso e membri (ZTNET, ruoli) e Sistema (valori
// di sola lettura dalle variabili d'ambiente).
import 'package:ms_l10n/ms_l10n.dart';

abstract final class AdminAccessStrings {
  const AdminAccessStrings();

  static AdminAccessStrings of(Lang l) => switch (l) {
    Lang.it => const _It(),
    Lang.en => const _En(),
  };

  // --- ZTNET ---------------------------------------------------------------
  String get membersLead;
  String get ztOk;
  String get ztErr;
  String get ztOff;
  String ztRefreshed(String ago, int n);
  String get ztNever;
  String ztLastError(String when, String error);
  String get ztOffText;
  String get checkNow;
  String get checked;
  String get ztUrl;
  String get ztToken;
  String get ztNetwork;
  String get secretsNote;
  String get notSet;

  // --- membri --------------------------------------------------------------
  String seenTitle(int n);
  String get searchMember;
  String get colMember;
  String get colMemberNode;
  String get colIp;
  String get colLast;
  String get colRole;
  String get colActions;
  String get you;
  String get noName;
  String get never;
  String get now;
  String get roleAdmin;
  String get roleMember;
  String get fromConfig;
  String get notRemovable;
  String get notAuthorized;
  String get authorizeInZtnet;
  String get makeAdmin;
  String get makeMember;
  String makeAdminFor(String name);
  String makeMemberFor(String name);
  String get noMatch;
  List<(String, bool)> get membersNote;
  String promoteTitle(String name);
  String promoteBody(String name);
  String demoteTitle(String name);
  String demoteBody(String name);
  String get demoteSelf;
  String roleDone(String name, bool admin);
  String get trust;
  String get trustHint;
  String get refresh;
  String get refreshHint;
  String refreshDefault(int s, int min);

  // --- Sistema -------------------------------------------------------------
  String get systemLead;
  String get readOnly;
  String get version;
  String versionBuild(String v, String build);
  String get uptime;
  String uptimeValue(Duration d);
  String get disk;
  String diskValue(String free, String total);
  String get http;
  String get dns;
  String get dnsHint;
  String dnsValue(String zone, String addr);
  String get dnsOn;
  String get dnsOff;
  String dnsBindError(String e);
  String get dnsNone;
  String get hosts;
  String get hostsHint;
  String get hostsNone;
  String get dataDir;
  String get admins;
  String get adminsNone;
  String get minFreeEnv;
  String get dl;
  String get dlNone;
  String get signing;
  String get signingHint;
  String get signed;
  String get unsigned;
  String get partlySigned;
  String get noUpdates;
  String get tz;
  String get web;
  String webValue(String id);
  String get copyDiag;
  String get systemError;
}

final class _It extends AdminAccessStrings {
  const _It();
  @override
  String get membersLead =>
      'Nessuna password: l\'hub riconosce i dispositivi della rete ZeroTier tramite ZTNET.';
  @override
  String get ztOk => 'Connesso a ZTNET';
  @override
  String get ztErr => 'ZTNET non risponde';
  @override
  String get ztOff => 'ZTNET non configurato';
  @override
  String ztRefreshed(String ago, int n) =>
      'Elenco aggiornato $ago, ${n == 1 ? '1 membro autorizzato' : '$n membri autorizzati'} '
      'sulla rete.';
  @override
  String get ztNever => 'Elenco non ancora letto.';
  @override
  String ztLastError(String when, String error) => 'Ultimo errore: $when, $error.';
  @override
  String get ztOffText =>
      'Senza ZTNET l\'hub non conosce i membri della rete. Imposta ZTNET_URL, ZTNET_API_TOKEN e '
      'ZTNET_NETWORK_ID nel file del container.';
  @override
  String get checkNow => 'Verifica ora';
  @override
  String get checked => 'ZTNET verificato';
  @override
  String get ztUrl => 'Indirizzo di ZTNET';
  @override
  String get ztToken => 'Token API';
  @override
  String get ztNetwork => 'Rete';
  @override
  String get secretsNote =>
      'Valori segreti usati per riconoscere chi apre questa pagina: si modificano solo nel file '
      'del container.';
  @override
  String get notSet => 'non impostato';

  @override
  String seenTitle(int n) => 'Membri visti dall\'hub ($n)';
  @override
  String get searchMember => 'Cerca membro';
  @override
  String get colMember => 'Membro';
  @override
  String get colMemberNode => 'Membro e node id';
  @override
  String get colIp => 'IP';
  @override
  String get colLast => 'Ultimo accesso';
  @override
  String get colRole => 'Ruolo';
  @override
  String get colActions => 'Azioni';
  @override
  String get you => 'tu';
  @override
  String get noName => 'senza nome';
  @override
  String get never => 'mai';
  @override
  String get now => 'ora';
  @override
  String get roleAdmin => 'Admin';
  @override
  String get roleMember => 'Membro';
  @override
  String get fromConfig => 'da configurazione';
  @override
  String get notRemovable => 'Non rimovibile';
  @override
  String get notAuthorized => 'Non autorizzato';
  @override
  String get authorizeInZtnet => 'si autorizza in ZTNET';
  @override
  String get makeAdmin => 'Rendi admin';
  @override
  String get makeMember => 'Rendi membro';
  @override
  String makeAdminFor(String name) => 'Rendi admin $name';
  @override
  String makeMemberFor(String name) => 'Rendi membro $name';
  @override
  String get noMatch => 'Nessun membro corrisponde alla ricerca';
  @override
  List<(String, bool)> get membersNote => const [
    ('Gli admin da configurazione arrivano dalla variabile ', false),
    ('MINESYNC_ADMINS', true),
    (
      ': garantiscono sempre l\'accesso e si rimuovono solo modificandola e riavviando l\'hub. '
          'I nuovi dispositivi si autorizzano in ZTNET; qui si sceglie solo il ruolo.',
      false,
    ),
  ];
  @override
  String promoteTitle(String name) => 'Rendere admin $name?';
  @override
  String promoteBody(String name) =>
      '$name potrà modificare le impostazioni dell\'hub e i ruoli degli altri ed eliminare server e '
      'versioni. Effettivo dalla sua prossima richiesta.';
  @override
  String demoteTitle(String name) => 'Rendere $name un membro?';
  @override
  String demoteBody(String name) =>
      '$name non vedrà più l\'area Admin né le azioni da admin. Effettivo dalla sua prossima richiesta.';
  @override
  String get demoteSelf =>
      'Stai rimuovendo il tuo ruolo di admin: non potrai più accedere a questa pagina.';
  @override
  String roleDone(String name, bool admin) => admin ? '$name ora è admin' : '$name ora è membro';
  @override
  String get trust => 'Riconosci i membri anche con ZTNET irraggiungibile per';
  @override
  String get trustHint =>
      'Se ZTNET non risponde, l\'hub usa l\'ultimo elenco per questo intervallo. 0 = sempre.';
  @override
  String get refresh => 'Aggiorna l\'elenco dei membri ogni';
  @override
  String get refreshHint =>
      'Tempo massimo prima che un nuovo membro autorizzato in ZTNET venga riconosciuto.';
  @override
  String refreshDefault(int s, int min) => 'Predefinito: $s s, minimo $min s';

  @override
  String get systemLead =>
      'I valori «impostato all\'avvio» provengono dalle variabili d\'ambiente del container: '
      'servono prima che questa pagina sia disponibile, e un errore qui bloccherebbe l\'accesso. '
      'Per modificarli, cambia il file del container e riavvia l\'hub.';
  @override
  String get readOnly => 'Sola lettura';
  @override
  String get version => 'Versione';
  @override
  String versionBuild(String v, String build) => '$v (build $build)';
  @override
  String get uptime => 'In funzione da';
  @override
  String uptimeValue(Duration d) {
    final days = d.inDays;
    final h = d.inHours % 24;
    final m = d.inMinutes % 60;
    String dd(int n) => n == 1 ? '1 giorno' : '$n giorni';
    String hh(int n) => n == 1 ? '1 ora' : '$n ore';
    if (days > 0) return h == 0 ? dd(days) : '${dd(days)} ${hh(h)}';
    if (d.inHours > 0) return m == 0 ? hh(h) : '${hh(h)} $m min';
    return '${d.inMinutes} min';
  }

  @override
  String get disk => 'Spazio su disco';
  @override
  String diskValue(String free, String total) => '$free liberi su $total';
  @override
  String get http => 'Indirizzo HTTP';
  @override
  String get dns => 'DNS dei server';
  @override
  String get dnsHint => 'Assegna a ogni server un indirizzo fisso.';
  @override
  String dnsValue(String zone, String addr) => 'zona $zone su $addr';
  @override
  String get dnsOn => 'Attivo';
  @override
  String get dnsOff => 'Disattivato';
  @override
  String dnsBindError(String e) => 'Avvio non riuscito: $e';
  @override
  String get dnsNone => 'non configurato';
  @override
  String get hosts => 'Host ammessi';
  @override
  String get hostsHint => 'Protezione dal DNS rebinding.';
  @override
  String get hostsNone => 'solo indirizzi IP, localhost e la zona DNS';
  @override
  String get dataDir => 'Cartella dati';
  @override
  String get admins => 'Admin iniziali';
  @override
  String get adminsNone => 'nessuno';
  @override
  String get minFreeEnv => 'Spazio libero minimo';
  @override
  String get dl => 'App da scaricare';
  @override
  String get dlNone => 'nessuna';
  @override
  String get signing => 'Firma degli aggiornamenti';
  @override
  String get signingHint =>
      'Le app accettano solo aggiornamenti firmati. La chiave è inclusa nella build.';
  @override
  String get signed => 'Chiave presente';
  @override
  String get unsigned => 'Non firmati';
  @override
  String get partlySigned => 'Firmati in parte';
  @override
  String get noUpdates => 'Nessun aggiornamento pubblicato';
  @override
  String get tz => 'Fuso orario';
  @override
  String get web => 'Interfaccia web';
  @override
  String webValue(String id) => 'build $id';
  @override
  String get copyDiag => 'Copia diagnostica';
  @override
  String get systemError => 'Informazioni di sistema non disponibili';
}

final class _En extends AdminAccessStrings {
  const _En();
  @override
  String get membersLead =>
      'No passwords: the hub recognises devices on the ZeroTier network through ZTNET.';
  @override
  String get ztOk => 'Connected to ZTNET';
  @override
  String get ztErr => 'ZTNET not responding';
  @override
  String get ztOff => 'ZTNET not configured';
  @override
  String ztRefreshed(String ago, int n) =>
      'List refreshed $ago, ${n == 1 ? '1 authorized member' : '$n authorized members'} on '
      'the network.';
  @override
  String get ztNever => 'List not read yet.';
  @override
  String ztLastError(String when, String error) => 'Last error: $when, $error.';
  @override
  String get ztOffText =>
      'Without ZTNET the hub does not know the network members. Set ZTNET_URL, ZTNET_API_TOKEN '
      'and ZTNET_NETWORK_ID in the container file.';
  @override
  String get checkNow => 'Check now';
  @override
  String get checked => 'ZTNET checked';
  @override
  String get ztUrl => 'ZTNET address';
  @override
  String get ztToken => 'API token';
  @override
  String get ztNetwork => 'Network';
  @override
  String get secretsNote =>
      'Secret values used to recognise who opens this page: they can be changed only in the '
      'container file.';
  @override
  String get notSet => 'not set';

  @override
  String seenTitle(int n) => 'Members seen by the hub ($n)';
  @override
  String get searchMember => 'Search member';
  @override
  String get colMember => 'Member';
  @override
  String get colMemberNode => 'Member and node id';
  @override
  String get colIp => 'IP';
  @override
  String get colLast => 'Last access';
  @override
  String get colRole => 'Role';
  @override
  String get colActions => 'Actions';
  @override
  String get you => 'you';
  @override
  String get noName => 'no name';
  @override
  String get never => 'never';
  @override
  String get now => 'now';
  @override
  String get roleAdmin => 'Admin';
  @override
  String get roleMember => 'Member';
  @override
  String get fromConfig => 'from configuration';
  @override
  String get notRemovable => 'Not removable';
  @override
  String get notAuthorized => 'Not authorized';
  @override
  String get authorizeInZtnet => 'authorize in ZTNET';
  @override
  String get makeAdmin => 'Make admin';
  @override
  String get makeMember => 'Make member';
  @override
  String makeAdminFor(String name) => 'Make $name admin';
  @override
  String makeMemberFor(String name) => 'Make $name a member';
  @override
  String get noMatch => 'No member matches the search';
  @override
  List<(String, bool)> get membersNote => const [
    ('Admins from configuration come from the ', false),
    ('MINESYNC_ADMINS', true),
    (
      ' variable: they guarantee access at all times and are removed only by changing it '
          'and restarting the hub. New devices are authorized in ZTNET; only the role is chosen '
          'here.',
      false,
    ),
  ];
  @override
  String promoteTitle(String name) => 'Make $name an admin?';
  @override
  String promoteBody(String name) =>
      '$name will be able to change the hub settings and the roles of others, and delete servers '
      'and versions. Effective from their next request.';
  @override
  String demoteTitle(String name) => 'Make $name a member?';
  @override
  String demoteBody(String name) =>
      '$name will no longer see the Admin area or the admin actions. Effective from their next '
      'request.';
  @override
  String get demoteSelf =>
      'You are removing your own admin role: you will no longer be able to access this page.';
  @override
  String roleDone(String name, bool admin) =>
      admin ? '$name is now an admin' : '$name is now a member';
  @override
  String get trust => 'Recognise members while ZTNET is unreachable for';
  @override
  String get trustHint =>
      'If ZTNET is not responding, the hub uses the last list for this long. 0 = always.';
  @override
  String get refresh => 'Refresh the member list every';
  @override
  String get refreshHint => 'Maximum time before a new member authorized in ZTNET is recognised.';
  @override
  String refreshDefault(int s, int min) => 'Default: $s s, at least $min s';

  @override
  String get systemLead =>
      'The values "set at start" come from the container environment variables: they are needed '
      'before this page is available, and a mistake here would block access. To change them, '
      'edit the container file and restart the hub.';
  @override
  String get readOnly => 'Read only';
  @override
  String get version => 'Version';
  @override
  String versionBuild(String v, String build) => '$v (build $build)';
  @override
  String get uptime => 'Running for';
  @override
  String uptimeValue(Duration d) {
    final days = d.inDays;
    final h = d.inHours % 24;
    final m = d.inMinutes % 60;
    String dd(int n) => n == 1 ? '1 day' : '$n days';
    String hh(int n) => n == 1 ? '1 hour' : '$n hours';
    if (days > 0) return h == 0 ? dd(days) : '${dd(days)} ${hh(h)}';
    if (d.inHours > 0) return m == 0 ? hh(h) : '${hh(h)} $m min';
    return '${d.inMinutes} min';
  }

  @override
  String get disk => 'Disk space';
  @override
  String diskValue(String free, String total) => '$free free of $total';
  @override
  String get http => 'HTTP address';
  @override
  String get dns => 'Server DNS';
  @override
  String get dnsHint => 'Assigns each server a fixed address.';
  @override
  String dnsValue(String zone, String addr) => 'zone $zone on $addr';
  @override
  String get dnsOn => 'On';
  @override
  String get dnsOff => 'Off';
  @override
  String dnsBindError(String e) => 'Failed to start: $e';
  @override
  String get dnsNone => 'not configured';
  @override
  String get hosts => 'Allowed hosts';
  @override
  String get hostsHint => 'Protection against DNS rebinding.';
  @override
  String get hostsNone => 'only IP addresses, localhost and the DNS zone';
  @override
  String get dataDir => 'Data folder';
  @override
  String get admins => 'Initial admins';
  @override
  String get adminsNone => 'none';
  @override
  String get minFreeEnv => 'Minimum free space';
  @override
  String get dl => 'Apps to download';
  @override
  String get dlNone => 'none';
  @override
  String get signing => 'Update signing';
  @override
  String get signingHint =>
      'The apps accept only signed updates. The key is included in the build.';
  @override
  String get signed => 'Key present';
  @override
  String get unsigned => 'Not signed';
  @override
  String get partlySigned => 'Partly signed';
  @override
  String get noUpdates => 'No updates published';
  @override
  String get tz => 'Time zone';
  @override
  String get web => 'Web interface';
  @override
  String webValue(String id) => 'build $id';
  @override
  String get copyDiag => 'Copy diagnostics';
  @override
  String get systemError => 'System information not available';
}
