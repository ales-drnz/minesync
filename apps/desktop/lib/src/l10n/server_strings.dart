// Testi del dettaglio di un server: stato del lock, Gioca, sull'hub, sul PC,
// trasferimento, azioni, dialoghi Java, impostazioni e "forza e gioca".
// Etichette del lock, schede e titoli delle versioni valgono anche per Home
// e Storia.
import 'package:ms_l10n/ms_l10n.dart';

import 'format_strings.dart';

/// Operazione di sincronizzazione (per i titoli degli esiti).
enum SyncOpName { pull, push, verify }

abstract final class ServerStrings {
  static ServerStrings of(Lang l) => switch (l) {
    Lang.it => const _It(),
    Lang.en => const _En(),
  };

  // --- comuni ---
  String get lockFree;
  String get lockPlay;
  String get lockStale;
  String get you;
  String get tabsLabel;
  String get tabOverview;
  String get tabHistory;
  String get play;
  String get details;
  String get copy;
  String get copied;
  String get close;
  String get cancel;
  String get head;
  String loaderName(String loader);
  String minecraft(String version);
  String get genericFolder;
  String mods(int n);
  String gen(int n);

  /// Titolo di una versione.
  String genTitle({
    required String kind,
    required String author,
    required String message,
    int? restoredFrom,
  });
  String statsLabel(int added, int changed, int removed);

  // --- Gioca ---
  String get freeTitle;
  String freeText(String name);
  String playingTitle(String who);
  String playingText(String since, int online);
  String copyAddressLabel(String address);
  String get noAddress;
  String get notifyMe;
  String get notifyOn;
  String lastSignal(String ago);
  String get worldWhere;
  String get forceAdmin;
  String get mineTitle;
  String get mineText;
  String get openSession;
  String staleTitle(String who);
  String get staleMineTitle;
  String get staleMineText;
  String get resume;

  /// [ago] null: il segnale è di un altro giorno, [time] lo dice già.
  String staleText(String time, String? ago);
  String get safeOnHub;
  String safeValue(int n, String who, String time);
  String maybeOnly(String who);
  String maybeValue(String time);
  String staleAdvice(String who, int n);
  String get forcePlay;
  String wait(String who);
  String get willNotify;

  // --- sull'hub ---
  String get onHub;
  String get noVersions;
  String get lastSave;
  String lastSaveValue(String who, String ago);
  String get status;
  String get online;
  String players(int n);

  // --- sul PC ---
  String get onPc;
  String toDownload(int files);
  String get upToDate;
  String get folder;
  String get modpack;
  String get launch;
  String get launchMissing;
  String copyBehind(int base, int head);
  String get copyNever;
  String javaOldTitle(int have);
  String javaOldText(int need, int? better);
  String javaNoneTitle(int need);
  String javaNoneText(int need);
  String useJava(int major);

  // --- trasferimento ---
  String get transfer;
  String get inBackground;
  String transferTitle(String phase, SyncOpName op, int? target);
  String filesOf(int done, int total);
  String bytesOf(String done, String total, String? speed);
  String eta(String d);
  String transferLabel(String name);

  // --- esiti ---
  String pulledTitle(int n);
  String pulledText(int written, int deleted);
  String backupText(String dir);
  String pushedTitle(int n);
  String get nothingToPush;
  String keptText(int count, String first);
  String get verifyOkTitle;
  String verifyOkText(int files);
  String get verifyDiffTitle;
  String verifyDiffText(int changed, int missing, int extra);
  String failedTitle(SyncOpName op);
  String get dirtyTitle;
  String dirtyText({required bool diverged, required int changed, required int removed});
  String get uploadMine;
  String get downloadAnyway;
  String get unreachable;

  // --- altre azioni ---
  String get more;
  String get change;
  String get folderLater;
  String firstDownload(String size);
  String get address;
  String get pull;
  String get push;
  String get verify;
  String get java;
  String get javaHint;
  String get openFolder;
  String get settings;

  // --- dialogo Java ---
  String javaTitle(String name);
  String javaNeeds(int n);
  String get javaSearching;
  String get javaNone;
  String javaOption(int major);
  String get javaInPack;
  String get javaRescan;
  String get javaRecommended;

  // --- dialogo impostazioni ---
  String settingsTitle(String name);
  String get folderLabel;
  String get folderHint;
  String get save;

  // --- forza e gioca ---
  String get forceStepAdmin;
  String get forceStep;
  String forceTitle(String name);
  String releaseTitle(String name);
  Rich forceBody(String who, int friends);
  Rich releaseBody(String who, String ago);
  String get risk;
  String riskValue(String who);
  String get forceAdvice;
  String releaseAdvice(String who);
  String get continueLabel;
  String get sureTitle;
  Rich get sureBody;
  String disconnected(int friends);
  String get mayLose;
  String get mayLoseValue;
  String get lastOnHub;
  String get then;
  String thenValue(String name, int n);
  String get noWait;
  String get yesForce;
  String get forceFailed;
}

final class _It implements ServerStrings {
  const _It();
  @override
  String get lockFree => 'Libero';
  @override
  String get lockPlay => 'In gioco';
  @override
  String get lockStale => 'Non risponde';
  @override
  String get you => 'tu';
  @override
  String get tabsLabel => 'Sezioni del server';
  @override
  String get tabOverview => 'Panoramica';
  @override
  String get tabHistory => 'Storia';
  @override
  String get play => 'Gioca';
  @override
  String get details => 'Dettagli';
  @override
  String get copy => 'Copia';
  @override
  String get copied => 'Copiato negli appunti';
  @override
  String get close => 'Chiudi';
  @override
  String get cancel => 'Annulla';
  @override
  String get head => 'attuale';
  @override
  String loaderName(String loader) => _loader(loader);
  @override
  String minecraft(String version) => 'Minecraft $version';
  @override
  String get genericFolder => 'Cartella generica';
  @override
  String mods(int n) => n == 1 ? '1 mod' : '$n mod';
  @override
  String gen(int n) => 'versione $n';
  @override
  String genTitle({
    required String kind,
    required String author,
    required String message,
    int? restoredFrom,
  }) => switch (kind) {
    'autosave' => 'Salvataggio automatico',
    'restore' => 'Ripristino della versione ${restoredFrom ?? '?'}',
    _ =>
      message.isNotEmpty
          ? Strings.of(Lang.it).autoMessage(message) ?? message
          : 'Salvataggio di $author',
  };
  @override
  String statsLabel(int added, int changed, int removed) => _stats(
    added + changed + removed,
    (n) => n == 1 ? '1 file cambiato' : '$n file cambiati',
    'nessun cambiamento',
  );

  @override
  String get freeTitle => 'Nessuno sta giocando';
  @override
  String freeText(String name) =>
      'Il server si avvia su questo PC e gli altri giocatori possono entrare. Alla chiusura il '
      'mondo torna sull\'hub.';
  @override
  String playingTitle(String who) => '$who sta giocando';
  @override
  String playingText(String since, int online) =>
      'Da $since, $online online. Per entrare: Minecraft › Multigiocatore › Aggiungi server, '
      'con questo indirizzo.';
  @override
  String copyAddressLabel(String address) => 'Copia indirizzo $address';

  @override
  String get noAddress => 'Indirizzo disponibile quando il server è pronto.';

  @override
  String get notifyMe => 'Avvisa quando è libero';

  @override
  String get notifyOn => 'Avviso attivo';
  @override
  String lastSignal(String ago) => 'Ultimo segnale $ago';
  @override
  String get worldWhere => 'Dove si trova il mondo';
  @override
  String get forceAdmin => 'Forza e gioca… (admin)';
  @override
  String get mineTitle => 'Avviato a tuo nome, non in questa finestra';
  @override
  String get mineText =>
      'Se MineSync si è chiuso durante la partita, entro 90 secondi il server risulta «Non risponde» e si può riavviare.';
  @override
  String get openSession => 'Apri la sessione';
  @override
  String staleTitle(String who) => 'L\'app di $who non risponde';
  @override
  String get staleMineTitle => 'La tua sessione precedente non risponde';
  @override
  String get staleMineText =>
      'MineSync si è chiuso mentre ospitavi. Riprendi per recuperare il mondo salvato su questo PC e caricarlo sull\'hub.';
  @override
  String get resume => 'Riprendi';
  @override
  String staleText(String time, String? ago) =>
      'Nessun segnale dalle $time${ago == null ? '' : ' ($ago)'}. Possibile chiusura anomala o perdita di rete.';
  @override
  String get safeOnHub => 'Al sicuro sull\'hub';
  @override
  String safeValue(int n, String who, String time) => 'tutto fino alle $time, salvato da $who';
  @override
  String maybeOnly(String who) => 'Forse solo sul PC di $who';
  @override
  String maybeValue(String time) => 'gli ultimi minuti di gioco dopo le $time';
  @override
  String staleAdvice(String who, int n) =>
      'Se aspetti, $who può tornare e salvarli. Se forzi, si riparte dall\'ultimo salvataggio.';
  @override
  String get forcePlay => 'Forza e gioca…';

  @override
  String wait(String who) => 'Attendi $who';
  @override
  String get willNotify => 'Riceverai una notifica quando il server sarà libero.';

  @override
  String get onHub => 'Sull\'hub';
  @override
  String get noVersions => 'nessuna versione';
  @override
  String get lastSave => 'Ultimo salvataggio';
  @override
  String lastSaveValue(String who, String ago) => '$who, $ago';
  @override
  String get status => 'Stato';
  @override
  String get online => 'Online';
  @override
  String players(int n) => n == 1 ? '1 giocatore' : '$n giocatori';

  @override
  String get onPc => 'Sul tuo PC';
  @override
  String toDownload(int files) => files == 1 ? '1 file da scaricare' : '$files file da scaricare';
  @override
  String get upToDate => 'aggiornato';
  @override
  String get folder => 'Cartella';
  @override
  String get modpack => 'Modpack';
  @override
  String get launch => 'Avvio';
  @override
  String get launchMissing => 'non trovato';
  @override
  String copyBehind(int base, int head) {
    final n = head - base;
    return base == 0
        ? 'mai sincronizzata'
        : n == 1
        ? '1 aggiornamento da scaricare'
        : '$n aggiornamenti da scaricare';
  }

  @override
  String get copyNever => 'mai sincronizzata';
  @override
  String javaOldTitle(int have) => 'Java $have è troppo vecchio per questo modpack';
  @override
  String javaOldText(int need, int? better) => better == null
      ? 'Serve Java $need. Installalo (per esempio Eclipse Temurin), poi cercalo di nuovo da Java.'
      : 'Serve Java $need. Su questo PC è presente anche Java $better: selezionalo.';
  @override
  String javaNoneTitle(int need) => 'Nessun Java $need su questo PC';
  @override
  String javaNoneText(int need) =>
      'Il server richiede Java $need. Installalo (per esempio Eclipse Temurin), poi cercalo di '
      'nuovo da Java.';
  @override
  String useJava(int major) => 'Usa Java $major';

  @override
  String get transfer => 'Trasferimento';
  @override
  String get inBackground => 'in background';
  @override
  String transferTitle(String phase, SyncOpName op, int? target) => switch (phase) {
    'scan' => 'Controllo dei file…',
    'commit' => 'Completamento del caricamento…',
    'download' => 'Scaricamento degli aggiornamenti',
    'upload' => 'Caricamento sull\'hub',
    _ => switch (op) {
      SyncOpName.pull => 'Preparazione dello scaricamento…',
      SyncOpName.push => 'Preparazione del caricamento…',
      SyncOpName.verify => 'Rilettura di tutti i file…',
    },
  };
  @override
  String filesOf(int done, int total) => '$done di $total file';
  @override
  String bytesOf(String done, String total, String? speed) =>
      speed == null ? '$done di $total' : '$done di $total, $speed';
  @override
  String eta(String d) => 'mancano circa $d';
  @override
  String transferLabel(String name) => 'Trasferimento di $name';

  @override
  String pulledTitle(int n) => 'Aggiornato alla versione $n';
  @override
  String pulledText(int written, int deleted) => '$written file scritti, $deleted rimossi.';
  @override
  String backupText(String dir) => 'Modifiche locali copiate in $dir.';
  @override
  String pushedTitle(int n) => 'Versione $n caricata';
  @override
  String get nothingToPush => 'Nessuna modifica da caricare: la copia locale coincide con l\'hub.';
  @override
  String keptText(int count, String first) =>
      '$count file non leggibili (es. $first): sull\'hub resta la versione precedente.';
  @override
  String get verifyOkTitle => 'Verifica completata';
  @override
  String verifyOkText(int files) => '$files file identici all\'ultima sincronizzazione.';
  @override
  String get verifyDiffTitle => 'Differenze rilevate';
  @override
  String verifyDiffText(int changed, int missing, int extra) =>
      'Rispetto all\'ultima sincronizzazione: $changed modificati, $missing mancanti, $extra '
      'nuovi.';
  @override
  String failedTitle(SyncOpName op) => switch (op) {
    SyncOpName.pull => 'Scaricamento non riuscito',
    SyncOpName.push => 'Caricamento non riuscito',
    SyncOpName.verify => 'Verifica non riuscita',
  };
  @override
  String get dirtyTitle => 'Modifiche non salvate su questo PC';
  @override
  String dirtyText({required bool diverged, required int changed, required int removed}) => diverged
      ? '$changed file modificati e $removed rimossi non ancora caricati. Nel frattempo è stato '
            'salvato un altro stato sull\'hub. Scaricando, le modifiche locali vengono prima '
            'copiate in un backup.'
      : '$changed file modificati e $removed rimossi non ancora caricati. Caricali sull\'hub prima '
            'di scaricare.';
  @override
  String get uploadMine => 'Carica le modifiche locali';
  @override
  String get downloadAnyway => 'Scarica e tieni un backup';
  @override
  String get unreachable => 'Hub non raggiungibile. Controlla che ZeroTier sia attivo.';

  @override
  String get more => 'Altro';
  @override
  String get change => 'Cambia';
  @override
  String get folderLater => 'Il server viene scaricato qui al primo avvio.';
  @override
  String firstDownload(String size) => '$size da scaricare al primo avvio';

  @override
  String get address => 'Indirizzo';
  @override
  String get pull => 'Scarica dall\'hub';
  @override
  String get push => 'Carica sull\'hub';
  @override
  String get verify => 'Verifica integrità';
  @override
  String get java => 'Java';
  @override
  String get javaHint => 'Scegli quale Java usare per questo server.';
  @override
  String get openFolder => 'Apri cartella';
  @override
  String get settings => 'Impostazioni server';

  @override
  String javaTitle(String name) => 'Java per $name';
  @override
  String javaNeeds(int n) => n > 0
      ? 'Questo server richiede Java $n.'
      : 'Versione di Java richiesta non nota: di solito va bene la più recente.';
  @override
  String get javaSearching => 'Ricerca di Java su questo PC…';
  @override
  String get javaNone => 'Nessun Java trovato su questo PC.';
  @override
  String javaOption(int major) => major > 0 ? 'Java $major' : 'Java (versione ignota)';
  @override
  String get javaInPack => 'nel pacchetto del server';
  @override
  String get javaRescan => 'Cerca di nuovo';
  @override
  String get javaRecommended => 'consigliato';

  @override
  String settingsTitle(String name) => 'Impostazioni di $name';
  @override
  String get folderLabel => 'Cartella su questo PC';
  @override
  String get folderHint =>
      'Per spostare il server, sposta prima la cartella e poi indicala qui. Nessun file viene copiato.';
  @override
  String get save => 'Salva';

  @override
  String get forceStepAdmin => 'Conferma 1 di 2, solo admin';
  @override
  String get forceStep => 'Conferma 1 di 2';
  @override
  String forceTitle(String name) => 'Forzare $name?';
  @override
  String releaseTitle(String name) => 'Liberare $name?';
  @override
  Rich forceBody(String who, int friends) => [
    ('$who sta giocando adesso', true),
    (
      friends == 0
          ? '. Se forzi, la sua sessione si interrompe e il server passa a te.'
          : friends == 1
          ? ', con 1 altro giocatore. Se forzi, la sua sessione si interrompe e il server passa a te.'
          : ', con altri $friends giocatori. Se forzi, la sua sessione si interrompe e il server '
                'passa a te.',
      false,
    ),
  ];
  @override
  Rich releaseBody(String who, String ago) => [
    ('L\'app di $who non risponde', true),
    (' da $ago. Se forzi, il server viene liberato e puoi ospitarlo.', false),
  ];
  @override
  String get risk => 'Rischio';
  @override
  String riskValue(String who) => '$who perde al massimo i minuti di gioco non ancora salvati';
  @override
  String get forceAdvice => 'Prima contatta chi sta giocando. Forza solo se il suo PC è bloccato.';
  @override
  String releaseAdvice(String who) => 'Se aspetti, $who può tornare e salvare gli ultimi minuti.';
  @override
  String get continueLabel => 'Continua…';
  @override
  String get sureTitle => 'Conferma finale';
  @override
  Rich get sureBody => const [
    ('Questa operazione ', false),
    ('non può essere annullata', true),
    ('.', false),
  ];
  @override
  String disconnected(int friends) => friends == 0
      ? 'viene disconnesso subito'
      : friends == 1
      ? 'viene disconnesso subito, con 1 altro giocatore'
      : 'viene disconnesso subito, con altri $friends giocatori';
  @override
  String get mayLose => 'Può perdere';
  @override
  String get mayLoseValue => 'al massimo i minuti di gioco non ancora salvati';
  @override
  String get lastOnHub => 'Ultimo salvataggio sull\'hub';
  @override
  String get then => 'Poi';
  @override
  String thenValue(String name, int n) => '$name riparte su questo PC dalla versione $n';
  @override
  String get noWait => 'Attendi';
  @override
  String get yesForce => 'Forza e gioca';
  @override
  String get forceFailed => 'Impossibile liberare il server';
}

final class _En implements ServerStrings {
  const _En();
  @override
  String get lockFree => 'Free';
  @override
  String get lockPlay => 'Playing';
  @override
  String get lockStale => 'Not responding';
  @override
  String get you => 'you';
  @override
  String get tabsLabel => 'Server sections';
  @override
  String get tabOverview => 'Overview';
  @override
  String get tabHistory => 'History';
  @override
  String get play => 'Play';
  @override
  String get details => 'Details';
  @override
  String get copy => 'Copy';
  @override
  String get copied => 'Copied to the clipboard';
  @override
  String get close => 'Close';
  @override
  String get cancel => 'Cancel';
  @override
  String get head => 'current';
  @override
  String loaderName(String loader) => _loader(loader);
  @override
  String minecraft(String version) => 'Minecraft $version';
  @override
  String get genericFolder => 'Generic folder';
  @override
  String mods(int n) => n == 1 ? '1 mod' : '$n mods';
  @override
  String gen(int n) => 'version $n';
  @override
  String genTitle({
    required String kind,
    required String author,
    required String message,
    int? restoredFrom,
  }) => switch (kind) {
    'autosave' => 'Autosave',
    'restore' => 'Restore of version ${restoredFrom ?? '?'}',
    _ =>
      message.isNotEmpty ? Strings.of(Lang.en).autoMessage(message) ?? message : 'Saved by $author',
  };
  @override
  String statsLabel(int added, int changed, int removed) => _stats(
    added + changed + removed,
    (n) => n == 1 ? '1 file changed' : '$n files changed',
    'no changes',
  );

  @override
  String get freeTitle => 'Nobody is playing';
  @override
  String freeText(String name) =>
      'The server starts on this PC and other players can join. When it closes, the world goes '
      'back to the hub.';
  @override
  String playingTitle(String who) => '$who is playing';
  @override
  String playingText(String since, int online) =>
      'For $since, $online online. To join: Minecraft › Multiplayer › Add Server, with the '
      'this address.';
  @override
  String copyAddressLabel(String address) => 'Copy address $address';

  @override
  String get noAddress => 'Address available when the server is ready.';

  @override
  String get notifyMe => 'Notify when free';

  @override
  String get notifyOn => 'Notification on';
  @override
  String lastSignal(String ago) => 'Last signal $ago';
  @override
  String get worldWhere => 'Where the world is';
  @override
  String get forceAdmin => 'Force and play… (admin)';
  @override
  String get mineTitle => 'Started under your name, not in this window';
  @override
  String get mineText =>
      'If MineSync closed during the session, within 90 seconds the server shows «Not responding» and can be restarted.';
  @override
  String get openSession => 'Open the session';
  @override
  String staleTitle(String who) => '$who\'s app is not responding';
  @override
  String get staleMineTitle => 'Your previous session is not responding';
  @override
  String get staleMineText =>
      'MineSync closed while you were hosting. Resume to recover the world saved on this PC and upload it to the hub.';
  @override
  String get resume => 'Resume';
  @override
  String staleText(String time, String? ago) =>
      'No signal since $time${ago == null ? '' : ' ($ago)'}. The app may have closed unexpectedly or lost the network.';
  @override
  String get safeOnHub => 'Safe on the hub';
  @override
  String safeValue(int n, String who, String time) => 'everything up to $time, saved by $who';
  @override
  String maybeOnly(String who) => 'Maybe only on $who\'s PC';
  @override
  String maybeValue(String time) => 'the last minutes of play after $time';
  @override
  String staleAdvice(String who, int n) =>
      'If you wait, $who can come back and save them. If you force, it restarts from the last save.';
  @override
  String get forcePlay => 'Force and play…';

  @override
  String wait(String who) => 'Wait for $who';
  @override
  String get willNotify => 'You will be notified when the server is free.';

  @override
  String get onHub => 'On the hub';
  @override
  String get noVersions => 'no versions yet';
  @override
  String get lastSave => 'Last save';
  @override
  String lastSaveValue(String who, String ago) => '$who, $ago';
  @override
  String get status => 'Status';
  @override
  String get online => 'Online';
  @override
  String players(int n) => n == 1 ? '1 player' : '$n players';

  @override
  String get onPc => 'On your PC';
  @override
  String toDownload(int files) => files == 1 ? '1 file to download' : '$files files to download';
  @override
  String get upToDate => 'up to date';
  @override
  String get folder => 'Folder';
  @override
  String get modpack => 'Modpack';
  @override
  String get launch => 'Start';
  @override
  String get launchMissing => 'not found';
  @override
  String copyBehind(int base, int head) {
    final n = head - base;
    return base == 0
        ? 'never synced'
        : n == 1
        ? '1 update to download'
        : '$n updates to download';
  }

  @override
  String get copyNever => 'never synced';
  @override
  String javaOldTitle(int have) => 'Java $have is too old for this modpack';
  @override
  String javaOldText(int need, int? better) => better == null
      ? 'Java $need is required. Install it (for example Eclipse Temurin), then search again from '
            'Java.'
      : 'Java $need is required. Java $better is also on this PC: select it.';
  @override
  String javaNoneTitle(int need) => 'No Java $need on this PC';
  @override
  String javaNoneText(int need) =>
      'The server requires Java $need. Install it (for example Eclipse Temurin), then search '
      'again from Java.';
  @override
  String useJava(int major) => 'Use Java $major';

  @override
  String get transfer => 'Transfer';
  @override
  String get inBackground => 'in the background';
  @override
  String transferTitle(String phase, SyncOpName op, int? target) => switch (phase) {
    'scan' => 'Checking the files…',
    'commit' => 'Finishing the upload…',
    'download' => 'Downloading updates',
    'upload' => 'Uploading to the hub',
    _ => switch (op) {
      SyncOpName.pull => 'Preparing the download…',
      SyncOpName.push => 'Preparing the upload…',
      SyncOpName.verify => 'Re-reading every file…',
    },
  };
  @override
  String filesOf(int done, int total) => '$done of $total files';
  @override
  String bytesOf(String done, String total, String? speed) =>
      speed == null ? '$done of $total' : '$done of $total, $speed';
  @override
  String eta(String d) => 'about $d left';
  @override
  String transferLabel(String name) => 'Transfer of $name';

  @override
  String pulledTitle(int n) => 'Updated to version $n';
  @override
  String pulledText(int written, int deleted) => '$written files written, $deleted removed.';
  @override
  String backupText(String dir) => 'Local changes copied to $dir.';
  @override
  String pushedTitle(int n) => 'Version $n uploaded';
  @override
  String get nothingToPush => 'No changes to upload: the local copy matches the hub.';
  @override
  String keptText(int count, String first) =>
      '$count unreadable files (e.g. $first): the hub keeps their previous version.';
  @override
  String get verifyOkTitle => 'Check passed';
  @override
  String verifyOkText(int files) => '$files files match the last sync.';
  @override
  String get verifyDiffTitle => 'Differences found';
  @override
  String verifyDiffText(int changed, int missing, int extra) =>
      'Compared with the last sync: $changed changed, $missing missing, $extra new.';
  @override
  String failedTitle(SyncOpName op) => switch (op) {
    SyncOpName.pull => 'Download failed',
    SyncOpName.push => 'Upload failed',
    SyncOpName.verify => 'Check failed',
  };
  @override
  String get dirtyTitle => 'Unsaved changes on this PC';
  @override
  String dirtyText({required bool diverged, required int changed, required int removed}) => diverged
      ? '$changed changed and $removed removed files not uploaded yet. Meanwhile, a different '
            'state was saved to the hub. Downloading first copies the local changes to a backup.'
      : '$changed changed and $removed removed files not uploaded yet. Upload them to the hub '
            'before downloading.';
  @override
  String get uploadMine => 'Upload local changes';
  @override
  String get downloadAnyway => 'Download and keep a backup';
  @override
  String get unreachable => 'Hub not reachable. Check that ZeroTier is running.';

  @override
  String get more => 'More';
  @override
  String get change => 'Change';
  @override
  String get folderLater => 'The server is downloaded here on first start.';
  @override
  String firstDownload(String size) => '$size to download on first start';

  @override
  String get address => 'Address';
  @override
  String get pull => 'Download from the hub';
  @override
  String get push => 'Upload to the hub';
  @override
  String get verify => 'Check integrity';
  @override
  String get java => 'Java';
  @override
  String get javaHint => 'Choose which Java to use for this server.';
  @override
  String get openFolder => 'Open folder';
  @override
  String get settings => 'Server settings';

  @override
  String javaTitle(String name) => 'Java for $name';
  @override
  String javaNeeds(int n) => n > 0
      ? 'This server requires Java $n.'
      : 'Required Java version unknown: the newest usually works.';
  @override
  String get javaSearching => 'Searching for Java on this PC…';
  @override
  String get javaNone => 'No Java found on this PC.';
  @override
  String javaOption(int major) => major > 0 ? 'Java $major' : 'Java (unknown version)';
  @override
  String get javaInPack => 'inside the server package';
  @override
  String get javaRescan => 'Search again';
  @override
  String get javaRecommended => 'recommended';

  @override
  String settingsTitle(String name) => '$name settings';
  @override
  String get folderLabel => 'Folder on this PC';
  @override
  String get folderHint =>
      'To move the server, move the folder first and then select it here. No files are copied.';
  @override
  String get save => 'Save';

  @override
  String get forceStepAdmin => 'Confirmation 1 of 2, admins only';
  @override
  String get forceStep => 'Confirmation 1 of 2';
  @override
  String forceTitle(String name) => 'Force $name?';
  @override
  String releaseTitle(String name) => 'Free $name?';
  @override
  Rich forceBody(String who, int friends) => [
    ('$who is playing right now', true),
    (
      friends == 0
          ? '. If you force, their session stops and the server passes to you.'
          : friends == 1
          ? ', with 1 other player. If you force, their session stops and the server passes to you.'
          : ', with $friends other players. If you force, their session stops and the server '
                'passes to you.',
      false,
    ),
  ];
  @override
  Rich releaseBody(String who, String ago) => [
    ('$who\'s app is not responding', true),
    (' for $ago. If you force, the server is freed and you can host it.', false),
  ];
  @override
  String get risk => 'Risk';
  @override
  String riskValue(String who) => '$who loses at most the minutes of play not saved yet';
  @override
  String get forceAdvice => 'Contact the player first. Force only if their PC is stuck.';
  @override
  String releaseAdvice(String who) => 'If you wait, $who can come back and save the last minutes.';
  @override
  String get continueLabel => 'Continue…';
  @override
  String get sureTitle => 'Final confirmation';
  @override
  Rich get sureBody => const [('This action ', false), ('cannot be undone', true), ('.', false)];
  @override
  String disconnected(int friends) => friends == 0
      ? 'is disconnected immediately'
      : friends == 1
      ? 'is disconnected immediately, with 1 other player'
      : 'is disconnected immediately, with $friends other players';
  @override
  String get mayLose => 'May lose';
  @override
  String get mayLoseValue => 'at most the minutes of play not saved yet';
  @override
  String get lastOnHub => 'Last save on the hub';
  @override
  String get then => 'Then';
  @override
  String thenValue(String name, int n) => '$name restarts on this PC from version $n';
  @override
  String get noWait => 'Wait';
  @override
  String get yesForce => 'Force and play';
  @override
  String get forceFailed => 'Unable to free the server';
}

String _loader(String loader) => switch (loader) {
  'fabric' => 'Fabric',
  'forge' => 'Forge',
  'neoforge' => 'NeoForge',
  'quilt' => 'Quilt',
  'vanilla' => 'Vanilla',
  'paper' => 'Paper',
  _ => loader,
};

String _stats(int n, String Function(int) some, String none) => n == 0 ? none : some(n);
