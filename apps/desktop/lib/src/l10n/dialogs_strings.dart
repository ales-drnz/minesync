// Testi dei dialoghi critici: conflitto con le modifiche locali, forzatura
// del lock, chiusura durante una sessione, aggiornamento pronto, EULA, Java
// mancante, crash del server, sessione terminata, errori di avvio.
import 'package:ms_core/ms_core.dart';
import 'package:ms_l10n/ms_l10n.dart';
import 'package:ms_protocol/ms_protocol.dart';

abstract final class DialogsStrings {
  static DialogsStrings of(Lang l) => switch (l) {
    Lang.it => const _It(),
    Lang.en => const _En(),
  };

  String get cancel;
  String get close;
  String get retry;

  // conflitto
  String get conflictTitle;
  String conflictText(String server);
  String get changedFiles;
  String get removedFiles;
  String get useHub;
  String get keepMine;
  String get conflict2Title;
  String get conflict2Step;
  String get conflict2Text;
  String get uploading;
  String uploadingValue(int changed, int removed);
  String get replaced;
  String replacedValue(String? lastAuthor);
  String get goBack;
  String get goBackValue;
  String get conflict2Hint;
  String get noGoBack;
  String get confirmKeepMine;

  // forzatura del lock
  String get forceStep1;
  String get forceStep1Stale;
  String forceTitle(String server);
  String forceText(String who, int friends);
  String forceTextStale(String who);
  String get lastSafe;

  /// [ago] null: il salvataggio è di un altro giorno, [time] lo dice già.
  String lastSafeValue(String? ago, String time);
  String get risk;
  String riskValue(String who);
  String get forceHint;
  String get continueLabel;
  String get forceStep2;
  String get forceTitle2;
  String get forceText2;
  String disconnected(int friends);
  String get mayLose;
  String get mayLoseValue;
  String get lastHubSave;
  String get then;
  String thenValue(String server);
  String get noWait;
  String get yesForce;

  // chiusura durante una sessione
  String get quitTitle;
  String quitText(String server);
  String get quitStepPlayers;
  String get quitStepSave;
  String get quitStepUpload;
  String get quitStepRelease;
  String get quitProgress;
  String get quitHint;
  String get quitBackground;

  // aggiornamento
  String updateTitle(String version);
  String get updateText;
  String get updateNotes;
  String updateHint(String version);
  String get notNow;
  String get restartNow;

  // EULA
  String get eulaTitle;
  String eulaText(String server);
  String get eulaRead;
  String get eulaHint;
  String get eulaAccept;

  // Java mancante e altri errori di avvio
  String javaTitle(int major);
  String javaText(String server, int major);
  String get nothingTouched;
  String get nothingTouchedText;
  String javaHint(int major);
  String get openSettings;
  String startErrorTitle(String server);
  String get noLaunchText;
  String get eulaDeclinedText;
  String get guardMissingText;

  // crash
  String get crashTitle;
  String crashText(String server, String time, int? saved, bool restarting);
  String get crashRestarting;
  String attempt(int a, int max);
  String get crashOom;
  String crashConfig(String server);
  String get crashFriends;
  String get console;
  String get dontRestart;

  // sessione terminata
  String get endedTitle;
  String endedText(String server);
  String get endedDuration;
  String get endedPlayers;
  String get endedLastSave;
  String get endedNoSave;
  String get playAgain;

  /// Spiegazione per l'utente di un errore del sync, dell'hub o dell'avvio.
  String describeError(Strings s, Object e);
}

String _describe(Strings s, Object e, String Function(Object) other) => switch (e) {
  SyncException(kind: SyncErrorKind.dirtyLocal) => s.errDirtyLocal(
    diverged: e.diverged,
    changed: e.changed.length,
    removed: e.removed.length,
  ),
  SyncException(kind: SyncErrorKind.staleBase) => s.errStaleBase,
  SyncException(kind: SyncErrorKind.massDelete) => s.errMassDelete(e.removed.length),
  SyncException(kind: SyncErrorKind.emptyRemote) => s.errEmptyRemote,
  SyncException(kind: SyncErrorKind.lockLost) => s.errLockLost,
  SyncException(kind: SyncErrorKind.spaceGone) => s.errSpaceGone,
  SyncException(kind: SyncErrorKind.badManifest) => s.errBadManifest,
  SyncException(kind: SyncErrorKind.corruptDownload) => s.errCorruptDownload,
  SyncException(kind: SyncErrorKind.blobRejected) => s.errBlobRejected,
  SyncException(kind: SyncErrorKind.localDiskFull) => s.errLocalDiskFull,
  SyncException(kind: SyncErrorKind.hubDiskFull) => s.errHubDiskFull,
  SyncException(kind: SyncErrorKind.dirSymlink) => s.errDirSymlink(e.path ?? ''),
  SyncException(kind: SyncErrorKind.outboxNoSpace) => s.errOutboxNoSpace,
  SyncException(kind: SyncErrorKind.snapshotStale) => s.errSnapshotStale,
  SyncException(kind: SyncErrorKind.cancelled) => s.errCancelled,
  ApiError(code: ErrorCode.unauthenticated) => s.errUnauthenticated,
  ApiError(code: ErrorCode.forbidden) => s.errForbidden,
  ApiError(code: ErrorCode.locked) => s.errLocked(
    (e.details['lock'] as Map<String, Object?>?)?['name'] as String? ??
        e.details['owner'] as String? ??
        '?',
  ),
  ApiError(code: ErrorCode.spaceGone || ErrorCode.notFound) => s.errSpaceGone,
  ApiError(code: ErrorCode.diskFull) => s.errHubDiskFull,
  ApiError() => e.message,
  HubUnreachable() => s.cliUnreachable,
  TransferStalled() => s.errStalled,
  _ => other(e),
};

final class _It implements DialogsStrings {
  const _It();
  @override
  String get cancel => 'Annulla';
  @override
  String get close => 'Chiudi';
  @override
  String get retry => 'Riprova';
  @override
  String get conflictTitle => 'Modifiche non salvate su questo PC';
  @override
  String conflictText(String server) =>
      '$server ha modifiche su questo PC che non sono mai arrivate sull\'hub. Nessun file è andato perso.';
  @override
  String get changedFiles => 'File cambiati';
  @override
  String get removedFiles => 'File eliminati';
  @override
  String get useHub => 'Usa la versione dell\'hub';
  @override
  String get keepMine => 'Carica le modifiche locali come nuova versione…';
  @override
  String get conflict2Title => 'Sostituire la versione dell\'hub per tutti?';
  @override
  String get conflict2Step => 'Conferma 2 di 2';
  @override
  String get conflict2Text =>
      'Le modifiche locali diventano la versione scaricata da chiunque giochi da questo momento.';
  @override
  String get uploading => 'Da caricare';
  @override
  String uploadingValue(int changed, int removed) => '$changed file cambiati, $removed eliminati';
  @override
  String get replaced => 'Da sostituire';
  @override
  String replacedValue(String? lastAuthor) =>
      'la versione attuale dell\'hub${lastAuthor == null ? '' : ' ($lastAuthor)'}';
  @override
  String get goBack => 'Annullamento';
  @override
  String get goBackValue =>
      'la versione sostituita resta nella cronologia e un admin può ripristinarla';
  @override
  String get conflict2Hint =>
      'I progressi di chi ha giocato dopo di te restano esclusi finché un admin non li ripristina. '
      'Nel dubbio, torna indietro e scegli la versione dell\'hub.';
  @override
  String get noGoBack => 'Torna indietro';
  @override
  String get confirmKeepMine => 'Carica le modifiche locali';
  @override
  String get forceStep1 => 'Conferma 1 di 2, solo admin';
  @override
  String get forceStep1Stale => 'Conferma 1 di 2';
  @override
  String forceTitle(String server) => 'Forzare $server?';
  @override
  String forceText(String who, int friends) =>
      '$who sta giocando${friends > 0 ? ' con $friends amici' : ''}. Forzando, la sua sessione '
      'si ferma e diventi tu l\'host.';
  @override
  String forceTextStale(String who) =>
      'Il PC di $who non risponde da tempo: probabilmente è spento o senza rete. Forzando, '
      'diventi tu l\'host.';
  @override
  String get lastSafe => 'Al sicuro sull\'hub';
  @override
  String lastSafeValue(String? ago, String time) =>
      'tutto fino all\'ultimo salvataggio, delle $time${ago == null ? '' : ' ($ago)'}';
  @override
  String get risk => 'Rischio';
  @override
  String riskValue(String who) => '$who perde al massimo gli ultimi ~5 min non salvati';
  @override
  String get forceHint => 'Contatta prima chi sta giocando. Forza solo se il suo PC è bloccato.';
  @override
  String get continueLabel => 'Continua…';
  @override
  String get forceStep2 => 'Conferma 2 di 2';
  @override
  String get forceTitle2 => 'Conferma definitiva';
  @override
  String get forceText2 => 'L\'operazione non si può annullare.';
  @override
  String disconnected(int friends) => friends > 0
      ? 'viene disconnesso subito, con i suoi $friends amici'
      : 'viene disconnesso subito';
  @override
  String get mayLose => 'Può perdere';
  @override
  String get mayLoseValue => 'al massimo gli ultimi ~5 min non salvati';
  @override
  String get lastHubSave => 'Ultimo salvataggio sull\'hub';
  @override
  String get then => 'Poi';
  @override
  String thenValue(String server) => '$server riparte sul tuo PC da quel salvataggio';
  @override
  String get noWait => 'Non forzare';
  @override
  String get yesForce => 'Forza e gioca';
  @override
  String get quitTitle => 'Arresto e salvataggio in corso…';
  @override
  String quitText(String server) =>
      'MineSync è stato chiuso mentre $server era acceso. Arresto regolare in corso, per '
      'caricare il mondo sull\'hub.';
  @override
  String get quitStepPlayers => 'Avviso ai giocatori';
  @override
  String get quitStepSave => 'Salvataggio del mondo';
  @override
  String get quitStepUpload => 'Caricamento sull\'hub';
  @override
  String get quitStepRelease => 'Rilascio del server';
  @override
  String get quitProgress => 'Caricamento finale';
  @override
  String get quitHint =>
      'Non spegnere il PC. Di solito serve meno di un minuto. MineSync si chiude al termine.';
  @override
  String get quitBackground => 'Continua in background';
  @override
  String updateTitle(String version) => 'MineSync $version è pronto';
  @override
  String get updateText =>
      'Aggiornamento scaricato, firma verificata. Il riavvio richiede pochi secondi.';
  @override
  String get updateNotes => 'Novità';
  @override
  String updateHint(String version) =>
      'Prima di una partita, scegli Non ora: l\'aggiornamento resta disponibile in alto, '
      '«Riavvia per $version». Il riavvio non avviene mai mentre ospiti un server.';
  @override
  String get notNow => 'Non ora';
  @override
  String get restartNow => 'Riavvia ora';
  @override
  String get eulaTitle => 'Accetta l\'EULA di Minecraft';
  @override
  String eulaText(String server) =>
      'Per ospitare un server, Minecraft richiede di accettare i termini di Mojang (EULA). '
      'L\'accettazione vale una sola volta per $server.';
  @override
  String get eulaRead => 'Leggi l\'EULA di Minecraft:';
  @override
  String get eulaHint =>
      'L\'accettazione scrive eula=true nel file eula.txt della cartella del server. Senza, il '
      'server si ferma subito all\'avvio.';
  @override
  String get eulaAccept => 'Accetto e avvio';
  @override
  String javaTitle(int major) => 'Manca Java $major';
  @override
  String javaText(String server, int major) =>
      '$server richiede Java $major. Su questo PC non c\'è una versione adatta.';
  @override
  String get nothingTouched => 'Nessuna modifica';
  @override
  String get nothingTouchedText =>
      'La tua copia e il mondo sull\'hub sono invariati. Il server è di nuovo libero.';
  @override
  String javaHint(int major) =>
      'Installa Java $major (per esempio Temurin, da adoptium.net) e premi Riprova, oppure '
      'sceglilo in Impostazioni › Per server.';
  @override
  String get openSettings => 'Impostazioni';
  @override
  String startErrorTitle(String server) => 'Impossibile avviare $server';
  @override
  String get noLaunchText =>
      'Nella cartella non c\'è un modo per avviare il server: nessuno script di avvio e nessun '
      'jar.';
  @override
  String get eulaDeclinedText => 'Senza l\'EULA accettata il server non può partire.';
  @override
  String get guardMissingText =>
      'Manca un componente di MineSync (minesync-guard). Reinstalla l\'app.';
  @override
  String get crashTitle => 'Chiusura imprevista del server';
  @override
  String crashText(String server, String time, int? saved, bool restarting) =>
      '$server è andato in crash alle $time.'
      '${saved == null ? '' : ' Lo stato è salvato sull\'hub.'}'
      '${restarting ? ' Riavvio in corso.' : ''}';
  @override
  String get crashRestarting => 'Riavvio';
  @override
  String attempt(int a, int max) => 'tentativo $a di $max';
  @override
  String get crashOom =>
      'Probabile memoria esaurita. Se ricapita, aumenta la memoria in Impostazioni › Per server.';
  @override
  String crashConfig(String server) =>
      'Chiusure ripetute: probabile problema di configurazione di $server. Il riavvio automatico '
      'è sospeso. Controlla la console per i dettagli.';
  @override
  String get crashFriends => 'Gli amici possono rientrare a breve.';
  @override
  String get console => 'Console';
  @override
  String get dontRestart => 'Non riavviare';
  @override
  String get endedTitle => 'Sessione terminata';
  @override
  String endedText(String server) =>
      'Mondo salvato sull\'hub. $server è di nuovo libero per tutti.';
  @override
  String get endedDuration => 'Durata';
  @override
  String get endedPlayers => 'Giocatori';
  @override
  String get endedLastSave => 'Ultimo salvataggio';
  @override
  String get endedNoSave => 'nessuna modifica da caricare';
  @override
  String get playAgain => 'Gioca ancora';
  @override
  String describeError(Strings s, Object e) => _describe(s, e, (e) => '$e');
}

final class _En implements DialogsStrings {
  const _En();
  @override
  String get cancel => 'Cancel';
  @override
  String get close => 'Close';
  @override
  String get retry => 'Try again';
  @override
  String get conflictTitle => 'Unsaved changes on this PC';
  @override
  String conflictText(String server) =>
      '$server has changes on this PC that never reached the hub. No files were lost.';
  @override
  String get changedFiles => 'Changed files';
  @override
  String get removedFiles => 'Deleted files';
  @override
  String get useHub => 'Use the hub version';
  @override
  String get keepMine => 'Upload local changes as a new version…';
  @override
  String get conflict2Title => 'Replace the hub version for everyone?';
  @override
  String get conflict2Step => 'Confirm 2 of 2';
  @override
  String get conflict2Text =>
      'The local changes become the version downloaded by everyone who plays from now on.';
  @override
  String get uploading => 'To upload';
  @override
  String uploadingValue(int changed, int removed) => '$changed changed files, $removed deleted';
  @override
  String get replaced => 'To replace';
  @override
  String replacedValue(String? lastAuthor) =>
      'the current hub version${lastAuthor == null ? '' : ' ($lastAuthor)'}';
  @override
  String get goBack => 'Undo';
  @override
  String get goBackValue => 'the replaced version stays in the history and an admin can restore it';
  @override
  String get conflict2Hint =>
      'Progress made by anyone who played after you stays out until an admin restores it. When in '
      'doubt, go back and choose the hub version.';
  @override
  String get noGoBack => 'Go back';
  @override
  String get confirmKeepMine => 'Upload local changes';
  @override
  String get forceStep1 => 'Confirmation 1 of 2, admins only';
  @override
  String get forceStep1Stale => 'Confirmation 1 of 2';
  @override
  String forceTitle(String server) => 'Force $server?';
  @override
  String forceText(String who, int friends) =>
      '$who is playing${friends > 0 ? ' with $friends friends' : ''}. Forcing stops their '
      'session and makes you the host.';
  @override
  String forceTextStale(String who) =>
      '$who\'s PC has not been responding for a while: it is probably off or offline. Forcing '
      'makes you the host.';
  @override
  String get lastSafe => 'Safe on the hub';
  @override
  String lastSafeValue(String? ago, String time) =>
      'everything up to the last save, at $time${ago == null ? '' : ' ($ago)'}';
  @override
  String get risk => 'Risk';
  @override
  String riskValue(String who) => '$who loses at most the last ~5 unsaved minutes';
  @override
  String get forceHint => 'Contact the current player first. Force only if their PC is stuck.';
  @override
  String get continueLabel => 'Continue…';
  @override
  String get forceStep2 => 'Confirm 2 of 2';
  @override
  String get forceTitle2 => 'Final confirmation';
  @override
  String get forceText2 => 'This cannot be undone.';
  @override
  String disconnected(int friends) => friends > 0
      ? 'is disconnected right away, with their $friends friends'
      : 'is disconnected right away';
  @override
  String get mayLose => 'May lose';
  @override
  String get mayLoseValue => 'at most the last ~5 unsaved minutes';
  @override
  String get lastHubSave => 'Last save on the hub';
  @override
  String get then => 'Then';
  @override
  String thenValue(String server) => '$server restarts on your PC from that save';
  @override
  String get noWait => 'Don\'t force';
  @override
  String get yesForce => 'Force and play';
  @override
  String get quitTitle => 'Stopping and saving…';
  @override
  String quitText(String server) =>
      'MineSync was closed while $server was running. Shutting down cleanly so the world reaches '
      'the hub.';
  @override
  String get quitStepPlayers => 'Notifying players';
  @override
  String get quitStepSave => 'Saving the world';
  @override
  String get quitStepUpload => 'Uploading to the hub';
  @override
  String get quitStepRelease => 'Releasing the server';
  @override
  String get quitProgress => 'Final upload';
  @override
  String get quitHint =>
      'Keep the PC on. This usually takes less than a minute. MineSync closes when done.';
  @override
  String get quitBackground => 'Continue in the background';
  @override
  String updateTitle(String version) => 'MineSync $version is ready';
  @override
  String get updateText => 'Update downloaded, signature verified. Restarting takes a few seconds.';
  @override
  String get updateNotes => 'What\'s new';
  @override
  String updateHint(String version) =>
      'Before playing, choose Not now: the update stays available at the top, “Restart for '
      '$version”. MineSync never restarts while you host a server.';
  @override
  String get notNow => 'Not now';
  @override
  String get restartNow => 'Restart now';
  @override
  String get eulaTitle => 'Accept the Minecraft EULA';
  @override
  String eulaText(String server) =>
      'To host a server, Minecraft requires accepting Mojang\'s terms (EULA). This is needed only '
      'once for $server.';
  @override
  String get eulaRead => 'Read the Minecraft EULA:';
  @override
  String get eulaHint =>
      'Accepting writes eula=true to the eula.txt file in the server folder. Without it, the '
      'server stops right after starting.';
  @override
  String get eulaAccept => 'Accept and start';
  @override
  String javaTitle(int major) => 'Java $major is missing';
  @override
  String javaText(String server, int major) =>
      '$server requires Java $major. No suitable version found on this PC.';
  @override
  String get nothingTouched => 'Nothing changed';
  @override
  String get nothingTouchedText =>
      'Your copy and the world on the hub are unchanged. The server is free again.';
  @override
  String javaHint(int major) =>
      'Install Java $major (for example Temurin, from adoptium.net) and press Try again, or pick '
      'it in Settings › Servers.';
  @override
  String get openSettings => 'Settings';
  @override
  String startErrorTitle(String server) => 'Unable to start $server';
  @override
  String get noLaunchText =>
      'The folder has no way to start the server: no launch script and no jar.';
  @override
  String get eulaDeclinedText => 'The server can\'t start without accepting the EULA.';
  @override
  String get guardMissingText =>
      'A MineSync component is missing (minesync-guard). Reinstall the app.';
  @override
  String get crashTitle => 'Server closed unexpectedly';
  @override
  String crashText(String server, String time, int? saved, bool restarting) =>
      '$server crashed at $time.'
      '${saved == null ? '' : ' The state is saved on the hub.'}'
      '${restarting ? ' Restarting.' : ''}';
  @override
  String get crashRestarting => 'Restarting';
  @override
  String attempt(int a, int max) => 'attempt $a of $max';
  @override
  String get crashOom =>
      'Likely out of memory. If it happens again, raise the memory in Settings › Servers.';
  @override
  String crashConfig(String server) =>
      'Repeated crashes: likely a configuration problem with $server. Automatic restart is '
      'paused. Check the console for details.';
  @override
  String get crashFriends => 'Friends can rejoin shortly.';
  @override
  String get console => 'Console';
  @override
  String get dontRestart => 'Don\'t restart';
  @override
  String get endedTitle => 'Session ended';
  @override
  String endedText(String server) => 'World saved to the hub. $server is free for everyone again.';
  @override
  String get endedDuration => 'Duration';
  @override
  String get endedPlayers => 'Players';
  @override
  String get endedLastSave => 'Last save';
  @override
  String get endedNoSave => 'no changes to upload';
  @override
  String get playAgain => 'Play again';
  @override
  String describeError(Strings s, Object e) => _describe(s, e, (e) => '$e');
}
