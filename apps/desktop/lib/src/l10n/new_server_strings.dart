// Testi della procedura «Nuovo server»: origine, nome, versione e tipo di
// server, modpack, cartella esistente, mod consigliate, EULA, creazione ed
// errori, e perché Avanti è spento.
import 'package:ms_l10n/ms_l10n.dart';

abstract final class NewServerStrings {
  const NewServerStrings();

  static NewServerStrings of(Lang l) => switch (l) {
    Lang.it => const _It(),
    Lang.en => const _En(),
  };

  String get title;
  String get stepsLabel;

  /// «passo 2 di 4», per i lettori di schermo.
  String stepOf(int position, int total);
  String step(String s);
  String get originTitle;
  String get originIntro;
  String get scratch;
  String get scratchText;
  String get modpack;
  String get modpackText;
  String get folder;
  String get folderText;
  String get cancel;
  String get next;
  String get back;
  String get adminOnly;

  /// Perché Avanti è spento.
  String get needName;
  String get needVersion;
  String needLoader(String loader);
  String needJava(int major);
  String get needPack;
  String get needFolder;
  String get wait;

  String get versionTitle;
  String get minecraft;
  String latest(String v);
  String get popular;
  String get releasesOnly;
  String get memory;
  String gb(int n);
  String get memoryHint;
  String get loader;

  /// Vanilla nella scelta del tipo di server: «Vanilla (senza mod)».
  String get vanillaTitle;
  String loaderText(String loader);
  String recommendedVersion(String v);
  String get noLoaderVersions;
  String get versionsError;
  String javaOk(int major);
  String javaOkText(String mc, int major, String found);
  String javaMissing(int major);
  String javaMissingText(String mc, int major, String found);
  String get javaHow;
  String get javaRescan;
  String get javaSearching;

  String get modpackTitle;
  String get mrpackPath;
  String get mrpackHint;
  String get open;
  String get base;
  String get mods;
  String modsValue(int server, int client);
  String get importError;

  String get folderTitle;
  String get folderIntro;
  String get folderPath;
  String get check;
  String get world;
  String get start;
  String folderMods(int n);
  String folderCopy(String dest);
  String get folderError;
  String get profile;

  String get modsTitle;
  String modsIntro(String loader);
  String get fabricApi;
  String get fabricApiText;
  String modHint(String slug);
  String get skip;
  String nextMods(int n);

  String get eulaTitle;
  String eulaIntro(String name);
  String get eulaText;
  String get eulaRead;
  String get summary;
  String get name;
  String get none;
  String get accept;

  /// Avanti di una cartella generica, che non ha l'EULA.
  String get create;

  String creating(String name);
  String get creatingText;
  String task(String t);
  String get failedTitle;
  String get failedText;
  String get nothingOnHub;
  String nothingOnHubText(String name);
  String get retry;
  String get copyDetails;
  String get copied;
  String readyTitle(String name);
  String get readyText;
  String get onPc;
  String get addMods;
  String get play;
  String get goToServer;
}

final class _It extends NewServerStrings {
  const _It();

  @override
  String get title => 'Nuovo server';
  @override
  String get stepsLabel => 'Passi';
  @override
  String stepOf(int position, int total) => 'passo $position di $total';
  @override
  String step(String s) => switch (s) {
    'origin' => 'Origine',
    'version' => 'Versione',
    'modpack' => 'Modpack',
    'folder' => 'Cartella',
    'mods' => 'Mod',
    _ => 'EULA',
  };
  @override
  String get originTitle => 'Scegli il punto di partenza';
  @override
  String get originIntro => 'Tutto si può cambiare in seguito.';
  @override
  String get scratch => 'Da zero';
  @override
  String get scratchText =>
      'Scegli la versione di Minecraft e il tipo di server. Le mod si possono aggiungere subito o più tardi.';
  @override
  String get modpack => 'Da un modpack';
  @override
  String get modpackText =>
      'Un modpack trovato su Modrinth o un file che hai già: versioni e mod già decise.';
  @override
  String get folder => 'Da una cartella';
  @override
  String get folderText => 'Un server già presente su questo PC, caricato sull\'hub così com\'è.';
  @override
  String get cancel => 'Annulla';
  @override
  String get next => 'Avanti';
  @override
  String get back => 'Indietro';
  @override
  String get adminOnly => 'Solo gli admin possono creare server.';

  @override
  String get needName => 'Scrivi un nome';
  @override
  String get needVersion => 'Scegli una versione';
  @override
  String needLoader(String loader) => '$loader non c\'è per questa versione';
  @override
  String needJava(int major) => 'Serve Java $major';
  @override
  String get needPack => 'Scegli un modpack';
  @override
  String get needFolder => 'Scegli la cartella e premi Controlla';
  @override
  String get wait => 'Attendere…';

  @override
  String get versionTitle => 'Nome e versione';
  @override
  String get minecraft => 'Minecraft';
  @override
  String latest(String v) => '$v (ultima)';
  @override
  String get popular =>
      '1.21.1 è la versione più usata per giocare con le mod: quasi tutte la supportano.';
  @override
  String get releasesOnly => 'Solo versioni stabili';
  @override
  String get memory => 'Memoria per il server';
  @override
  String gb(int n) => '$n GB';
  @override
  String get memoryHint =>
      'Consigliati 6–8 GB con le mod. Modificabile in seguito nelle Impostazioni.';
  @override
  String get loader => 'Tipo di server';
  @override
  String get vanillaTitle => 'Vanilla (senza mod)';
  @override
  String loaderText(String loader) => switch (loader) {
    'vanilla' => 'Il server originale di Mojang.',
    'fabric' => 'Leggero e veloce, moltissime mod.',
    'quilt' => 'Simile a Fabric, compatibile con quasi tutte le sue mod.',
    'neoforge' => 'Le grandi mod tecniche e di magia.',
    _ => 'Il più longevo: molte mod, anche datate.',
  };
  @override
  String recommendedVersion(String v) => 'Versione consigliata: $v.';
  @override
  String get noLoaderVersions => 'Non esiste per questa versione.';
  @override
  String get versionsError =>
      'Impossibile leggere le versioni: controlla la connessione e riprova.';
  @override
  String javaOk(int major) => 'Java $major: presente';
  @override
  String javaOkText(String mc, int major, String found) =>
      'Minecraft $mc richiede Java $major. Verrà usato $found, già presente sul PC.';
  @override
  String javaMissing(int major) => 'Manca Java $major';
  @override
  String javaMissingText(String mc, int major, String found) =>
      'Senza, il server non parte. Minecraft $mc richiede Java $major o successivo${found.isEmpty ? '' : ' (trovato: $found)'}. Installa Temurin $major (gratuito, di Eclipse Adoptium), poi premi «Cerca di nuovo».';
  @override
  String get javaHow => 'Come installare Java (Temurin)';
  @override
  String get javaRescan => 'Cerca di nuovo';
  @override
  String get javaSearching => 'Ricerca di Java…';

  @override
  String get modpackTitle => 'Da un modpack';
  @override
  String get mrpackPath => 'File .mrpack';
  @override
  String get mrpackHint => 'Il formato .mrpack è quello di Modrinth e di Prism Launcher.';
  @override
  String get open => 'Apri';
  @override
  String get base => 'Base';
  @override
  String get mods => 'Mod';
  @override
  String modsValue(int server, int client) =>
      '$server sul server${client > 0 ? ', $client solo per i giocatori' : ''}';
  @override
  String get importError => 'Impossibile aprire il modpack';

  @override
  String get folderTitle => 'Da una cartella';
  @override
  String get folderIntro =>
      'Scegli la cartella del server: il resto viene riconosciuto automaticamente.';
  @override
  String get folderPath => 'Cartella del server';
  @override
  String get check => 'Controlla';
  @override
  String get world => 'Mondo';
  @override
  String get start => 'Avvio';
  @override
  String folderMods(int n) => n == 1 ? '1 mod' : '$n mod';
  @override
  String folderCopy(String dest) =>
      'Tutto viene caricato sull\'hub. La cartella originale resta dov\'è: si lavora su una copia in $dest.';
  @override
  String get folderError => 'Cartella non trovata';
  @override
  String get profile => 'Tipo';

  @override
  String get modsTitle => 'Mod iniziali';
  @override
  String modsIntro(String loader) =>
      'Facoltativo: le mod consigliate per un server $loader. Le altre si cercano in seguito dalla scheda Mod.';
  @override
  String get fabricApi => 'Fabric API sempre inclusa';
  @override
  String get fabricApiText =>
      'Quasi tutte le mod Fabric la richiedono: viene aggiunta automaticamente, anche senza altre scelte.';
  @override
  String modHint(String slug) => switch (slug) {
    'lithium' => 'Meno carico sul server a parità di mondo',
    'ferrite-core' => 'Usa meno memoria',
    'krypton' => 'Rete più leggera con tanti giocatori',
    'chunky' => 'Genera il mondo in anticipo: nessuno scatto durante l\'esplorazione',
    _ => 'Mostra cosa rallenta il server',
  };
  @override
  String get skip => 'Salta';
  @override
  String nextMods(int n) => n == 0 ? 'Avanti' : 'Avanti ($n mod)';

  @override
  String get eulaTitle => 'L\'EULA di Minecraft';
  @override
  String eulaIntro(String name) => 'Ultimo passo prima di creare $name.';
  @override
  String get eulaText =>
      'Mojang chiede di accettare l\'EULA per ospitare un server. Vale per tutto il gruppo.';
  @override
  String get eulaRead => 'Leggi l\'EULA di Minecraft';
  @override
  String get summary => 'Riepilogo';
  @override
  String get name => 'Nome';
  @override
  String get none => 'nessuna';
  @override
  String get accept => 'Accetta e crea il server';
  @override
  String get create => 'Crea il server';

  @override
  String creating(String name) => 'Creazione di $name…';
  @override
  String get creatingText => 'Richiede un paio di minuti.';
  @override
  String task(String t) => switch (t) {
    'server' => 'Installazione del server',
    'mods' => 'Mod da Modrinth',
    'files' => 'Copia della cartella',
    'hub' => 'Server sull\'hub',
    _ => 'Primo caricamento sull\'hub',
  };
  @override
  String get failedTitle => 'Creazione non riuscita';
  @override
  String get failedText => 'Interrotto al passo segnato. Riprova riparte da lì.';
  @override
  String get nothingOnHub => 'Nessun dato parziale sull\'hub';
  @override
  String nothingOnHubText(String name) =>
      '$name non è stato creato. I file già scaricati restano: Riprova riparte da qui.';
  @override
  String get retry => 'Riprova';
  @override
  String get copyDetails => 'Copia dettagli';
  @override
  String get copied => 'Dettagli copiati';
  @override
  String readyTitle(String name) => '$name è pronto';
  @override
  String get readyText =>
      'Il server è sull\'hub e compare già nell\'elenco di tutti. Il mondo viene generato al primo Gioca.';
  @override
  String get onPc => 'Su questo PC';
  @override
  String get addMods => 'Aggiungi mod';
  @override
  String get play => 'Gioca';
  @override
  String get goToServer => 'Vai al server';
}

final class _En extends NewServerStrings {
  const _En();

  @override
  String get title => 'New server';
  @override
  String get stepsLabel => 'Steps';
  @override
  String stepOf(int position, int total) => 'step $position of $total';
  @override
  String step(String s) => switch (s) {
    'origin' => 'Origin',
    'version' => 'Version',
    'modpack' => 'Modpack',
    'folder' => 'Folder',
    'mods' => 'Mods',
    _ => 'EULA',
  };
  @override
  String get originTitle => 'Choose a starting point';
  @override
  String get originIntro => 'Everything can be changed later.';
  @override
  String get scratch => 'From scratch';
  @override
  String get scratchText =>
      'Choose the Minecraft version and the server type. Mods can be added now or later.';
  @override
  String get modpack => 'From a modpack';
  @override
  String get modpackText =>
      'A modpack from Modrinth or a file you already have: versions and mods already chosen.';
  @override
  String get folder => 'From a folder';
  @override
  String get folderText => 'A server already on this PC, uploaded to the hub as it is.';
  @override
  String get cancel => 'Cancel';
  @override
  String get next => 'Next';
  @override
  String get back => 'Back';
  @override
  String get adminOnly => 'Only admins can create servers.';

  @override
  String get needName => 'Enter a name';
  @override
  String get needVersion => 'Choose a version';
  @override
  String needLoader(String loader) => '$loader is not available for this version';
  @override
  String needJava(int major) => 'Java $major required';
  @override
  String get needPack => 'Choose a modpack';
  @override
  String get needFolder => 'Choose the folder and press Check';
  @override
  String get wait => 'Please wait…';

  @override
  String get versionTitle => 'Name and version';
  @override
  String get minecraft => 'Minecraft';
  @override
  String latest(String v) => '$v (latest)';
  @override
  String get popular =>
      '1.21.1 is the most used version for modded play: almost every mod supports it.';
  @override
  String get releasesOnly => 'Stable versions only';
  @override
  String get memory => 'Memory for the server';
  @override
  String gb(int n) => '$n GB';
  @override
  String get memoryHint => '6–8 GB recommended with mods. Can be changed later in Settings.';
  @override
  String get loader => 'Server type';
  @override
  String get vanillaTitle => 'Vanilla (no mods)';
  @override
  String loaderText(String loader) => switch (loader) {
    'vanilla' => 'The original Mojang server.',
    'fabric' => 'Light and fast, many mods.',
    'quilt' => 'Similar to Fabric, compatible with almost all of its mods.',
    'neoforge' => 'The big tech and magic mods.',
    _ => 'The longest-standing: many mods, older ones too.',
  };
  @override
  String recommendedVersion(String v) => 'Recommended version: $v.';
  @override
  String get noLoaderVersions => 'Does not exist for this version.';
  @override
  String get versionsError => 'Unable to read the versions: check the connection and try again.';
  @override
  String javaOk(int major) => 'Java $major: installed';
  @override
  String javaOkText(String mc, int major, String found) =>
      'Minecraft $mc requires Java $major. $found, already on this PC, will be used.';
  @override
  String javaMissing(int major) => 'Java $major is missing';
  @override
  String javaMissingText(String mc, int major, String found) =>
      'Without it, the server does not start. Minecraft $mc requires Java $major or newer${found.isEmpty ? '' : ' (found: $found)'}. Install Temurin $major (free, from Eclipse Adoptium), then press «Search again».';
  @override
  String get javaHow => 'How to install Java (Temurin)';
  @override
  String get javaRescan => 'Search again';
  @override
  String get javaSearching => 'Searching for Java…';

  @override
  String get modpackTitle => 'From a modpack';
  @override
  String get mrpackPath => '.mrpack file';
  @override
  String get mrpackHint => '.mrpack is the format of Modrinth and Prism Launcher.';
  @override
  String get open => 'Open';
  @override
  String get base => 'Base';
  @override
  String get mods => 'Mods';
  @override
  String modsValue(int server, int client) =>
      '$server on the server${client > 0 ? ', $client for players only' : ''}';
  @override
  String get importError => 'Unable to open the modpack';

  @override
  String get folderTitle => 'From a folder';
  @override
  String get folderIntro => 'Choose the server folder: the rest is detected automatically.';
  @override
  String get folderPath => 'Server folder';
  @override
  String get check => 'Check';
  @override
  String get world => 'World';
  @override
  String get start => 'Start';
  @override
  String folderMods(int n) => n == 1 ? '1 mod' : '$n mods';
  @override
  String folderCopy(String dest) =>
      'Everything is uploaded to the hub. The original folder stays where it is: work happens on a copy in $dest.';
  @override
  String get folderError => 'Folder not found';
  @override
  String get profile => 'Type';

  @override
  String get modsTitle => 'Starter mods';
  @override
  String modsIntro(String loader) =>
      'Optional: recommended mods for a $loader server. Find others later in the Mods tab.';
  @override
  String get fabricApi => 'Fabric API always included';
  @override
  String get fabricApiText =>
      'Almost every Fabric mod requires it: it is added automatically, even if nothing else is selected.';
  @override
  String modHint(String slug) => switch (slug) {
    'lithium' => 'Less server load for the same world',
    'ferrite-core' => 'Uses less memory',
    'krypton' => 'Lighter network with many players',
    'chunky' => 'Generates the world in advance: no stutter while exploring',
    _ => 'Shows what slows the server down',
  };
  @override
  String get skip => 'Skip';
  @override
  String nextMods(int n) => n == 0 ? 'Next' : 'Next ($n mods)';

  @override
  String get eulaTitle => 'The Minecraft EULA';
  @override
  String eulaIntro(String name) => 'Last step before creating $name.';
  @override
  String get eulaText =>
      'Mojang requires accepting the EULA to host a server. It covers the whole group.';
  @override
  String get eulaRead => 'Read the Minecraft EULA';
  @override
  String get summary => 'Summary';
  @override
  String get name => 'Name';
  @override
  String get none => 'none';
  @override
  String get accept => 'Accept and create the server';
  @override
  String get create => 'Create the server';

  @override
  String creating(String name) => 'Creating $name…';
  @override
  String get creatingText => 'This takes a couple of minutes.';
  @override
  String task(String t) => switch (t) {
    'server' => 'Server installation',
    'mods' => 'Mods from Modrinth',
    'files' => 'Copy of the folder',
    'hub' => 'Server on the hub',
    _ => 'First upload to the hub',
  };
  @override
  String get failedTitle => 'Creation failed';
  @override
  String get failedText => 'Stopped at the marked step. Try again resumes from there.';
  @override
  String get nothingOnHub => 'No partial data on the hub';
  @override
  String nothingOnHubText(String name) =>
      '$name was not created. Files already downloaded are kept: Try again resumes from here.';
  @override
  String get retry => 'Try again';
  @override
  String get copyDetails => 'Copy details';
  @override
  String get copied => 'Details copied';
  @override
  String readyTitle(String name) => '$name is ready';
  @override
  String get readyText =>
      'The server is on the hub and already appears in everyone\'s list. The world is generated at the first Play.';
  @override
  String get onPc => 'On this PC';
  @override
  String get addMods => 'Add mods';
  @override
  String get play => 'Play';
  @override
  String get goToServer => 'Go to the server';
}
