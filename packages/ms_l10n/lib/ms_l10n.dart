/// Testi in italiano e inglese condivisi da app, hub web e CLI. Ogni testo è
/// un metodo: una lingua a cui manca un testo non compila.
library;

/// Lingue supportate.
enum Lang { it, en }

/// Riconosce una lingua da una stringa di locale (`it`, `it_IT.UTF-8`,
/// `it-IT`, `IT`, `it_CH@euro`, `en_US`...) o da un elenco separato da
/// virgole o due punti (vince la prima supportata). `C`, `POSIX` e lingue non
/// supportate danno null.
Lang? parseLang(String? s) {
  if (s == null) return null;
  for (final raw in s.split(RegExp('[,:]'))) {
    final part = raw.trim();
    if (part.contains(';q=0') && !part.contains(';q=0.')) continue;
    final code = part.split(RegExp('[-_.@;]')).first.toLowerCase();
    for (final l in Lang.values) {
      if (l.name == code) return l;
    }
  }
  return null;
}

/// Lingua dalle variabili d'ambiente di sistema (LC_ALL, LC_MESSAGES,
/// LANGUAGE, LANG), con [fallback] se nessuna è riconosciuta.
Lang langFromEnv(Map<String, String> env, {Lang fallback = Lang.en}) {
  for (final k in ['MINESYNC_LANG', 'LC_ALL', 'LC_MESSAGES', 'LANGUAGE', 'LANG']) {
    final l = parseLang(env[k]);
    if (l != null) return l;
  }
  return fallback;
}

/// Testi per lingua.
abstract final class Strings {
  static Strings of(Lang l) => switch (l) {
    Lang.it => const _It(),
    Lang.en => const _En(),
  };

  Lang get lang;

  /// Testo di un messaggio riservato dei caricamenti automatici
  /// (`AutoMessage` di ms_protocol), o null se [message] è un messaggio
  /// scritto da una persona.
  String? autoMessage(String message);

  // --- generali ---
  String get yes;
  String get no;
  String sizeBytes(int bytes);

  // --- CLI: uso ---
  String get cliUsage;
  String cliUnknownCommand(String c);
  String get cliNoHub;
  String cliConnected(String hub, String name, bool admin);
  String get cliNoSpaces;
  String get cliNotLinked;
  String cliLinked(String space, String folder);
  String get cliLockFree;
  String cliLockHeld(String who, bool stale);
  String cliHead(int n, String author);
  String get cliEmptySpace;
  String cliLocalBase(int? n);
  String cliPulled(int n, int written, int deleted);
  String cliBackup(String dir);
  String get cliNothingToPush;
  String cliPushed(int n, int uploaded);
  String cliKept(int count, String first);
  String cliVerifyOk(int files);
  String cliVerifyDiff(int changed, int missing, int extra);
  String get cliUnreachable;
  String cliError(String message);
  String cliProgress(String phase, int done, int total);

  // --- CLI: play ---
  String get playNoLaunch;
  String get playEulaNeeded;
  String playJavaMissing(int required);
  String playStarting(String label, String? java);
  String playState(String state);
  String playSaved(int n);
  String playWarning(String code);
  String playAlert(String kind);
  String playCrashed(int? code, bool restarting);
  String get playGuardMissing;

  // --- errori del sync ---
  String errDirtyLocal({required bool diverged, required int changed, required int removed});
  String get errStaleBase;
  String errMassDelete(int removed);
  String get errEmptyRemote;
  String get errLockLost;
  String errLocked(String who);
  String get errSpaceGone;
  String get errBadManifest;
  String get errCorruptDownload;
  String get errBlobRejected;
  String get errLocalDiskFull;
  String get errHubDiskFull;
  String errDirSymlink(String path);
  String get errStalled;
  String get errUnauthenticated;
  String get errForbidden;
  String get errOutboxNoSpace;
  String get errSnapshotStale;
  String get errCancelled;
}

final class _It implements Strings {
  @override
  String? autoMessage(String message) => switch (message) {
    '@session-end' || 'end of session' => 'Fine della sessione',
    '@recovered' || 'recovered local changes' => 'Modifiche locali recuperate',
    '@after-crash' => 'Dopo un crash del server',
    _ => null,
  };
  const _It();
  @override
  Lang get lang => Lang.it;

  @override
  String get yes => 'sì';
  @override
  String get no => 'no';
  @override
  String sizeBytes(int b) => _size(b, 'B');

  @override
  String get cliUsage => '''
Uso: minesync <comando> [opzioni]

Comandi:
  login <indirizzo-hub>      collega questo PC a un hub (es. http://192.0.2.10:8084)
  spaces                     elenca i server dell'hub
  link <server> <cartella>   collega un server a una cartella locale
  status [server]            stato dell'hub e della copia locale
  pull [server] [--discard-local]
                             scarica l'ultima versione dall'hub
  push [server] [-m messaggio]
                             carica la copia locale come nuova versione
  verify [server]            rilegge tutti i file e li confronta con l'ultima sincronizzazione
  play [server] [--discard-local] [--accept-eula] [--java PERCORSO] [--xmx MiB]
                             ospita il server: scarica, avvia, salva sull'hub, carica alla fine
''';
  @override
  String cliUnknownCommand(String c) => 'comando sconosciuto: $c';
  @override
  String get cliNoHub => 'nessun hub configurato: usa "minesync login <indirizzo>"';
  @override
  String cliConnected(String hub, String name, bool admin) =>
      'connesso a $hub come $name${admin ? ' (admin)' : ''}';
  @override
  String get cliNoSpaces => 'nessun server sull\'hub';
  @override
  String get cliNotLinked => 'nessun server collegato: usa "minesync link <server> <cartella>"';
  @override
  String cliLinked(String space, String folder) => '$space collegato a $folder';
  @override
  String get cliLockFree => 'libero';
  @override
  String cliLockHeld(String who, bool stale) =>
      stale ? 'bloccato da $who (non risponde più)' : 'in gioco: $who';
  @override
  String cliHead(int n, String author) => 'versione #$n di $author';
  @override
  String get cliEmptySpace => 'ancora nessuna versione';
  @override
  String cliLocalBase(int? n) =>
      n == null ? 'copia locale: mai sincronizzata' : 'copia locale: versione #$n';
  @override
  String cliPulled(int n, int written, int deleted) =>
      'ora alla versione #$n ($written file scritti, $deleted rimossi)';
  @override
  String cliBackup(String dir) => 'modifiche locali copiate in $dir';
  @override
  String get cliNothingToPush => 'niente da caricare: la copia locale è uguale all\'hub';
  @override
  String cliPushed(int n, int uploaded) => 'caricata la versione #$n ($uploaded blocchi inviati)';
  @override
  String cliKept(int count, String first) =>
      '$count file non leggibili (es. $first): resta la versione dell\'hub';
  @override
  String cliVerifyOk(int files) =>
      'verifica completata: $files file identici all\'ultima sincronizzazione';
  @override
  String cliVerifyDiff(int changed, int missing, int extra) =>
      'differenze dall\'ultima sincronizzazione: $changed modificati, $missing mancanti, $extra nuovi';
  @override
  String get cliUnreachable =>
      'hub non raggiungibile: controlla di essere connesso alla rete ZeroTier';
  @override
  String cliError(String message) => 'errore: $message';
  @override
  String cliProgress(String phase, int done, int total) {
    final what = switch (phase) {
      'scan' => 'scansione',
      'download' => 'scaricamento',
      'upload' => 'caricamento',
      'commit' => 'conferma',
      _ => phase,
    };
    return total > 0 ? '$what ${_size(done, 'B')} di ${_size(total, 'B')}' : what;
  }

  @override
  String get playNoLaunch => 'nessuno script o jar di avvio in questa cartella';
  @override
  String get playEulaNeeded =>
      'il server richiede di accettare la EULA di Minecraft (https://aka.ms/MinecraftEULA): '
      'rilancia con --accept-eula se la accetti';
  @override
  String playJavaMissing(int required) =>
      'nessun Java $required trovato: installalo (es. Eclipse Temurin) o indica --java';
  @override
  String playStarting(String label, String? java) =>
      'avvio $label${java == null ? '' : ' con $java'}';
  @override
  String playState(String state) => switch (state) {
    'syncing' => 'sincronizzazione con l\'hub…',
    'starting' => 'avvio del server…',
    'running' => 'server avviato: scrivi i comandi qui, "stop" per chiudere',
    'saving' => 'salvataggio…',
    'stopping' => 'arresto del server…',
    'finalPush' => 'caricamento dello stato finale sull\'hub…',
    'ended' => 'sessione terminata, stato salvato sull\'hub',
    'failed' => 'sessione terminata con un errore',
    _ => state,
  };
  @override
  String playSaved(int n) => 'salvato sull\'hub (versione #$n)';
  @override
  String playWarning(String code) => switch (code) {
    'saveNotConfirmed' => 'salvataggio non confermato dal server: ciclo saltato',
    'uploadFailed' => 'caricamento non riuscito: nuovo tentativo al prossimo salvataggio',
    'finalPushFailed' =>
      'caricamento finale non riuscito: il mondo resta su questo PC e verrà caricato la prossima '
          'volta',
    'unreadableKept' => 'alcuni file non sono leggibili: sull\'hub resta la versione precedente',
    'autostop' => 'nessun giocatore da tempo: arresto del server',
    _ => 'avviso: $code',
  };
  @override
  String playAlert(String kind) => switch (kind) {
    'lockLost' =>
      'ATTENZIONE: controllo del server perso. Server arrestato: il mondo resta solo su questo PC',
    'spaceGone' => 'ATTENZIONE: questo server è stato eliminato dall\'hub. Server arrestato',
    'hubDiskFull' => 'ATTENZIONE: lo spazio dell\'hub è esaurito',
    _ => 'ATTENZIONE: $kind',
  };
  @override
  String playCrashed(int? code, bool restarting) =>
      'il server si è chiuso in modo imprevisto (codice ${code ?? '?'})${restarting ? ': riavvio in corso' : ''}';
  @override
  String get playGuardMissing => 'manca minesync-guard accanto a minesync: reinstalla';

  @override
  String errDirtyLocal({required bool diverged, required int changed, required int removed}) =>
      diverged
      ? 'modifiche locali non ancora caricate ($changed modificate, $removed rimosse) e nel '
            'frattempo sull\'hub è arrivata un\'altra versione: usa "pull --discard-local" per prendere '
            'la versione dell\'hub (le modifiche locali vengono copiate in un backup)'
      : 'modifiche locali non ancora caricate ($changed modificate, $removed rimosse): caricale con '
            '"push"';
  @override
  String get errStaleBase =>
      'la copia locale non parte dall\'ultima versione dell\'hub: fai prima "pull"';
  @override
  String errMassDelete(int removed) =>
      'il caricamento cancellerebbe $removed file dall\'hub: rifiutato per sicurezza';
  @override
  String get errEmptyRemote => 'l\'hub è vuoto: carica la copia locale con "push"';
  @override
  String get errLockLost => 'controllo del server perso: un altro PC ne ha preso il controllo';
  @override
  String errLocked(String who) => '$who sta giocando su questo server';
  @override
  String get errSpaceGone => 'questo server è stato eliminato dall\'hub';
  @override
  String get errBadManifest => 'l\'hub ha mandato dati non validi: nessun file è stato toccato';
  @override
  String get errCorruptDownload => 'un file scaricato è danneggiato: riprova';
  @override
  String get errBlobRejected =>
      'l\'hub ha rifiutato un file cambiato durante il caricamento: riprova';
  @override
  String get errLocalDiskFull => 'spazio insufficiente su questo PC';
  @override
  String get errHubDiskFull => 'spazio esaurito sull\'hub: avvisa l\'amministratore';
  @override
  String errDirSymlink(String path) =>
      '$path è un collegamento a una cartella: sostituiscilo con la cartella vera';
  @override
  String get errStalled => 'il trasferimento si è fermato: controlla la connessione e riprova';
  @override
  String get errUnauthenticated =>
      'dispositivo non riconosciuto dall\'hub: connettiti alla rete ZeroTier del gruppo';
  @override
  String get errForbidden => 'operazione riservata agli amministratori';
  @override
  String get errOutboxNoSpace =>
      'spazio insufficiente su questo PC per preparare il salvataggio: caricamento diretto';
  @override
  String get errSnapshotStale => 'i file sono cambiati durante la preparazione: nuovo tentativo';
  @override
  String get errCancelled => 'annullato';
}

final class _En implements Strings {
  @override
  String? autoMessage(String message) => switch (message) {
    '@session-end' || 'end of session' => 'End of session',
    '@recovered' || 'recovered local changes' => 'Recovered local changes',
    '@after-crash' => 'After a server crash',
    _ => null,
  };
  const _En();
  @override
  Lang get lang => Lang.en;

  @override
  String get yes => 'yes';
  @override
  String get no => 'no';
  @override
  String sizeBytes(int b) => _size(b, 'B');

  @override
  String get cliUsage => '''
Usage: minesync <command> [options]

Commands:
  login <hub-address>        connect this PC to a hub (e.g. http://192.0.2.10:8084)
  spaces                     list the hub's servers
  link <server> <folder>     link a server to a local folder
  status [server]            hub and local copy status
  pull [server] [--discard-local]
                             download the latest version from the hub
  push [server] [-m message]
                             upload the local copy as a new version
  verify [server]            re-read every file and compare with the last sync
  play [server] [--discard-local] [--accept-eula] [--java PATH] [--xmx MiB]
                             host the server: download, start, save to the hub, upload at the end
''';
  @override
  String cliUnknownCommand(String c) => 'unknown command: $c';
  @override
  String get cliNoHub => 'no hub configured: use "minesync login <address>"';
  @override
  String cliConnected(String hub, String name, bool admin) =>
      'connected to $hub as $name${admin ? ' (admin)' : ''}';
  @override
  String get cliNoSpaces => 'no servers on the hub';
  @override
  String get cliNotLinked => 'no linked server: use "minesync link <server> <folder>"';
  @override
  String cliLinked(String space, String folder) => '$space linked to $folder';
  @override
  String get cliLockFree => 'free';
  @override
  String cliLockHeld(String who, bool stale) =>
      stale ? 'held by $who (not responding)' : 'in game: $who';
  @override
  String cliHead(int n, String author) => 'version #$n by $author';
  @override
  String get cliEmptySpace => 'no versions yet';
  @override
  String cliLocalBase(int? n) => n == null ? 'local copy: never synced' : 'local copy: version #$n';
  @override
  String cliPulled(int n, int written, int deleted) =>
      'now at version #$n ($written files written, $deleted removed)';
  @override
  String cliBackup(String dir) => 'local changes copied to $dir';
  @override
  String get cliNothingToPush => 'nothing to upload: the local copy matches the hub';
  @override
  String cliPushed(int n, int uploaded) => 'uploaded version #$n ($uploaded blocks sent)';
  @override
  String cliKept(int count, String first) =>
      '${count == 1 ? '1 file' : '$count files'} could not be read (e.g. $first): the hub version stays';
  @override
  String cliVerifyOk(int files) => 'check passed: $files files match the last sync';
  @override
  String cliVerifyDiff(int changed, int missing, int extra) =>
      'differences from the last sync: $changed changed, $missing missing, $extra new';
  @override
  String get cliUnreachable => 'hub not reachable: check the connection to the ZeroTier network';
  @override
  String cliError(String message) => 'error: $message';
  @override
  String cliProgress(String phase, int done, int total) =>
      total > 0 ? '$phase ${_size(done, 'B')} of ${_size(total, 'B')}' : phase;

  @override
  String get playNoLaunch => 'no start script or jar in this folder';
  @override
  String get playEulaNeeded =>
      'the server requires accepting the Minecraft EULA (https://aka.ms/MinecraftEULA): '
      'run again with --accept-eula if you accept it';
  @override
  String playJavaMissing(int required) =>
      'no Java $required found: install it (e.g. Eclipse Temurin) or pass --java';
  @override
  String playStarting(String label, String? java) =>
      'starting $label${java == null ? '' : ' with $java'}';
  @override
  String playState(String state) => switch (state) {
    'syncing' => 'syncing with the hub…',
    'starting' => 'starting the server…',
    'running' => 'server running: type commands here, "stop" to close',
    'saving' => 'saving…',
    'stopping' => 'stopping the server…',
    'finalPush' => 'uploading the final state to the hub…',
    'ended' => 'session ended, state saved on the hub',
    'failed' => 'session ended with an error',
    _ => state,
  };
  @override
  String playSaved(int n) => 'saved to the hub (version #$n)';
  @override
  String playWarning(String code) => switch (code) {
    'saveNotConfirmed' => 'save not confirmed by the server: cycle skipped',
    'uploadFailed' => 'upload failed: retrying at the next save',
    'finalPushFailed' =>
      'final upload failed: the world stays on this PC and will be uploaded next time',
    'unreadableKept' => 'some files cannot be read: the hub keeps their previous version',
    'autostop' => 'no players for a while: stopping the server',
    _ => 'warning: $code',
  };
  @override
  String playAlert(String kind) => switch (kind) {
    'lockLost' =>
      'WARNING: control of the server lost. Server stopped: the world stays only on this PC',
    'spaceGone' => 'WARNING: this server was deleted from the hub. Server stopped',
    'hubDiskFull' => 'WARNING: the hub is out of space',
    _ => 'WARNING: $kind',
  };
  @override
  String playCrashed(int? code, bool restarting) =>
      'the server closed unexpectedly (code ${code ?? '?'})${restarting ? ': restarting' : ''}';
  @override
  String get playGuardMissing => 'minesync-guard is missing next to minesync: reinstall';

  @override
  String errDirtyLocal({required bool diverged, required int changed, required int removed}) =>
      diverged
      ? 'local changes not uploaded yet ($changed changed, $removed removed) and another version '
            'reached the hub meanwhile: use "pull --discard-local" to take the hub version (local '
            'changes are copied to a backup)'
      : 'local changes not uploaded yet ($changed changed, $removed removed): upload them with '
            '"push"';
  @override
  String get errStaleBase => 'the local copy is not based on the hub\'s latest version: pull first';
  @override
  String errMassDelete(int removed) =>
      'the upload would delete $removed files from the hub: refused for safety';
  @override
  String get errEmptyRemote => 'the hub is empty: upload the local copy with "push"';
  @override
  String get errLockLost => 'control of the server lost: another PC took over';
  @override
  String errLocked(String who) => '$who is playing on this server';
  @override
  String get errSpaceGone => 'this server was deleted from the hub';
  @override
  String get errBadManifest => 'the hub sent invalid data: no file was touched';
  @override
  String get errCorruptDownload => 'a downloaded file is damaged: try again';
  @override
  String get errBlobRejected => 'the hub refused a file that changed during the upload: try again';
  @override
  String get errLocalDiskFull => 'not enough space on this PC';
  @override
  String get errHubDiskFull => 'the hub is out of space: contact the administrator';
  @override
  String errDirSymlink(String path) =>
      '$path is a link to a folder: replace it with the real folder';
  @override
  String get errStalled => 'the transfer stalled: check the connection and try again';
  @override
  String get errUnauthenticated =>
      'device not recognised by the hub: join the group\'s ZeroTier network';
  @override
  String get errForbidden => 'only administrators can do this';
  @override
  String get errOutboxNoSpace =>
      'not enough space on this PC to prepare the save: uploading it directly';
  @override
  String get errSnapshotStale => 'the files changed during preparation: retrying';
  @override
  String get errCancelled => 'cancelled';
}

String _size(int b, String unit) {
  const units = ['', 'Ki', 'Mi', 'Gi', 'Ti'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return i == 0 ? '$b $unit' : '${v.toStringAsFixed(v < 10 ? 1 : 0)} ${units[i]}$unit';
}
