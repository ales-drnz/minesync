// Testi del modpack: scheda Mod del server (elenco, aggiornamenti, ricerca
// su Modrinth, cambio di versione o loader, modifiche da applicare), i suoi
// dialoghi e il pacchetto per i giocatori.
import 'package:ms_l10n/ms_l10n.dart';

abstract final class ModpackStrings {
  const ModpackStrings();

  static ModpackStrings of(Lang l) => switch (l) {
    Lang.it => const _It(),
    Lang.en => const _En(),
  };

  // --- scheda e intestazione
  String get tab;
  String get viewLabel;
  String get viewServer;
  String get viewClient;
  String get retarget;
  String get addJar;
  String get noFolder;
  String get getServer;
  String get manualKept;
  String get loading;
  String get recognizing;
  String get recognizingText;
  String get noVersion;
  String get noVersionText;
  String get loadError;
  String get retry;
  String lockedTitle(String who);
  String get lockedText;
  String get notifyFree;
  String get notifyFreeOn;
  String get modrinthDown;
  String get modrinthDownText;
  String modrinthNext(String at, int seconds);
  String watchReady(String mc);
  String watchReadyNotice(String mc);
  String get vanillaTitle;
  String get vanillaText;

  // --- aggiornamenti
  String get updates;
  String checkedAgo(String ago);
  String get checkUpdates;
  String get checking;
  String get notChecked;
  String updateAll(int n);
  String get update;
  String get inChanges;
  String get why;
  String get noUpdates;
  String fromTo(String a, String b);

  // --- installate
  String get installed;
  String installedCount(int n);
  String get filterLabel;
  String get filterAll;
  String get filterClient;
  String get filterServer;
  String get filterDisabled;
  String get findInstalled;
  String get sideClient;
  String get sideServer;
  String get sideBoth;
  String get sideServerTip;
  String get sideClientTip;
  String get chipNew;
  String get chipManual;
  String get chipDisabled;
  String available(String v);
  String requiredBy(int n);
  String get toggleLabel;
  String get removeLabel;
  String get readOnlyHint;
  String get installedFoot;
  String get noMatch;
  String get noMods;
  String get manualNote;
  String toUpdate(String v);

  // --- dettaglio
  String get detail;
  String showAll(int n);
  String get showFewer;
  String get manualText;
  String get manualAdded;
  String get openModrinth;
  String get detailNote;
  String get manualUpdate;
  String get manualUpdateValue;
  String get whereLabel;
  String get whereHint;
  String get inClientPack;
  String get notInClientPack;
  String get optionalForPlayers;
  String get pinLabel;
  String get file;
  String get size;
  String get remove;

  // --- ricerca
  String searchTitle(String loader, String mc);
  String get searchLabel;
  String get searchPlaceholder;
  String get sortLabel;
  String get sortRelevance;
  String get sortDownloads;
  String get sortUpdated;
  String onlyCompatible(String name);
  String onlyCompatibleHint(String loader, String mc);
  String hitMeta(String author, String downloads, String description);
  String downloads(int n);
  String get install;
  String get installing;
  String get chipInstalled;
  String notFor(String loader);
  String get searchEmpty;
  String get searchNone;
  String get searchDown;
  String get searchDownText;
  String get searchHint;

  // --- modifiche da applicare
  String changes(int n);
  String get changesLabel;
  String get appliesNext;
  String lockedBar(String who, String name);
  String get apply;
  String applyWhen(String who);
  String queuedText(String who);
  String get unqueue;
  String get discard;
  String get waitingModrinth;
  String get waitingModrinthText;
  String lineAdded(String name, String v);
  String lineRemoved(String name);
  String lineUpdated(String name, String a, String b);
  String lineEnabled(String name);
  String lineDisabled(String name);
  String lineChanged(String name);
  String lineTarget(String loader, String mc);
  String get lineShared;
  String get lineFirstSetup;
  String andMore(int n);
  String applyStep(String step);
  String downloading(String mod);
  String applied(int n);
  String get appliedNothing;
  String get appliedText;
  String get applyFailed;
  String applyFailedText(String reason, Object? detail);
  String get close;
  String pushMessage(int n);
  String get queuedNotice;

  // --- versione e loader
  String get retargetTitle;
  String get retargetIntro;
  String get minecraft;
  String latest(String v);
  String current(String v);
  String get releasesOnly;
  String nowOn(String v);
  String get loader;
  String loaderVersionPicked(String loader, String v, String mc);
  String get loaderChangeWarn;
  String javaOk(int major);
  String javaOkText(String mc, int major, String found);
  String javaMissing(int major);
  String javaMissingText(String mc, int major);
  String get javaHow;
  String get javaRescan;
  String get check;
  String get checkingMods;
  String checkDone(int n);
  String ready(int n, String mc);
  String blocking(int n);
  String toCheck(int n);
  String get notReady;
  String get chipToCheck;
  String blockReason(String reason, {String? other, List<String> versions = const []});
  String get manualReason;
  String readyFoot(int n, String mc, int head);
  String get watch;
  String get watchSet;
  String changeAndRemove(int n);
  String get changeTarget;
  String get cancel;
  String get noLoaderVersions;

  // --- dialoghi
  String addTitle(String name);
  String addText(String name, int deps, String loader, String mc);
  String get chosen;
  String requiredFor(String name);
  String get willAdd;
  String alreadyThere(String v);
  String get addFoot;
  String addButton(int n);
  String addBlockedTitle(String name);
  String get addBlockedText;
  String updateBlockedTitle(String name, String v);
  String get updateBlockedFoot;
  String get hideUpdate;
  String stayOn(String v);
  String get haveNow;
  String get needs;
  String get toGetIt;
  String loaderTitle(String name, String loader);
  String loaderText(String loader, String mc);
  String get loaderEyebrow;
  String keep(int n, String loader);
  String removed(int n, String names);
  String get worldLoss;
  String get backTerm;
  String backValue(int head, String loader);
  String get loaderFoot;
  String stayOnLoader(String loader);
  String switchTo(String loader);
  String cfTitle(String name);
  String get cfText;
  String cfStep1(String loader, String mc);
  String get cfStep2;
  String get cfFoot;
  String get cfOpen;
  String get cfHaveFile;
  String get cfPath;
  String get cfWrong;
  String lockedTitle2(String who, String name);
  String get lockedText2;
  String get yourChanges;
  String yourChangesValue(int n);
  String get inGame;
  String inGameValue(String who, String since, int online);
  String get whenFree;
  String whenFreeValue(int next);
  String get queueSwitch;
  String get queueSwitchHint;
  String get wait;
  String get confirmTitle;
  String confirmText(int next, String name);
  String confirmDownload(int n, String size);
  String get noDownload;
  String get forPlayers;
  String get forPlayersValue;
  String get confirmApply;
  String removeTitle(String name);
  String get removeText;
  String usedBy(int n);
  String get orphansTerm;
  String orphans(int n);
  String dependsOn(String name);
  String get alsoRemoved;
  String removeButton(String name, int n);
  String historyBack(int head);
  String get dependentsTerm;

  // --- pacchetto per i giocatori
  String forPlayersCount(int n);
  String get cpNotReady;
  String get cpNotReadyText;
  String cpOutdated(String where, int mine, int head);
  String get cpOutdatedText;
  String cpUpdateIn(String where);
  String get cpReady;
  String cpReadyText(String where, int n, String address);
  String get cpNoLaunch;
  String get cpNoLaunchText;
  String get prism;
  String get prismFound;
  String get prismRecommended;
  String get prismText;
  String get prismStep1;
  String get prismStep2;
  String prismStep3(String address);
  String get openInPrism;
  String get exportMrpack;
  String get prismMissing;
  String get prismMissingText;
  String get prismDownload;
  String get prismMissingFoot;
  String get official;
  String officialText(String loader, String mc);
  String get profileTerm;
  String profileValue(String name);
  String get folderTerm;
  String get updatesTerm;
  String get updatesValue;
  String get createProfile;
  String get closeLauncherFirst;
  String get officialMissing;
  String get officialUnsupported;
  String profileDone(String folder);
  String profileBackup(String file);
  String get contents;
  String contentsFrom(int n);
  String get cpAll;
  String get cpRequired;
  String get cpOptional;
  String get cpServerOnly;
  String requiredFoot(int n);
  String get optionalFoot;
  String serverOnlyFoot(int n);
  String get iWantIt;
  String get exportedTitle;
  String exportedText(String path);
  String get localBehind;
  String localBehindText(int mine, int head);
  String get localDownload;
  String get cpVanilla;
  String cpVanillaText(String name, String mc, String address);
  String get copyAddress;
  String get copied;
  String get missingTitle;
  String missingText(String names);
  String get openPage;
  String get cpError;
  String get cpNoPack;
  String get cpNoPackText;
  String get goServerMods;
}

String _sideIt(String s) => switch (s) {
  'client' => 'Giocatori',
  'server' => 'Server',
  _ => 'Server e giocatori',
};

final class _It extends ModpackStrings {
  const _It();

  @override
  String get tab => 'Mod';
  @override
  String get viewLabel => 'Vista della scheda Mod';
  @override
  String get viewServer => 'Mod del server';
  @override
  String get viewClient => 'Pacchetto per i giocatori';
  @override
  String get retarget => 'Cambia versione o loader…';
  @override
  String get addJar => 'Da file…';
  @override
  String get noFolder => 'Per modificare le mod scarica il server';
  @override
  String get getServer => 'Scarica il server';
  @override
  String get manualKept => 'Le mod non trovate su Modrinth restano come sono.';
  @override
  String get loading => 'Lettura delle mod della tua copia…';
  @override
  String get recognizing => 'Riconoscimento delle mod su Modrinth…';
  @override
  String get recognizingText =>
      'Prima analisi: l\'impronta di ogni file mod viene cercata su Modrinth per identificarlo.';
  @override
  String get noVersion => 'Versione del server non riconosciuta';
  @override
  String get noVersionText =>
      'Servono la versione di Minecraft e il loader: avvia il server una volta o scegli «Cambia versione o loader».';
  @override
  String get loadError => 'Impossibile leggere le mod';
  @override
  String get retry => 'Riprova';
  @override
  String lockedTitle(String who) => '$who sta giocando: le mod sono in sola lettura';
  @override
  String get lockedText =>
      'Cambiarle a server acceso interromperebbe la partita in corso. Puoi consultarle e preparare le modifiche, da applicare quando il server è libero.';
  @override
  String get notifyFree => 'Avvisami quando si libera';
  @override
  String get notifyFreeOn => 'Notifica attiva per quando si libera';
  @override
  String get modrinthDown => 'Modrinth non risponde';
  @override
  String get modrinthDownText =>
      'Le mod installate restano visibili e si possono disattivare come sempre. Ricerca e aggiornamenti tornano disponibili appena Modrinth risponde. Nuovo tentativo automatico ogni 30 s.';
  @override
  String modrinthNext(String at, int seconds) => 'Ultimo tentativo: $at, prossimo tra $seconds s';
  @override
  String watchReady(String mc) => 'Le mod sono pronte per Minecraft $mc';
  @override
  String watchReadyNotice(String mc) =>
      'Tutte le mod esistono per Minecraft $mc: il cambio è possibile.';
  @override
  String get vanillaTitle => 'Server vanilla';
  @override
  String get vanillaText =>
      'Nessun loader e nessuna mod. Per aggiungerne, scegli un loader con «Cambia versione o loader».';

  @override
  String get updates => 'Aggiornamenti';
  @override
  String checkedAgo(String ago) => 'controllato $ago';
  @override
  String get checkUpdates => 'Controlla gli aggiornamenti';
  @override
  String get checking => 'Controllo in corso…';
  @override
  String get notChecked => 'Non ancora controllato.';
  @override
  String updateAll(int n) => 'Aggiorna tutte ($n)';
  @override
  String get update => 'Aggiorna';
  @override
  String get inChanges => 'nelle modifiche';
  @override
  String get why => 'Motivo';
  @override
  String get noUpdates => 'Tutte le mod sono all\'ultima versione.';
  @override
  String fromTo(String a, String b) => '$a › $b';

  @override
  String get installed => 'Installate';
  @override
  String installedCount(int n) => '$n mod';
  @override
  String get filterLabel => 'Filtra le mod';
  @override
  String get filterAll => 'Tutte';
  @override
  String get filterClient => 'Solo giocatori';
  @override
  String get filterServer => 'Solo server';
  @override
  String get filterDisabled => 'Disattivate';
  @override
  String get findInstalled => 'Cerca tra le mod installate';
  @override
  String get sideClient => _sideIt('client');
  @override
  String get sideServer => _sideIt('server');
  @override
  String get sideBoth => _sideIt('both');
  @override
  String get sideServerTip => 'Solo sul server: i giocatori non la scaricano';
  @override
  String get sideClientTip => 'Solo per i giocatori: il server non la carica';
  @override
  String get chipNew => 'nuova';
  @override
  String get chipManual => 'aggiunto a mano';
  @override
  String get chipDisabled => 'disattivata';
  @override
  String available(String v) => '$v disponibile';
  @override
  String requiredBy(int n) => 'richiesta da $n mod: non si può rimuovere da sola';
  @override
  String get toggleLabel => 'Attiva';
  @override
  String get removeLabel => 'Rimuovi';
  @override
  String get readOnlyHint =>
      'Interruttori e cestino tornano attivi quando il server è libero. Ricerca e preparazione delle modifiche restano disponibili.';
  @override
  String get installedFoot =>
      'Una mod disattivata resta nella cartella, ma il server non la carica.';
  @override
  String get noMatch => 'Nessuna mod corrisponde.';
  @override
  String get noMods => 'Nessuna mod installata.';
  @override
  String get manualNote =>
      'Non trovato su Modrinth: resta così com\'è, senza aggiornamenti automatici';
  @override
  String toUpdate(String v) => '› $v';

  @override
  String get detail => 'Dettaglio';
  @override
  String showAll(int n) => 'Mostra tutti ($n)';
  @override
  String get showFewer => 'Mostra meno';
  @override
  String get manualText =>
      'Non trovato su Modrinth: la sua impronta non corrisponde a nessuna mod pubblica. Succede con mod fatte in casa o ricompilate.';
  @override
  String get manualAdded => 'aggiunta a mano';
  @override
  String get openModrinth => 'Apri su Modrinth';
  @override
  String get detailNote => 'Le modifiche vanno nell\'elenco da applicare.';
  @override
  String get manualUpdate => 'Aggiornamento automatico';
  @override
  String get manualUpdateValue => 'no: per una versione nuova, sostituisci il file';
  @override
  String get whereLabel => 'Dove serve';
  @override
  String get whereHint =>
      'Nel dubbio lascia «Server»: se manca ai giocatori, Minecraft lo segnala all\'ingresso.';
  @override
  String get inClientPack => 'incluso anche nel pacchetto per i giocatori';
  @override
  String get notInClientPack => 'resta solo sul server';
  @override
  String get optionalForPlayers => 'Facoltativa per i giocatori';
  @override
  String get pinLabel => 'Non aggiornarla con «Aggiorna tutte»';
  @override
  String get file => 'File';
  @override
  String get size => 'Dimensione';
  @override
  String get remove => 'Rimuovi…';

  @override
  String searchTitle(String loader, String mc) => 'Aggiungi da Modrinth';
  @override
  String get searchLabel => 'Cerca su Modrinth';
  @override
  String get searchPlaceholder => 'Cerca su Modrinth';
  @override
  String get sortLabel => 'Ordina i risultati';
  @override
  String get sortRelevance => 'Rilevanza';
  @override
  String get sortDownloads => 'Download';
  @override
  String get sortUpdated => 'Aggiornate di recente';
  @override
  String onlyCompatible(String name) => 'Solo quelle che funzionano su $name';
  @override
  String onlyCompatibleHint(String loader, String mc) => '$loader per Minecraft $mc';
  @override
  String hitMeta(String author, String downloads, String description) =>
      description.isEmpty ? 'di $author, $downloads' : 'di $author, $downloads: $description';
  @override
  String downloads(int n) => n >= 1000000
      ? '${(n / 1000000).floor()} M download'
      : n >= 1000
      ? '${(n / 1000).floor()} mila download'
      : '$n download';
  @override
  String get install => 'Installa';
  @override
  String get installing => 'Controllo…';
  @override
  String get chipInstalled => 'installata';
  @override
  String notFor(String loader) => 'non per $loader';
  @override
  String get searchEmpty => 'Scrivi il nome di una mod per cercarla.';
  @override
  String get searchNone => 'Nessun risultato.';
  @override
  String get searchDown => 'Modrinth non risponde';
  @override
  String get searchDownText =>
      'Probabilmente questo PC non ha accesso a internet (l\'hub e ZeroTier funzionano). Le mod installate restano tutte; ricerca e aggiornamenti tornano automaticamente.';
  @override
  String get searchHint =>
      'I risultati che non funzionano su questo server restano visibili con il motivo.';

  @override
  String changes(int n) => n == 1 ? 'modifica da applicare' : 'modifiche da applicare';
  @override
  String get changesLabel => 'Modifiche da applicare';
  @override
  String get appliesNext =>
      'Valgono per tutti dal prossimo Gioca. Si può tornare indietro dalla Storia.';
  @override
  String lockedBar(String who, String name) =>
      '$who sta giocando su $name: le modifiche restano pronte su questo PC e il server acceso non viene toccato.';
  @override
  String get apply => 'Applica e carica sull\'hub';
  @override
  String applyWhen(String who) => 'Applica quando $who chiude';
  @override
  String queuedText(String who) =>
      'Applicazione e caricamento appena $who chiude, preceduti da un avviso.';
  @override
  String get unqueue => 'Togli dalla coda';
  @override
  String get discard => 'Annulla le modifiche';
  @override
  String get waitingModrinth => 'in attesa di Modrinth';
  @override
  String get waitingModrinthText =>
      'Alcune mod vanno ancora scaricate da Modrinth: l\'applicazione parte appena torna la connessione.';
  @override
  String lineAdded(String name, String v) => '+ $name $v';
  @override
  String lineRemoved(String name) => '− $name';
  @override
  String lineUpdated(String name, String a, String b) => '~ $name $a › $b';
  @override
  String lineEnabled(String name) => '+ $name riattivata';
  @override
  String lineDisabled(String name) => '− $name disattivata';
  @override
  String lineChanged(String name) => '~ $name: lato o impostazioni';
  @override
  String lineTarget(String loader, String mc) => '› $loader per Minecraft $mc';
  @override
  String get lineShared => '~ file condivisi con i giocatori';
  @override
  String get lineFirstSetup => 'Prima configurazione delle mod';
  @override
  String andMore(int n) => 'e altre $n';
  @override
  String applyStep(String step) => switch (step) {
    'pull' => 'Download dell\'ultima versione…',
    'install' => 'Installazione del nuovo server…',
    'download' => 'Download e verifica delle mod…',
    _ => 'Carico sull\'hub…',
  };
  @override
  String downloading(String mod) => 'Download di $mod';
  @override
  String applied(int n) => 'Versione #$n caricata';
  @override
  String get appliedNothing => 'Nessuna modifica da caricare';
  @override
  String get appliedText =>
      'Chi entra trova le mod nuove. In caso di problemi, dalla Storia puoi tornare alla versione precedente.';
  @override
  String get applyFailed => 'Modifiche non applicate';
  @override
  String applyFailedText(String reason, Object? detail) => switch (reason) {
    'locked' =>
      'Qualcuno ha iniziato a giocare: la cartella non è cambiata. Le modifiche restano pronte.',
    'pull' => 'Impossibile scaricare l\'ultima versione. La cartella non è cambiata.',
    'changedMeanwhile' =>
      'Nel frattempo le mod sull\'hub sono cambiate. L\'elenco è stato aggiornato: ripeti le modifiche su quello nuovo.',
    'java' => 'Manca Java $detail: installalo (per esempio Eclipse Temurin) e riprova.',
    'install' => 'Installazione del server non riuscita: $detail',
    'unavailable' => 'Alcune mod non si possono scaricare da qui. La cartella non è cambiata.',
    'download' =>
      'Un download non è riuscito o non corrisponde: la cartella non è cambiata. Riprova tra qualche istante.',
    _ =>
      'Le mod sono aggiornate sulla tua copia, ma il caricamento sull\'hub non è riuscito: riprova dalla Panoramica.',
  };
  @override
  String get close => 'Chiudi';
  @override
  String pushMessage(int n) => n == 1 ? 'Mod: 1 modifica' : 'Mod: $n modifiche';
  @override
  String get queuedNotice => 'Server libero: applicazione e caricamento delle modifiche alle mod.';

  @override
  String get retargetTitle => 'Cambia versione o loader';
  @override
  String get retargetIntro =>
      'Prima del cambio, ogni mod viene controllata su Modrinth e vengono indicate quelle che bloccano.';
  @override
  String get minecraft => 'Minecraft';
  @override
  String latest(String v) => '$v (ultima)';
  @override
  String current(String v) => '$v (attuale)';
  @override
  String get releasesOnly => 'Solo versioni stabili';
  @override
  String nowOn(String v) => 'Attuale: $v. Le versioni nuove richiedono di aggiornare anche le mod.';
  @override
  String get loader => 'Loader';
  @override
  String loaderVersionPicked(String loader, String v, String mc) =>
      '$loader $v per $mc, scelto automaticamente.';
  @override
  String get loaderChangeWarn => 'Cambiare loader rimuove quasi tutte le mod.';
  @override
  String javaOk(int major) => 'Java $major: presente';
  @override
  String javaOkText(String mc, int major, String found) =>
      'Minecraft $mc richiede Java $major. Sul PC c\'è $found, che verrà usato.';
  @override
  String javaMissing(int major) => 'Manca Java $major';
  @override
  String javaMissingText(String mc, int major) =>
      'Minecraft $mc richiede Java $major o successivo. Installa Temurin $major (gratuito, di Eclipse Adoptium), poi premi «Cerca di nuovo».';
  @override
  String get javaHow => 'Come installare Java (Temurin)';
  @override
  String get javaRescan => 'Cerca di nuovo';
  @override
  String get check => 'Controlla le mod';
  @override
  String get checkingMods => 'Controllo delle mod su Modrinth…';
  @override
  String checkDone(int n) => 'Controllo delle $n mod completato';
  @override
  String ready(int n, String mc) => '$n pronte per $mc';
  @override
  String blocking(int n) => '$n bloccano';
  @override
  String toCheck(int n) => '$n da controllare manualmente';
  @override
  String get notReady => 'non pronta';
  @override
  String get chipToCheck => 'da controllare';
  @override
  String blockReason(
    String reason, {
    String? other,
    List<String> versions = const [],
  }) => switch (reason) {
    'noCompatibleVersion' => 'nessuna versione per questa versione e questo loader',
    'onlyPrerelease' => 'esiste solo una beta: esclusa',
    'dependencyUnavailable' => 'richiede ${other ?? 'una mod'}, non disponibile qui',
    'dependencyIncompatible' =>
      'richiede ${other ?? 'una mod'} in una versione che funziona solo su ${versions.isEmpty ? 'altre versioni' : versions.join(', ')}',
    'dependencyBlocked' => 'richiede ${other ?? 'una mod'}, che è bloccata',
    'conflict' => 'incompatibile con ${other ?? 'una mod installata'}',
    'alreadyInstalled' => 'è già installata',
    _ => 'Modrinth non ha risposto: riprova',
  };
  @override
  String get manualReason => 'aggiunto a mano: compatibilità sconosciuta';
  @override
  String readyFoot(int n, String mc, int head) =>
      'Le $n pronte passano automaticamente alla versione per $mc. Il mondo della #$head resta nella Storia: si può tornare indietro in qualsiasi momento.';
  @override
  String get watch => 'Avvisami quando sono pronte';
  @override
  String get watchSet => 'Notifica attiva per quando sono pronte';
  @override
  String changeAndRemove(int n) => n == 1 ? 'Cambia e rimuovi 1 mod…' : 'Cambia e rimuovi $n mod…';
  @override
  String get changeTarget => 'Cambia';
  @override
  String get cancel => 'Annulla';
  @override
  String get noLoaderVersions => 'Questo loader non esiste per questa versione di Minecraft.';

  @override
  String addTitle(String name) => 'Installare $name?';
  @override
  String addText(String name, int deps, String loader, String mc) => deps == 0
      ? 'Le dipendenze richieste da $name sono già presenti.'
      : 'Per funzionare, $name richiede ${deps == 1 ? 'un\'altra mod' : 'altre $deps mod'}, aggiunte insieme nella versione giusta per $loader $mc.';
  @override
  String get chosen => 'quella scelta';
  @override
  String requiredFor(String name) => 'obbligatoria per $name';
  @override
  String get willAdd => 'da aggiungere';
  @override
  String alreadyThere(String v) => 'obbligatoria, già presente: la $v è compatibile';
  @override
  String get addFoot =>
      'Per ora vanno solo nelle modifiche da applicare: l\'hub non cambia finché non le applichi.';
  @override
  String addButton(int n) => n == 1 ? 'Aggiungi la mod' : 'Aggiungi le $n mod';
  @override
  String addBlockedTitle(String name) => '$name non si può installare';
  @override
  String get addBlockedText => 'Nessuna modifica effettuata. Motivo:';
  @override
  String updateBlockedTitle(String name, String v) => '$name $v non si può installare';
  @override
  String get updateBlockedFoot =>
      'Nessuna modifica effettuata. L\'aggiornamento viene riproposto quando esce una versione compatibile o se cambi versione di Minecraft.';
  @override
  String get hideUpdate => 'Nascondi questo aggiornamento';
  @override
  String stayOn(String v) => 'Resta su $v';
  @override
  String get haveNow => 'Attuale';
  @override
  String get needs => 'Richiede';
  @override
  String get toGetIt => 'Per averla';
  @override
  String loaderTitle(String name, String loader) => 'Passare $name a $loader?';
  @override
  String loaderText(String loader, String mc) =>
      'Un loader diverso comporta mod diverse: quelle non disponibili per $loader $mc vengono rimosse e i loro blocchi spariscono dal mondo.';
  @override
  String get loaderEyebrow => 'Cambio di loader';
  @override
  String keep(int n, String loader) => 'Restano $n mod, nella versione per $loader';
  @override
  String removed(int n, String names) => 'Rimosse $n, tra cui $names';
  @override
  String get worldLoss => 'Nel mondo spariscono i blocchi e gli oggetti delle mod rimosse';
  @override
  String get backTerm => 'Annullamento';
  @override
  String backValue(int head, String loader) =>
      'la #$head, con $loader e il mondo di adesso, resta nella Storia';
  @override
  String get loaderFoot =>
      'Non disponibile mentre qualcuno gioca. Anche i giocatori devono aggiornare il pacchetto e ricevono un avviso.';
  @override
  String stayOnLoader(String loader) => 'Resta su $loader';
  @override
  String switchTo(String loader) => 'Passa a $loader';
  @override
  String cfTitle(String name) => '$name va scaricata a mano';
  @override
  String get cfText =>
      'Questa mod è su CurseForge e l\'autore non consente ad altre app di scaricarla. Scaricala dalla sua pagina, poi indica qui il file.';
  @override
  String cfStep1(String loader, String mc) => 'Apri la pagina e scarica il file per $loader $mc.';
  @override
  String get cfStep2 =>
      'Inserisci qui il percorso del file e premi «Usa il file»: viene verificato che sia quello giusto.';
  @override
  String get cfFoot =>
      'La regola è dell\'autore, non di MineSync. Anche i giocatori dovranno scaricarla così: il loro pacchetto contiene lo stesso link.';
  @override
  String get cfOpen => 'Apri la pagina su CurseForge';
  @override
  String get cfHaveFile => 'Usa il file';
  @override
  String get cfPath => 'Percorso del file scaricato';
  @override
  String get cfWrong => 'File non corretto: l\'impronta non corrisponde.';
  @override
  String lockedTitle2(String who, String name) => '$who sta giocando su $name';
  @override
  String get lockedText2 =>
      'Impossibile applicare adesso. Cambiare le mod a server acceso farebbe uscire chi è dentro e potrebbe danneggiare il mondo.';
  @override
  String get yourChanges => 'Le tue modifiche';
  @override
  String yourChangesValue(int n) => '$n, al sicuro su questo PC';
  @override
  String get inGame => 'In gioco';
  @override
  String inGameValue(String who, String since, int online) =>
      '$who da $since${online > 0 ? ' ($online online)' : ''}';
  @override
  String get whenFree => 'Quando chiude';
  @override
  String whenFreeValue(int next) => 'applicazione e caricamento della #$next, se attivato';
  @override
  String get queueSwitch => 'Applica quando il server si libera';
  @override
  String get queueSwitchHint => 'con una notifica prima dell\'applicazione';
  @override
  String get wait => 'Attendi';
  @override
  String get confirmTitle => 'Caricare le modifiche sull\'hub?';
  @override
  String confirmText(int next, String name) =>
      'Valgono per tutti: chi gioca $name da adesso trova le mod nuove.';
  @override
  String confirmDownload(int n, String size) =>
      n == 1 ? 'Download di 1 mod da Modrinth ($size)' : 'Download di $n mod da Modrinth ($size)';
  @override
  String get noDownload => 'Nessun download';
  @override
  String get forPlayers => 'Giocatori';
  @override
  String get forPlayersValue => 'aggiornano il pacchetto con un clic';
  @override
  String get confirmApply => 'Applica e carica';
  @override
  String removeTitle(String name) => 'Rimuovere $name?';
  @override
  String get removeText =>
      'Se aggiunge blocchi o oggetti, quelli già nel mondo spariscono al prossimo avvio.';
  @override
  String usedBy(int n) => n == 1
      ? 'Usata da 1 mod che la richiede: viene rimossa anche quella'
      : 'Usata da $n mod che la richiedono: vengono rimosse anche quelle';
  @override
  String get orphansTerm => 'Dipendenze';
  @override
  String orphans(int n) => n == 1
      ? '1 aggiunta automaticamente non serve più: viene rimossa'
      : '$n aggiunte automaticamente non servono più: vengono rimosse';
  @override
  String dependsOn(String name) => 'dipende da $name';
  @override
  String get alsoRemoved => 'rimossa insieme';
  @override
  String removeButton(String name, int n) => n == 0 ? 'Rimuovi $name' : 'Rimuovi $name e $n mod';
  @override
  String historyBack(int head) => 'Storia › #$head';
  @override
  String get dependentsTerm => 'Dipendenti';

  @override
  String forPlayersCount(int n) => n == 1 ? '1 mod per i giocatori' : '$n mod per i giocatori';
  @override
  String get cpNotReady => 'Server non ancora pronto per giocare su questo PC';
  @override
  String get cpNotReadyText =>
      'Scegli qui sotto come preparare Minecraft: serve circa un minuto, poi a ogni aggiornamento del server basta un clic.';
  @override
  String cpOutdated(String where, int mine, int head) =>
      'Il tuo pacchetto in $where è alla #$mine, il server alla #$head';
  @override
  String get cpOutdatedText =>
      'Con il pacchetto vecchio, il server può rifiutare l\'ingresso per «mod mancanti».';
  @override
  String cpUpdateIn(String where) => 'Aggiorna in $where';
  @override
  String get cpReady => 'Pronto per giocare';
  @override
  String cpReadyText(String where, int n, String address) =>
      '$where ha il pacchetto della #$n, uguale al server. Avvialo ed entra su $address.';
  @override
  String get cpNoLaunch => 'MineSync non avvia Minecraft';
  @override
  String get cpNoLaunchText =>
      'Per giocare serve il tuo account Microsoft, utilizzabile solo dai launcher approvati. MineSync prepara l\'istanza; avviala da Prism Launcher o dal launcher ufficiale.';
  @override
  String get prism => 'Prism Launcher';
  @override
  String get prismFound => 'trovato sul PC';
  @override
  String get prismRecommended => 'consigliato';
  @override
  String get prismText =>
      'Importa il pacchetto con un clic: Prism crea l\'istanza con loader e mod, separata dalle altre.';
  @override
  String get prismStep1 => 'Premi «Apri in Prism»: si apre la sua finestra di importazione.';
  @override
  String get prismStep2 => 'Conferma con OK. Prism scarica le mod da Modrinth.';
  @override
  String prismStep3(String address) => 'Avvia l\'istanza, poi Multigiocatore › $address';
  @override
  String get openInPrism => 'Apri in Prism';
  @override
  String get exportMrpack => 'Esporta il file .mrpack';
  @override
  String get prismMissing => 'Prism Launcher non trovato';
  @override
  String get prismMissingText =>
      'Prism non è installato su questo PC. È gratuito e open source e gestisce automaticamente account Microsoft, Java e mod.';
  @override
  String get prismDownload => 'Scarica Prism Launcher';
  @override
  String get prismMissingFoot =>
      'Nel frattempo puoi esportare il file .mrpack e importarlo in Prism dopo l\'installazione.';
  @override
  String get official => 'Launcher ufficiale';
  @override
  String officialText(String loader, String mc) =>
      'Viene creato un profilo MineSync con $loader per Minecraft $mc e le mod in una cartella dedicata, così gli altri profili non cambiano. Prima viene salvata una copia del file dei profili.';
  @override
  String get profileTerm => 'Profilo';
  @override
  String profileValue(String name) => 'MineSync ($name)';
  @override
  String get folderTerm => 'Cartella';
  @override
  String get updatesTerm => 'Aggiornamenti';
  @override
  String get updatesValue => 'premi di nuovo «Crea il profilo» a ogni versione nuova';
  @override
  String get createProfile => 'Crea il profilo';
  @override
  String get closeLauncherFirst => 'Chiudi prima il launcher.';
  @override
  String get officialMissing =>
      'Launcher ufficiale non trovato su questo PC (manca la cartella .minecraft). Avvialo una volta, poi torna qui.';
  @override
  String get officialUnsupported =>
      'Per Forge e NeoForge il profilo viene creato dal loro installer: usa Prism, che gestisce tutto automaticamente.';
  @override
  String profileDone(String folder) => 'Profilo pronto, cartella $folder.';
  @override
  String profileBackup(String file) => 'Copia del file dei profili: $file';
  @override
  String get contents => 'Cosa c\'è nel pacchetto';
  @override
  String contentsFrom(int n) => 'dalla #$n';
  @override
  String get cpAll => 'Tutte';
  @override
  String get cpRequired => 'Obbligatorie';
  @override
  String get cpOptional => 'Facoltative';
  @override
  String get cpServerOnly => 'Solo sul server';
  @override
  String requiredFoot(int n) => 'Senza queste il server non consente l\'ingresso.';
  @override
  String get optionalFoot =>
      'Solo per te: il server funziona anche senza. Le scelte valgono su questo PC.';
  @override
  String serverOnlyFoot(int n) => 'Escluse dal pacchetto: funzionano solo su chi ospita.';
  @override
  String get iWantIt => 'includi';
  @override
  String get exportedTitle => 'Pacchetto esportato';
  @override
  String exportedText(String path) => '$path. Aprilo con Prism o invialo a chi non usa MineSync.';
  @override
  String get localBehind => 'La tua copia del server è indietro';
  @override
  String localBehindText(int mine, int head) =>
      'Il pacchetto viene preparato dalla tua copia, ferma alla #$mine: prima serve scaricare la #$head.';
  @override
  String get localDownload => 'Scarica l\'ultima versione';
  @override
  String get cpVanilla => 'Server vanilla';
  @override
  String cpVanillaText(String name, String mc, String address) =>
      '$name è vanilla: niente da installare. Apri Minecraft $mc dal launcher ufficiale o da Prism, poi Multigiocatore › $address.';
  @override
  String get copyAddress => 'Copia indirizzo';
  @override
  String get copied => 'Indirizzo copiato';
  @override
  String get missingTitle => 'Alcune mod vanno scaricate a mano';
  @override
  String missingText(String names) =>
      '$names: l\'autore non consente ad altre app di scaricarle. Il resto del pacchetto è pronto.';
  @override
  String get openPage => 'Apri la pagina';
  @override
  String get cpError => 'Impossibile preparare il pacchetto';
  @override
  String get cpNoPack => 'Ancora nessun pacchetto';
  @override
  String get cpNoPackText => 'Applica una volta le mod del server per crearlo.';
  @override
  String get goServerMods => 'Vai alle mod del server';
}

String _sideEn(String s) => switch (s) {
  'client' => 'Players',
  'server' => 'Server',
  _ => 'Server and players',
};

final class _En extends ModpackStrings {
  const _En();

  @override
  String get tab => 'Mods';
  @override
  String get viewLabel => 'Mods tab view';
  @override
  String get viewServer => 'Server mods';
  @override
  String get viewClient => 'Players pack';
  @override
  String get retarget => 'Change version or loader…';
  @override
  String get addJar => 'From file…';
  @override
  String get noFolder => 'To change the mods, download the server';
  @override
  String get getServer => 'Download the server';
  @override
  String get manualKept => 'Mods not found on Modrinth stay as they are.';
  @override
  String get loading => 'Reading the mods in your copy…';
  @override
  String get recognizing => 'Recognising the mods on Modrinth…';
  @override
  String get recognizingText =>
      'First scan: the fingerprint of every mod file is looked up on Modrinth to identify it.';
  @override
  String get noVersion => 'Server version not recognised';
  @override
  String get noVersionText =>
      'The Minecraft version and the loader are required: start the server once, or choose «Change version or loader».';
  @override
  String get loadError => 'Unable to read the mods';
  @override
  String get retry => 'Try again';
  @override
  String lockedTitle(String who) => '$who is playing: mods are read-only';
  @override
  String get lockedText =>
      'Changing them while the server runs would interrupt the current game. You can browse them and prepare changes to apply when the server is free.';
  @override
  String get notifyFree => 'Notify me when it is free';
  @override
  String get notifyFreeOn => 'Notification on for when it is free';
  @override
  String get modrinthDown => 'Modrinth not responding';
  @override
  String get modrinthDownText =>
      'Installed mods stay visible and can be disabled as usual. Search and updates return as soon as Modrinth responds. Retrying automatically every 30 s.';
  @override
  String modrinthNext(String at, int seconds) => 'Last attempt: $at, next in $seconds s';
  @override
  String watchReady(String mc) => 'The mods are ready for Minecraft $mc';
  @override
  String watchReadyNotice(String mc) =>
      'Every mod exists for Minecraft $mc: the switch is possible.';
  @override
  String get vanillaTitle => 'Vanilla server';
  @override
  String get vanillaText =>
      'No loader and no mods. To add mods, choose a loader with «Change version or loader».';

  @override
  String get updates => 'Updates';
  @override
  String checkedAgo(String ago) => 'checked $ago';
  @override
  String get checkUpdates => 'Check for updates';
  @override
  String get checking => 'Checking…';
  @override
  String get notChecked => 'Not checked yet.';
  @override
  String updateAll(int n) => 'Update all ($n)';
  @override
  String get update => 'Update';
  @override
  String get inChanges => 'in the changes';
  @override
  String get why => 'Reason';
  @override
  String get noUpdates => 'All mods are up to date.';
  @override
  String fromTo(String a, String b) => '$a › $b';

  @override
  String get installed => 'Installed';
  @override
  String installedCount(int n) => n == 1 ? '1 mod' : '$n mods';
  @override
  String get filterLabel => 'Filter mods';
  @override
  String get filterAll => 'All';
  @override
  String get filterClient => 'Players only';
  @override
  String get filterServer => 'Server only';
  @override
  String get filterDisabled => 'Disabled';
  @override
  String get findInstalled => 'Search installed mods';
  @override
  String get sideClient => _sideEn('client');
  @override
  String get sideServer => _sideEn('server');
  @override
  String get sideBoth => _sideEn('both');
  @override
  String get sideServerTip => 'Server only: players do not download it';
  @override
  String get sideClientTip => 'Players only: the server does not load it';
  @override
  String get chipNew => 'new';
  @override
  String get chipManual => 'added by hand';
  @override
  String get chipDisabled => 'disabled';
  @override
  String available(String v) => '$v available';
  @override
  String requiredBy(int n) => 'required by $n mods: cannot be removed on its own';
  @override
  String get toggleLabel => 'Enabled';
  @override
  String get removeLabel => 'Remove';
  @override
  String get readOnlyHint =>
      'Switches and the bin return when the server is free. Search and change preparation stay available.';
  @override
  String get installedFoot =>
      'A disabled mod stays in the folder, but the server does not load it.';
  @override
  String get noMatch => 'No mod matches.';
  @override
  String get noMods => 'No mods installed.';
  @override
  String get manualNote => 'Not found on Modrinth: kept as it is, no automatic updates';
  @override
  String toUpdate(String v) => '› $v';

  @override
  String get detail => 'Detail';
  @override
  String showAll(int n) => 'Show all ($n)';
  @override
  String get showFewer => 'Show fewer';
  @override
  String get manualText =>
      'Not found on Modrinth: its fingerprint matches no public mod. This happens with home-made or rebuilt mods.';
  @override
  String get manualAdded => 'added by hand';
  @override
  String get openModrinth => 'Open on Modrinth';
  @override
  String get detailNote => 'Changes join the list to apply.';
  @override
  String get manualUpdate => 'Automatic updates';
  @override
  String get manualUpdateValue => 'no: for a new version, replace the file yourself';
  @override
  String get whereLabel => 'Where it is needed';
  @override
  String get whereHint =>
      'If in doubt, leave «Server»: if players need it, Minecraft reports it when they join.';
  @override
  String get inClientPack => 'also included in the players pack';
  @override
  String get notInClientPack => 'stays on the server only';
  @override
  String get optionalForPlayers => 'Optional for players';
  @override
  String get pinLabel => 'Skip it in «Update all»';
  @override
  String get file => 'File';
  @override
  String get size => 'Size';
  @override
  String get remove => 'Remove…';

  @override
  String searchTitle(String loader, String mc) => 'Add from Modrinth';
  @override
  String get searchLabel => 'Search Modrinth';
  @override
  String get searchPlaceholder => 'Search Modrinth';
  @override
  String get sortLabel => 'Sort results';
  @override
  String get sortRelevance => 'Relevance';
  @override
  String get sortDownloads => 'Downloads';
  @override
  String get sortUpdated => 'Recently updated';
  @override
  String onlyCompatible(String name) => 'Only those that work on $name';
  @override
  String onlyCompatibleHint(String loader, String mc) => '$loader for Minecraft $mc';
  @override
  String hitMeta(String author, String downloads, String description) =>
      description.isEmpty ? 'by $author, $downloads' : 'by $author, $downloads: $description';
  @override
  String downloads(int n) => n >= 1000000
      ? '${(n / 1000000).floor()} M downloads'
      : n >= 1000
      ? '${(n / 1000).floor()} k downloads'
      : '$n downloads';
  @override
  String get install => 'Install';
  @override
  String get installing => 'Checking…';
  @override
  String get chipInstalled => 'installed';
  @override
  String notFor(String loader) => 'not for $loader';
  @override
  String get searchEmpty => 'Type the name of a mod to search for it.';
  @override
  String get searchNone => 'No results.';
  @override
  String get searchDown => 'Modrinth not responding';
  @override
  String get searchDownText =>
      'This PC probably has no internet access (the hub and ZeroTier work). All installed mods stay; search and updates return automatically.';
  @override
  String get searchHint => 'Results that do not work on this server stay visible with the reason.';

  @override
  String changes(int n) => n == 1 ? 'change to apply' : 'changes to apply';
  @override
  String get changesLabel => 'Changes to apply';
  @override
  String get appliesNext =>
      'Applies to everyone from the next Play. It can be undone from History.';
  @override
  String lockedBar(String who, String name) =>
      '$who is playing on $name: the changes stay ready on this PC and the running server is not touched.';
  @override
  String get apply => 'Apply and upload to the hub';
  @override
  String applyWhen(String who) => 'Apply when $who quits';
  @override
  String queuedText(String who) =>
      'Applied and uploaded as soon as $who quits, with a notice first.';
  @override
  String get unqueue => 'Remove from queue';
  @override
  String get discard => 'Discard the changes';
  @override
  String get waitingModrinth => 'waiting for Modrinth';
  @override
  String get waitingModrinthText =>
      'Some mods still have to be downloaded from Modrinth: applying starts when the connection is back.';
  @override
  String lineAdded(String name, String v) => '+ $name $v';
  @override
  String lineRemoved(String name) => '− $name';
  @override
  String lineUpdated(String name, String a, String b) => '~ $name $a › $b';
  @override
  String lineEnabled(String name) => '+ $name enabled';
  @override
  String lineDisabled(String name) => '− $name disabled';
  @override
  String lineChanged(String name) => '~ $name: side or settings';
  @override
  String lineTarget(String loader, String mc) => '› $loader for Minecraft $mc';
  @override
  String get lineShared => '~ files shared with players';
  @override
  String get lineFirstSetup => 'First mod setup';
  @override
  String andMore(int n) => 'and $n more';
  @override
  String applyStep(String step) => switch (step) {
    'pull' => 'Downloading the latest version…',
    'install' => 'Installing the new server…',
    'download' => 'Downloading and checking the mods…',
    _ => 'Uploading to the hub…',
  };
  @override
  String downloading(String mod) => 'Downloading $mod';
  @override
  String applied(int n) => 'Uploaded #$n';
  @override
  String get appliedNothing => 'Nothing to upload';
  @override
  String get appliedText =>
      'Players who join get the new mods. If something goes wrong, go back to the previous version from History.';
  @override
  String get applyFailed => 'Changes not applied';
  @override
  String applyFailedText(String reason, Object? detail) => switch (reason) {
    'locked' => 'Someone started playing: the folder did not change. The changes stay ready.',
    'pull' => 'Unable to download the latest version. The folder did not change.',
    'changedMeanwhile' =>
      'The mods on the hub changed in the meantime. The list has been reloaded: redo your changes on the new one.',
    'java' => 'Java $detail is missing: install it (for example Eclipse Temurin) and try again.',
    'install' => 'Server installation failed: $detail',
    'unavailable' => 'Some mods cannot be downloaded from here. The folder did not change.',
    'download' =>
      'A download failed or did not match: the folder did not change. Try again shortly.',
    _ =>
      'The mods are updated in your copy, but the upload to the hub failed: try again from Overview.',
  };
  @override
  String get close => 'Close';
  @override
  String pushMessage(int n) => n == 1 ? 'Mods: 1 change' : 'Mods: $n changes';
  @override
  String get queuedNotice => 'Server free: applying and uploading the mod changes.';

  @override
  String get retargetTitle => 'Change version or loader';
  @override
  String get retargetIntro =>
      'Before the change, every mod is checked on Modrinth and the blocking ones are listed.';
  @override
  String get minecraft => 'Minecraft';
  @override
  String latest(String v) => '$v (latest)';
  @override
  String current(String v) => '$v (current)';
  @override
  String get releasesOnly => 'Stable versions only';
  @override
  String nowOn(String v) => 'Current: $v. Newer versions also require newer mods.';
  @override
  String get loader => 'Loader';
  @override
  String loaderVersionPicked(String loader, String v, String mc) =>
      '$loader $v for $mc, chosen automatically.';
  @override
  String get loaderChangeWarn => 'Changing loader removes almost every mod.';
  @override
  String javaOk(int major) => 'Java $major: installed';
  @override
  String javaOkText(String mc, int major, String found) =>
      'Minecraft $mc requires Java $major. This PC has $found, which will be used.';
  @override
  String javaMissing(int major) => 'Java $major is missing';
  @override
  String javaMissingText(String mc, int major) =>
      'Minecraft $mc requires Java $major or newer. Install Temurin $major (free, from Eclipse Adoptium), then press «Search again».';
  @override
  String get javaHow => 'How to install Java (Temurin)';
  @override
  String get javaRescan => 'Search again';
  @override
  String get check => 'Check the mods';
  @override
  String get checkingMods => 'Checking the mods on Modrinth…';
  @override
  String checkDone(int n) => 'Check of the $n mods complete';
  @override
  String ready(int n, String mc) => '$n ready for $mc';
  @override
  String blocking(int n) => '$n blocking';
  @override
  String toCheck(int n) => '$n to check manually';
  @override
  String get notReady => 'not ready';
  @override
  String get chipToCheck => 'to check';
  @override
  String blockReason(
    String reason, {
    String? other,
    List<String> versions = const [],
  }) => switch (reason) {
    'noCompatibleVersion' => 'no version for this Minecraft version and loader',
    'onlyPrerelease' => 'only a beta exists: excluded',
    'dependencyUnavailable' => 'requires ${other ?? 'a mod'}, not available here',
    'dependencyIncompatible' =>
      'requires ${other ?? 'a mod'} in a version that only runs on ${versions.isEmpty ? 'other versions' : versions.join(', ')}',
    'dependencyBlocked' => 'requires ${other ?? 'a mod'}, which is blocked',
    'conflict' => 'incompatible with ${other ?? 'an installed mod'}',
    'alreadyInstalled' => 'is already installed',
    _ => 'Modrinth did not respond: try again',
  };
  @override
  String get manualReason => 'added by hand: compatibility unknown';
  @override
  String readyFoot(int n, String mc, int head) =>
      'The $n ready mods move to their $mc version automatically. The world of #$head stays in History and can be restored at any time.';
  @override
  String get watch => 'Notify me when they are ready';
  @override
  String get watchSet => 'Notification on for when they are ready';
  @override
  String changeAndRemove(int n) =>
      n == 1 ? 'Change and remove 1 mod…' : 'Change and remove $n mods…';
  @override
  String get changeTarget => 'Change';
  @override
  String get cancel => 'Cancel';
  @override
  String get noLoaderVersions => 'This loader does not exist for this Minecraft version.';

  @override
  String addTitle(String name) => 'Install $name?';
  @override
  String addText(String name, int deps, String loader, String mc) => deps == 0
      ? 'The dependencies required by $name are already installed.'
      : 'To work, $name requires ${deps == 1 ? 'another mod' : '$deps other mods'}, added together in the right version for $loader $mc.';
  @override
  String get chosen => 'the selected one';
  @override
  String requiredFor(String name) => 'required by $name';
  @override
  String get willAdd => 'to be added';
  @override
  String alreadyThere(String v) => 'required, already installed: $v is compatible';
  @override
  String get addFoot =>
      'For now they only go into the changes to apply: the hub does not change until you apply them.';
  @override
  String addButton(int n) => n == 1 ? 'Add the mod' : 'Add the $n mods';
  @override
  String addBlockedTitle(String name) => '$name cannot be installed';
  @override
  String get addBlockedText => 'Nothing was changed. Reason:';
  @override
  String updateBlockedTitle(String name, String v) => '$name $v cannot be installed';
  @override
  String get updateBlockedFoot =>
      'Nothing was changed. The update is offered again when a compatible version is released, or if you change Minecraft version.';
  @override
  String get hideUpdate => 'Hide this update';
  @override
  String stayOn(String v) => 'Stay on $v';
  @override
  String get haveNow => 'Current';
  @override
  String get needs => 'Requires';
  @override
  String get toGetIt => 'To get it';
  @override
  String loaderTitle(String name, String loader) => 'Move $name to $loader?';
  @override
  String loaderText(String loader, String mc) =>
      'A different loader means different mods: those not available for $loader $mc are removed, and their blocks disappear from the world.';
  @override
  String get loaderEyebrow => 'Loader change';
  @override
  String keep(int n, String loader) => '$n mods stay, in their $loader version';
  @override
  String removed(int n, String names) => '$n removed, including $names';
  @override
  String get worldLoss => 'Blocks and items of the removed mods disappear from the world';
  @override
  String get backTerm => 'Undo';
  @override
  String backValue(int head, String loader) =>
      '#$head, with $loader and today\'s world, stays in History';
  @override
  String get loaderFoot =>
      'Not available while someone is playing. Players must update their pack too and are notified.';
  @override
  String stayOnLoader(String loader) => 'Stay on $loader';
  @override
  String switchTo(String loader) => 'Move to $loader';
  @override
  String cfTitle(String name) => '$name must be downloaded by hand';
  @override
  String get cfText =>
      'This mod is on CurseForge and its author does not allow other apps to download it. Download it from its page, then select the file here.';
  @override
  String cfStep1(String loader, String mc) =>
      'Open the page and download the file for $loader $mc.';
  @override
  String get cfStep2 =>
      'Enter the file path here and press «Use the file»: it is checked to be the right one.';
  @override
  String get cfFoot =>
      'The rule is the author\'s, not MineSync\'s. Players download it the same way: their pack has the same link.';
  @override
  String get cfOpen => 'Open the page on CurseForge';
  @override
  String get cfHaveFile => 'Use the file';
  @override
  String get cfPath => 'Path of the downloaded file';
  @override
  String get cfWrong => 'Wrong file: the fingerprint does not match.';
  @override
  String lockedTitle2(String who, String name) => '$who is playing on $name';
  @override
  String get lockedText2 =>
      'Unable to apply now. Changing mods while the server runs would disconnect the players and could damage the world.';
  @override
  String get yourChanges => 'Your changes';
  @override
  String yourChangesValue(int n) => '$n, safe on this PC';
  @override
  String get inGame => 'Playing';
  @override
  String inGameValue(String who, String since, int online) =>
      '$who for $since${online > 0 ? ' ($online online)' : ''}';
  @override
  String get whenFree => 'When they quit';
  @override
  String whenFreeValue(int next) => '#$next is applied and uploaded, if enabled';
  @override
  String get queueSwitch => 'Apply when the server is free';
  @override
  String get queueSwitchHint => 'with a notification first';
  @override
  String get wait => 'Wait';
  @override
  String get confirmTitle => 'Upload the changes to the hub?';
  @override
  String confirmText(int next, String name) =>
      'They apply to everyone: whoever plays $name from now on gets the new mods.';
  @override
  String confirmDownload(int n, String size) => n == 1
      ? '1 mod to download from Modrinth ($size)'
      : '$n mods to download from Modrinth ($size)';
  @override
  String get noDownload => 'Nothing to download';
  @override
  String get forPlayers => 'Players';
  @override
  String get forPlayersValue => 'update their pack with one click';
  @override
  String get confirmApply => 'Apply and upload';
  @override
  String removeTitle(String name) => 'Remove $name?';
  @override
  String get removeText =>
      'If it adds blocks or items, those already in the world disappear at the next start.';
  @override
  String usedBy(int n) => n == 1
      ? 'Used by 1 mod that requires it: that mod is removed too'
      : 'Used by $n mods that require it: those mods are removed too';
  @override
  String get orphansTerm => 'Dependencies';
  @override
  String orphans(int n) => n == 1
      ? '1 added automatically is no longer needed: it is removed'
      : '$n added automatically are no longer needed: they are removed';
  @override
  String dependsOn(String name) => 'depends on $name';
  @override
  String get alsoRemoved => 'removed too';
  @override
  String removeButton(String name, int n) => n == 0 ? 'Remove $name' : 'Remove $name and $n mods';
  @override
  String historyBack(int head) => 'History › #$head';
  @override
  String get dependentsTerm => 'Dependents';

  @override
  String forPlayersCount(int n) => n == 1 ? '1 mod for players' : '$n mods for players';
  @override
  String get cpNotReady => 'Server not ready to play on this PC yet';
  @override
  String get cpNotReadyText =>
      'Choose below how to set up Minecraft: it takes about a minute, then one click at every server update.';
  @override
  String cpOutdated(String where, int mine, int head) =>
      'Your pack in $where is at #$mine, the server at #$head';
  @override
  String get cpOutdatedText =>
      'With the old pack, the server may refuse to let you in with «missing mods».';
  @override
  String cpUpdateIn(String where) => 'Update in $where';
  @override
  String get cpReady => 'Ready to play';
  @override
  String cpReadyText(String where, int n, String address) =>
      '$where has the pack of #$n, same as the server. Start it and join $address.';
  @override
  String get cpNoLaunch => 'MineSync does not start Minecraft';
  @override
  String get cpNoLaunchText =>
      'Playing requires your Microsoft account, which only approved launchers can use. MineSync prepares the instance; start it from Prism Launcher or the official launcher.';
  @override
  String get prism => 'Prism Launcher';
  @override
  String get prismFound => 'found on this PC';
  @override
  String get prismRecommended => 'recommended';
  @override
  String get prismText =>
      'Import the pack with one click: Prism creates the instance with the loader and the mods, separate from the others.';
  @override
  String get prismStep1 => 'Press «Open in Prism»: its import window opens.';
  @override
  String get prismStep2 => 'Confirm with OK. Prism downloads the mods from Modrinth.';
  @override
  String prismStep3(String address) => 'Start the instance, then Multiplayer › $address';
  @override
  String get openInPrism => 'Open in Prism';
  @override
  String get exportMrpack => 'Export the .mrpack file';
  @override
  String get prismMissing => 'Prism Launcher not found';
  @override
  String get prismMissingText =>
      'Prism is not installed on this PC. It is free and open source, and manages Microsoft accounts, Java and mods automatically.';
  @override
  String get prismDownload => 'Download Prism Launcher';
  @override
  String get prismMissingFoot =>
      'Meanwhile, you can export the .mrpack file and import it into Prism after installing it.';
  @override
  String get official => 'Official launcher';
  @override
  String officialText(String loader, String mc) =>
      'This creates a MineSync profile with $loader for Minecraft $mc and the mods in a dedicated folder, so other profiles do not change. The profiles file is backed up first.';
  @override
  String get profileTerm => 'Profile';
  @override
  String profileValue(String name) => 'MineSync ($name)';
  @override
  String get folderTerm => 'Folder';
  @override
  String get updatesTerm => 'Updates';
  @override
  String get updatesValue => 'press «Create the profile» again at every new version';
  @override
  String get createProfile => 'Create the profile';
  @override
  String get closeLauncherFirst => 'Close the launcher first.';
  @override
  String get officialMissing =>
      'Official launcher not found on this PC (no .minecraft folder). Start it once, then come back.';
  @override
  String get officialUnsupported =>
      'For Forge and NeoForge, the profile is created by their own installer: use Prism, which handles everything automatically.';
  @override
  String profileDone(String folder) => 'Profile ready, folder $folder.';
  @override
  String profileBackup(String file) => 'Backup of the profiles file: $file';
  @override
  String get contents => 'What is in the pack';
  @override
  String contentsFrom(int n) => 'from #$n';
  @override
  String get cpAll => 'All';
  @override
  String get cpRequired => 'Required';
  @override
  String get cpOptional => 'Optional';
  @override
  String get cpServerOnly => 'Server only';
  @override
  String requiredFoot(int n) => 'Without these, the server refuses entry.';
  @override
  String get optionalFoot =>
      'For you only: the server works without them. Choices apply to this PC.';
  @override
  String serverOnlyFoot(int n) => 'Not included in the pack: they only run on the host.';
  @override
  String get iWantIt => 'include';
  @override
  String get exportedTitle => 'Pack exported';
  @override
  String exportedText(String path) =>
      '$path. Open it with Prism, or send it to players who do not use MineSync.';
  @override
  String get localBehind => 'Your copy of the server is behind';
  @override
  String localBehindText(int mine, int head) =>
      'The pack is built from your copy, which is at #$mine: #$head must be downloaded first.';
  @override
  String get localDownload => 'Download the latest version';
  @override
  String get cpVanilla => 'Vanilla server';
  @override
  String cpVanillaText(String name, String mc, String address) =>
      '$name is vanilla: nothing to install. Open Minecraft $mc from the official launcher or Prism, then Multiplayer › $address.';
  @override
  String get copyAddress => 'Copy address';
  @override
  String get copied => 'Address copied';
  @override
  String get missingTitle => 'Some mods must be downloaded by hand';
  @override
  String missingText(String names) =>
      '$names: the author does not allow other apps to download them. The rest of the pack is ready.';
  @override
  String get openPage => 'Open the page';
  @override
  String get cpError => 'Unable to prepare the pack';
  @override
  String get cpNoPack => 'No pack yet';
  @override
  String get cpNoPackText => 'Apply the server mods once to create it.';
  @override
  String get goServerMods => 'Go to the server mods';
}
