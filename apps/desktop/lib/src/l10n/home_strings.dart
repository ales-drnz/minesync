// Testi della Home: avvisi, server in card, attività, connessione, questo
// PC, stato vuoto, pre-scarico nella barra laterale e dialogo "Nuovo server".
import 'package:ms_l10n/ms_l10n.dart';
import 'package:ms_protocol/ms_protocol.dart' show EventType;

import 'format_strings.dart';

abstract final class HomeStrings {
  static HomeStrings of(Lang l) => switch (l) {
    Lang.it => const _It(),
    Lang.en => const _En(),
  };

  String get offlineTitle;
  String offlineText(int retrySeconds);
  String get retry;
  String hubFullTitle(String free, String total);
  String get hubFullText;
  String get cleanup;

  String get gcTitle;
  String get gcText;
  String get gcKeep;
  String gcKeepN(int n);
  String get gcVersions;
  String gcVersionsValue(int now, int after);
  String get gcFreed;
  String get gcOwnRules;
  String get gcLoading;
  String get gcNothing;
  String get gcForever;
  String get gcCancel;
  String get gcRun;
  String gcDone(int generations, String freed);
  String get gcFailed;
  String updateTitle(String version);
  String get updateText;
  String get later;
  String get restartNow;

  String hello(String name);
  String get question;
  String get newServer;
  String get stillEmpty;
  String playingOnline(int online);
  String playingSince(String since);
  String freeMeta(String who, String when);
  String get freeNever;
  String staleMeta(String duration);
  String get joinOn;
  String get addressPending;
  String get copyAddress;
  String get whatToDo;
  String get prefetch;
  String get youHost;
  String get youHostElsewhere;
  String get openSession;

  String get activity;
  String get showAll;
  String get showLess;
  String get olderActivity;
  String get olderFailed;
  String get noActivity;
  String eventBadge(String type);
  Rich eventText(
    String type,
    String? actor,
    String? space,
    Map<String, Object?> data,
    FormatStrings f,
  );

  String get connection;
  String get connected;
  String get offline;
  String get connecting;

  String get java;
  String get javaSearching;
  String get settings;

  String get emptyTitle;
  String get emptyText;
  String get createFirst;
  String get notAdminHint;
  String connectedTo(String hub, int ms);

  String get noServers;
  String get prefetchWord;
  String get prefetchHint;

  String get nsMinecraft;
  String get nsGeneric;
  String get nsMinecraftHint;
  String get nsGenericHint;
}

final class _It implements HomeStrings {
  const _It();
  @override
  String get offlineTitle => 'Offline: hub non raggiungibile';
  @override
  String offlineText(int retrySeconds) =>
      'I mondi su questo PC sono al sicuro. Per giocare serve l\'hub: controlla che ZeroTier sia '
      'attivo. Nuovo tentativo tra $retrySeconds s.';
  @override
  String get retry => 'Riprova';
  @override
  String hubFullTitle(String free, String total) =>
      'Disco dell\'hub quasi pieno: liberi $free su $total';
  @override
  String get hubFullText =>
      'I mondi salvati finora sono al sicuro. Se lo spazio finisce, i salvataggi successivi '
      'vengono rifiutati e il mondo resta solo sul PC di chi gioca. Un admin può eliminare le '
      'versioni vecchie.';
  @override
  String get cleanup => 'Pulizia…';

  @override
  String get gcTitle => 'Pulizia delle versioni vecchie';
  @override
  String get gcText =>
      'Le versioni più recenti di ogni server restano, quelle più vecchie vengono eliminate '
      'dall\'hub. Lo stato attuale dei mondi non cambia.';
  @override
  String get gcKeep => 'Versioni da tenere per server';
  @override
  String gcKeepN(int n) => 'ultime $n';
  @override
  String get gcVersions => 'Versioni sull\'hub';
  @override
  String gcVersionsValue(int now, int after) => 'da $now a $after';
  @override
  String get gcFreed => 'Spazio recuperato';
  @override
  String get gcOwnRules => 'regole proprie';
  @override
  String get gcLoading => 'Calcolo delle versioni eliminabili…';
  @override
  String get gcNothing => 'Nessuna versione da eliminare con questa scelta.';
  @override
  String get gcForever =>
      'Le versioni eliminate non si possono più ripristinare. La pulizia è possibile anche mentre '
      'qualcuno gioca.';
  @override
  String get gcCancel => 'Annulla';
  @override
  String get gcRun => 'Pulisci ora';
  @override
  String gcDone(int generations, String freed) =>
      'Pulizia completata: $generations versioni eliminate, $freed liberati';
  @override
  String get gcFailed => 'Pulizia non riuscita';
  @override
  String updateTitle(String version) => 'MineSync $version è pronto';
  @override
  String get updateText =>
      'Scaricato e verificato. Il riavvio richiede pochi secondi e non avviene mai mentre ospiti '
      'un server.';
  @override
  String get later => 'Più tardi';
  @override
  String get restartNow => 'Riavvia ora';

  @override
  String hello(String name) => 'Ciao $name';
  @override
  String get question => 'Scegli un server';
  @override
  String get newServer => 'Nuovo server';
  @override
  String get stillEmpty => 'ancora vuoto';
  @override
  String playingOnline(int online) => '$online online';
  @override
  String playingSince(String since) => 'da $since';
  @override
  String freeMeta(String who, String when) => '$who ha giocato $when';
  @override
  String get freeNever => 'nessuno ha ancora giocato';
  @override
  String staleMeta(String duration) => 'non risponde da $duration';
  @override
  String get joinOn => 'Entra da Minecraft su';
  @override
  String get addressPending => 'l\'indirizzo compare quando il server è pronto';
  @override
  String get copyAddress => 'Copia indirizzo';
  @override
  String get whatToDo => 'Cosa fare';
  @override
  String get prefetch => 'Download degli aggiornamenti';
  @override
  String get youHost => 'Ospitato da questo PC.';
  @override
  String get youHostElsewhere => 'Avviato a tuo nome, non in questa finestra.';
  @override
  String get openSession => 'Apri la sessione';

  @override
  String get activity => 'Attività';
  @override
  String get showAll => 'Tutta l\'attività';
  @override
  String get showLess => 'Meno attività';
  @override
  String get olderActivity => 'Più vecchie';
  @override
  String get olderFailed => 'Impossibile leggere l\'attività più vecchia.';
  @override
  String get noActivity => 'Nessuna attività.';
  @override
  String eventBadge(String type) => switch (type) {
    EventType.push => 'salvato',
    EventType.lock => 'in gioco',
    EventType.unlock => 'finito',
    EventType.stale => 'non risponde',
    EventType.force => 'forzato',
    EventType.port => 'porta',
    EventType.restore || EventType.restoreFile => 'ripristino',
    EventType.generationDelete => 'eliminata',
    EventType.disk => 'disco',
    EventType.gc || EventType.gcError => 'pulizia',
    EventType.spaceCreate => 'nuovo',
    EventType.spaceDelete => 'eliminato',
    EventType.spaceUpdate => 'modificato',
    EventType.settings => 'hub',
    EventType.memberRole => 'membri',
    EventType.ztnet => 'rete',
    EventType.telegramError => 'telegram',
    _ => type,
  };
  @override
  Rich eventText(
    String type,
    String? actor,
    String? space,
    Map<String, Object?> data,
    FormatStrings f,
  ) {
    final a = actor ?? '?';
    final sp = space ?? '?';
    return switch (type) {
      'push' => [(a, true), (' ha salvato ', false), (sp, true), (_sizeOf(data, f), false)],
      // lock preso solo per caricare (mod applicate, modifiche locali): non
      // è una partita
      EventType.lock when data['action'] == 'push' => [
        (a, true),
        (' carica ', false),
        (sp, true),
        (' dall\'app', false),
      ],
      EventType.lock => switch (data['tookOver']) {
        final String was when was == a => [(a, true), (' riprende ', false), (sp, true)],
        final String was => [
          (a, true),
          (' gioca su ', false),
          (sp, true),
          (' (era di $was)', false),
        ],
        _ => [(a, true), (' gioca su ', false), (sp, true)],
      },
      EventType.unlock => [
        (a, true),
        (' ha chiuso ', false),
        (sp, true),
        if (data['durationMs'] is int)
          (' dopo ${f.duration(Duration(milliseconds: data['durationMs']! as int))}', false),
      ],
      EventType.stale => [
        (sp, true),
        (': l\'app di ', false),
        ('${data['holder'] ?? a}', true),
        (' non risponde', false),
      ],
      EventType.force => [
        (a, true),
        (' ha liberato ', false),
        (sp, true),
        (' (era di ${data['from']})', false),
      ],
      EventType.port =>
        data['state'] == 'reachable'
            ? [
                ('La porta di ', false),
                (sp, true),
                (' è raggiungibile: gli amici possono entrare', false),
              ]
            : [
                ('La porta di ', false),
                (sp, true),
                (
                  ' non è raggiungibile dall\'esterno: gli amici potrebbero non riuscire a entrare',
                  false,
                ),
              ],
      EventType.restore => [
        (a, true),
        (' ha riportato ', false),
        (sp, true),
        (' alla #${data['restoredFrom']} (nuova #${data['n']})', false),
      ],
      EventType.restoreFile => [
        (a, true),
        (' ha ripreso ', false),
        (_fileName(data['path']), true),
        (' di ', false),
        (sp, true),
        (' dalla #${data['restoredFrom']} (nuova #${data['n']})', false),
      ],
      EventType.generationDelete => [
        (a, true),
        (' ha eliminato la #${data['n']} di ', false),
        (sp, true),
        (', liberati ${f.size(_int(data['bytes']))}', false),
      ],
      EventType.disk =>
        data['level'] == 'full'
            ? [('Disco dell\'hub pieno: i salvataggi vengono rifiutati', false)]
            : [
                (
                  'Disco dell\'hub quasi pieno: liberi ${f.size(_int(data['free']))} su '
                      '${f.size(_int(data['total']))}',
                  false,
                ),
              ],
      EventType.gc => [
        if (actor != null) ...[(a, true), (' ha fatto pulizia', false)],
        if (actor == null) ('Pulizia dell\'hub', false),
        if (space != null) ...[(' su ', false), (sp, true)],
        (
          ': tolte ${data['generations']} versioni vecchie, liberati '
              '${f.size(_int(data['bytes']))}',
          false,
        ),
      ],
      EventType.gcError => [('Pulizia dell\'hub non riuscita su ', false), (sp, true)],
      EventType.spaceCreate => [(a, true), (' ha creato ', false), ('${data['name'] ?? sp}', true)],
      EventType.spaceDelete => [(a, true), (' ha eliminato ', false), (sp, true)],
      EventType.spaceUpdate => [(a, true), (' ha modificato ', false), (sp, true)],
      EventType.settings => [(a, true), (' ha cambiato le impostazioni dell\'hub', false)],
      EventType.memberRole => [
        (a, true),
        (' ha reso ', false),
        ('${data['member'] ?? '?'}', true),
        (data['role'] == 'admin' ? ' admin' : ' membro', false),
      ],
      EventType.ztnet =>
        data['state'] == 'ok'
            ? [('Rete del gruppo di nuovo operativa', false)]
            : [('La rete del gruppo non risponde: entra solo chi era già riconosciuto', false)],
      EventType.telegramError => [('Il bot Telegram non riesce a inviare messaggi', false)],
      _ => [(type, false)],
    };
  }

  @override
  String get connection => 'Connessione';
  @override
  String get connected => 'Connesso';
  @override
  String get offline => 'Offline';
  @override
  String get connecting => 'Connessione…';

  @override
  String get java => 'Java';
  @override
  String get javaSearching => 'ricerca…';
  @override
  String get settings => 'Impostazioni';

  @override
  String get emptyTitle => 'Ancora nessun server';
  @override
  String get emptyText =>
      'Un server è un mondo condiviso: chi gioca lo ospita sul suo PC, gli altri entrano. A fine '
      'sessione il mondo si salva sull\'hub per il giocatore successivo.';
  @override
  String get createFirst => 'Crea il primo server';
  @override
  String get notAdminHint =>
      'Se non sei admin, chiedi a chi gestisce l\'hub di crearne uno: comparirà qui '
      'automaticamente.';
  @override
  String connectedTo(String hub, int ms) => 'Connesso a $hub ($ms ms)';

  @override
  String get noServers => 'Nessun server.';
  @override
  String get prefetchWord => 'Pre-scarico';
  @override
  String get prefetchHint => 'Il server parte subito quando premi Gioca.';

  @override
  @override
  String get nsMinecraft => 'Minecraft';
  @override
  String get nsGeneric => 'Cartella generica';
  @override
  String get nsMinecraftHint => 'Minecraft: mondo, mod e Java riconosciuti automaticamente.';
  @override
  String get nsGenericHint => 'Cartella generica: i file vengono sincronizzati così come sono.';
}

final class _En implements HomeStrings {
  const _En();
  @override
  String get offlineTitle => 'Offline: hub unreachable';
  @override
  String offlineText(int retrySeconds) =>
      'The worlds on this PC are safe. Playing requires the hub: check that ZeroTier is running. '
      'Retrying in $retrySeconds s.';
  @override
  String get retry => 'Try again';
  @override
  String hubFullTitle(String free, String total) => 'Hub disk nearly full: $free free of $total';
  @override
  String get hubFullText =>
      'The worlds saved so far are safe. If space runs out, further saves are refused and the '
      'world stays only on the host\'s PC. An admin can clean up old versions.';
  @override
  String get cleanup => 'Clean up…';

  @override
  String get gcTitle => 'Clean up old versions';
  @override
  String get gcText =>
      'The most recent versions of every server are kept and older ones are deleted from the '
      'hub. The current state of the worlds is not affected.';
  @override
  String get gcKeep => 'Versions to keep per server';
  @override
  String gcKeepN(int n) => 'last $n';
  @override
  String get gcVersions => 'Versions on the hub';
  @override
  String gcVersionsValue(int now, int after) => 'from $now to $after';
  @override
  String get gcFreed => 'Space freed';
  @override
  String get gcOwnRules => 'own rules';
  @override
  String get gcLoading => 'Calculating what can be removed…';
  @override
  String get gcNothing => 'Nothing to remove with this choice.';
  @override
  String get gcForever =>
      'Removed versions can no longer be restored. Cleanup can run while someone is playing.';
  @override
  String get gcCancel => 'Cancel';
  @override
  String get gcRun => 'Clean up now';
  @override
  String gcDone(int generations, String freed) =>
      'Cleanup complete: $generations versions removed, $freed freed';
  @override
  String get gcFailed => 'Cleanup failed';
  @override
  String updateTitle(String version) => 'MineSync $version is ready';
  @override
  String get updateText =>
      'Downloaded and verified. Restarting takes a few seconds and never happens while you host '
      'a server.';
  @override
  String get later => 'Later';
  @override
  String get restartNow => 'Restart now';

  @override
  String hello(String name) => 'Hi $name';
  @override
  String get question => 'Choose a server';
  @override
  String get newServer => 'New server';
  @override
  String get stillEmpty => 'still empty';
  @override
  String playingOnline(int online) => '$online online';
  @override
  String playingSince(String since) => 'for $since';
  @override
  String freeMeta(String who, String when) => '$who played $when';
  @override
  String get freeNever => 'nobody has played yet';
  @override
  String staleMeta(String duration) => 'not responding for $duration';
  @override
  String get joinOn => 'Join from Minecraft at';
  @override
  String get addressPending => 'the address appears when the server is ready';
  @override
  String get copyAddress => 'Copy address';
  @override
  String get whatToDo => 'What to do';
  @override
  String get prefetch => 'Downloading updates';
  @override
  String get youHost => 'Hosted from this PC.';
  @override
  String get youHostElsewhere => 'Started under your name, not in this window.';
  @override
  String get openSession => 'Open the session';

  @override
  String get activity => 'Activity';
  @override
  String get showAll => 'All activity';
  @override
  String get showLess => 'Less activity';
  @override
  String get olderActivity => 'Older';
  @override
  String get olderFailed => 'Unable to read older activity.';
  @override
  String get noActivity => 'No activity yet.';
  @override
  String eventBadge(String type) => switch (type) {
    EventType.push => 'saved',
    EventType.lock => 'playing',
    EventType.unlock => 'ended',
    EventType.stale => 'not responding',
    EventType.force => 'forced',
    EventType.port => 'port',
    EventType.restore || EventType.restoreFile => 'restore',
    EventType.generationDelete => 'deleted',
    EventType.disk => 'disk',
    EventType.gc || EventType.gcError => 'cleanup',
    EventType.spaceCreate => 'new',
    EventType.spaceDelete => 'deleted',
    EventType.spaceUpdate => 'changed',
    EventType.settings => 'hub',
    EventType.memberRole => 'members',
    EventType.ztnet => 'network',
    EventType.telegramError => 'telegram',
    _ => type,
  };
  @override
  Rich eventText(
    String type,
    String? actor,
    String? space,
    Map<String, Object?> data,
    FormatStrings f,
  ) {
    final a = actor ?? '?';
    final sp = space ?? '?';
    return switch (type) {
      'push' => [(a, true), (' saved ', false), (sp, true), (_sizeOf(data, f), false)],
      EventType.lock when data['action'] == 'push' => [
        (a, true),
        (' is uploading ', false),
        (sp, true),
        (' from the app', false),
      ],
      EventType.lock => switch (data['tookOver']) {
        final String was when was == a => [(a, true), (' resumes ', false), (sp, true)],
        final String was => [
          (a, true),
          (' is playing on ', false),
          (sp, true),
          (' (was $was\'s)', false),
        ],
        _ => [(a, true), (' is playing on ', false), (sp, true)],
      },
      EventType.unlock => [
        (a, true),
        (' closed ', false),
        (sp, true),
        if (data['durationMs'] is int)
          (' after ${f.duration(Duration(milliseconds: data['durationMs']! as int))}', false),
      ],
      EventType.stale => [
        (sp, true),
        (': ', false),
        ('${data['holder'] ?? a}', true),
        ('\'s app is not responding', false),
      ],
      EventType.force => [
        (a, true),
        (' freed ', false),
        (sp, true),
        (' (held by ${data['from']})', false),
      ],
      EventType.port =>
        data['state'] == 'reachable'
            ? [('The port of ', false), (sp, true), (' is reachable: friends can join', false)]
            : [
                ('The port of ', false),
                (sp, true),
                (' is not reachable from outside: friends may be unable to join', false),
              ],
      EventType.restore => [
        (a, true),
        (' brought ', false),
        (sp, true),
        (' back to #${data['restoredFrom']} (new #${data['n']})', false),
      ],
      EventType.restoreFile => [
        (a, true),
        (' took ', false),
        (_fileName(data['path']), true),
        (' of ', false),
        (sp, true),
        (' back from #${data['restoredFrom']} (new #${data['n']})', false),
      ],
      EventType.generationDelete => [
        (a, true),
        (' deleted #${data['n']} of ', false),
        (sp, true),
        (', freed ${f.size(_int(data['bytes']))}', false),
      ],
      EventType.disk =>
        data['level'] == 'full'
            ? [('The hub\'s disk is full: saves are being refused', false)]
            : [
                (
                  'The hub\'s disk is nearly full: ${f.size(_int(data['free']))} free of '
                      '${f.size(_int(data['total']))}',
                  false,
                ),
              ],
      EventType.gc => [
        if (actor != null) ...[(a, true), (' cleaned up', false)],
        if (actor == null) ('Hub cleanup', false),
        if (space != null) ...[(' on ', false), (sp, true)],
        (
          ': removed ${data['generations']} old versions, freed '
              '${f.size(_int(data['bytes']))}',
          false,
        ),
      ],
      EventType.gcError => [('Hub cleanup failed on ', false), (sp, true)],
      EventType.spaceCreate => [(a, true), (' created ', false), ('${data['name'] ?? sp}', true)],
      EventType.spaceDelete => [(a, true), (' deleted ', false), (sp, true)],
      EventType.spaceUpdate => [(a, true), (' changed ', false), (sp, true)],
      EventType.settings => [(a, true), (' changed the hub settings', false)],
      EventType.memberRole => [
        (a, true),
        (' made ', false),
        ('${data['member'] ?? '?'}', true),
        (data['role'] == 'admin' ? ' an admin' : ' a member', false),
      ],
      EventType.ztnet =>
        data['state'] == 'ok'
            ? [('Group network back online', false)]
            : [('The group network is not responding: only known members can join', false)],
      EventType.telegramError => [('The Telegram bot cannot send messages', false)],
      _ => [(type, false)],
    };
  }

  @override
  String get connection => 'Connection';
  @override
  String get connected => 'Connected';
  @override
  String get offline => 'Offline';
  @override
  String get connecting => 'Connecting…';

  @override
  String get java => 'Java';
  @override
  String get javaSearching => 'searching…';
  @override
  String get settings => 'Settings';

  @override
  String get emptyTitle => 'No servers yet';
  @override
  String get emptyText =>
      'A server is a shared world: the player hosts it on their PC, the others join. At the end '
      'of the session, the world is saved to the hub for the next player.';
  @override
  String get createFirst => 'Create the first server';
  @override
  String get notAdminHint =>
      'If you are not an admin, ask the hub admin to create one: it will appear here '
      'automatically.';
  @override
  String connectedTo(String hub, int ms) => 'Connected to $hub ($ms ms)';

  @override
  String get noServers => 'No servers.';
  @override
  String get prefetchWord => 'Pre-loading';
  @override
  String get prefetchHint => 'The server starts at once when you press Play.';

  @override
  @override
  String get nsMinecraft => 'Minecraft';
  @override
  String get nsGeneric => 'Generic folder';
  @override
  String get nsMinecraftHint => 'Minecraft: world, mods and Java detected automatically.';
  @override
  String get nsGenericHint => 'Generic folder: files are synced as they are.';
}

int _int(Object? v) => v is int ? v : 0;

/// Ultima parte di un percorso del mondo (`world/region/r.0.0.mca` →
/// `r.0.0.mca`).
String _fileName(Object? path) {
  final p = path is String ? path : '?';
  final i = p.lastIndexOf('/');
  return i < 0 ? p : p.substring(i + 1);
}

String _sizeOf(Map<String, Object?> data, FormatStrings f) {
  final stats = data['stats'];
  if (stats is Map<String, Object?> && stats['size'] is int) {
    return ' (${f.size(stats['size']! as int)})';
  }
  return '';
}
