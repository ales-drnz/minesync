// Testi della card «Pacchetto per i giocatori» nella scheda Mod del server:
// download del .mrpack e delle sole mod, istruzioni per l'app, Prism e il
// launcher ufficiale, server vanilla, mod da scaricare a mano, lato di ogni
// mod.
import 'package:ms_l10n/ms_l10n.dart';

abstract final class PackStrings {
  const PackStrings();

  static PackStrings of(Lang l) => switch (l) {
    Lang.it => const _It(),
    Lang.en => const _En(),
  };

  String get title;
  String intro(String server, String loader, String mc, int mods);
  String updated(int n);
  String download(String file);
  String mrpackHint(String size);
  String modsZip(String size);
  String get withApp;
  String get recommended;
  String withAppText(String server);
  String get withPrism;
  String get prism1;
  String get prism2;
  String prism3(String address);
  String get withOfficial;
  String official1(String loader, String mc);
  String get official2;
  String get official3;
  String get youLaunch;
  String get youLaunchText;
  String get noPackTitle;
  String vanillaText(String server, String mc, String address);
  String get notManagedText;
  String get copyAddress;
  String missingTitle(int n);
  String missingText(String names);
  String openPage(String name);
  String get adminNote;
  String get loadError;
  String side(String side);
  String get optional;
  String get disabled;
  String get manual;
}

final class _It extends PackStrings {
  const _It();

  @override
  String get title => 'Pacchetto per i giocatori';
  @override
  String intro(String server, String loader, String mc, int mods) =>
      'Per entrare in $server servono $loader per Minecraft $mc e ${mods == 1 ? 'la mod' : 'le $mods mod'} lato giocatore.';
  @override
  String updated(int n) => 'Aggiornato alla versione $n';
  @override
  String download(String file) => 'Scarica $file';
  @override
  String mrpackHint(String size) => 'Per Prism Launcher ($size)';
  @override
  String modsZip(String size) => 'Solo le mod (.zip, $size)';
  @override
  String get withApp => 'Con l\'app MineSync';
  @override
  String get recommended => 'consigliato';
  @override
  String withAppText(String server) =>
      'Apri $server nell\'app › Mod › Pacchetto per i giocatori: Prism o il launcher ufficiale vengono preparati con un clic. L\'app segnala ogni nuova versione.';
  @override
  String get withPrism => 'Con Prism Launcher';
  @override
  String get prism1 => 'Scarica il file .mrpack qui sopra.';
  @override
  String get prism2 =>
      'In Prism: Aggiungi istanza › Importa e scegli il file, o trascinalo nella finestra.';
  @override
  String prism3(String address) => 'Avvia l\'istanza ed entra su $address.';
  @override
  String get withOfficial => 'Con il launcher ufficiale';
  @override
  String official1(String loader, String mc) => 'Installa $loader per Minecraft $mc dal suo sito.';
  @override
  String get official2 => 'Scarica solo le mod (.zip) e mettile nella cartella mods.';
  @override
  String get official3 => 'Avvia il profilo del loader ed entra.';
  @override
  String get youLaunch => 'Avvio di Minecraft';
  @override
  String get youLaunchText =>
      'Minecraft si avvia dal launcher con il proprio account Microsoft. L\'hub e l\'app MineSync preparano solo la versione giusta.';
  @override
  String get noPackTitle => 'Nessun pacchetto da scaricare';
  @override
  String vanillaText(String server, String mc, String address) =>
      '$server è vanilla: apri Minecraft $mc da qualsiasi launcher ed entra su $address.';
  @override
  String get notManagedText =>
      'Le mod di questo server non sono ancora gestite dall\'app. Un admin deve aprire la scheda Mod nell\'app MineSync e applicare una volta.';
  @override
  String get copyAddress => 'Copia indirizzo';
  @override
  String missingTitle(int n) => n == 1 ? '1 mod non è nel file' : '$n mod non sono nel file';
  @override
  String missingText(String names) =>
      '$names: l\'autore non consente il download da altre app. Scaricala dalla sua pagina e copiala nella cartella mods.';
  @override
  String openPage(String name) => 'Pagina di $name';
  @override
  String get adminNote =>
      'Le mod si modificano dalla scheda Mod dell\'app MineSync. Qui sono in sola lettura, con il pacchetto da scaricare.';
  @override
  String get loadError => 'Impossibile leggere il pacchetto.';
  @override
  String side(String side) => switch (side) {
    'client' => 'client',
    'server' => 'server',
    _ => 'client e server',
  };
  @override
  String get optional => 'facoltativa per i giocatori';
  @override
  String get disabled => 'disattivata';
  @override
  String get manual => 'aggiunta a mano';
}

final class _En extends PackStrings {
  const _En();

  @override
  String get title => 'Players pack';
  @override
  String intro(String server, String loader, String mc, int mods) =>
      'Joining $server requires $loader for Minecraft $mc and ${mods == 1 ? 'the player-side mod' : 'the $mods player-side mods'}.';
  @override
  String updated(int n) => 'Up to date with version $n';
  @override
  String download(String file) => 'Download $file';
  @override
  String mrpackHint(String size) => 'For Prism Launcher ($size)';
  @override
  String modsZip(String size) => 'Mods only (.zip, $size)';
  @override
  String get withApp => 'With the MineSync app';
  @override
  String get recommended => 'recommended';
  @override
  String withAppText(String server) =>
      'Open $server in the app › Mods › Players pack: Prism or the official launcher is set up in one click. The app reports every new version.';
  @override
  String get withPrism => 'With Prism Launcher';
  @override
  String get prism1 => 'Download the .mrpack file above.';
  @override
  String get prism2 =>
      'In Prism: Add instance › Import and pick the file, or drag it into the window.';
  @override
  String prism3(String address) => 'Start the instance and join $address.';
  @override
  String get withOfficial => 'With the official launcher';
  @override
  String official1(String loader, String mc) =>
      'Install $loader for Minecraft $mc from its website.';
  @override
  String get official2 => 'Download the mods only (.zip) and put them in the mods folder.';
  @override
  String get official3 => 'Start the loader profile and join.';
  @override
  String get youLaunch => 'Starting Minecraft';
  @override
  String get youLaunchText =>
      'Minecraft is started from the launcher with your own Microsoft account. The hub and the MineSync app only prepare the right version.';
  @override
  String get noPackTitle => 'No pack to download';
  @override
  String vanillaText(String server, String mc, String address) =>
      '$server is vanilla: open Minecraft $mc from any launcher and join $address.';
  @override
  String get notManagedText =>
      'The mods of this server are not managed by the app yet. An admin needs to open the Mods tab in the MineSync app and apply once.';
  @override
  String get copyAddress => 'Copy address';
  @override
  String missingTitle(int n) => n == 1 ? '1 mod is not in the file' : '$n mods are not in the file';
  @override
  String missingText(String names) =>
      '$names: the author does not allow downloads from other apps. Download it from its page and copy it to the mods folder.';
  @override
  String openPage(String name) => '$name page';
  @override
  String get adminNote =>
      'Mods are changed from the Mods tab of the MineSync app. Here they are read-only, with the pack to download.';
  @override
  String get loadError => 'Unable to read the pack.';
  @override
  String side(String side) => switch (side) {
    'client' => 'client',
    'server' => 'server',
    _ => 'client and server',
  };
  @override
  String get optional => 'optional for players';
  @override
  String get disabled => 'off';
  @override
  String get manual => 'added by hand';
}
