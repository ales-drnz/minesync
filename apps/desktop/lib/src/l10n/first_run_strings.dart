// Testi del primo avvio: benvenuto, connessione all'hub, errori, pronto.
import 'package:ms_l10n/ms_l10n.dart';

import 'format_strings.dart';

abstract final class FirstRunStrings {
  static FirstRunStrings of(Lang l) => switch (l) {
    Lang.it => const _It(),
    Lang.en => const _En(),
  };

  String get feat1Title;
  String get feat2Title;
  String get feat3Title;
  String get panelLabel;
  String get stepsLabel;
  List<String> get steps;

  String get welcomeTitle;
  String get welcomeText;
  String get addressLabel;
  String get addressHintPrefilled;
  String get addressInvalid;
  String get connect;
  String get whatIsZt;
  String get ztExplain;

  String get connectingTitle;
  String get connectingText;
  String get progressLabel;
  String get checkAddress;
  String get checkReach;
  String get checkWho;
  String get connectingButton;
  String get cancel;

  String get errNotMemberTitle;
  String get errNotMemberText;
  String get errUnreachableTitle;
  String errUnreachableText(String address);
  String get errTimeoutTitle;
  String get errTimeoutText;
  String get errOtherTitle;
  String errOtherText(String message);
  String get whatToDo;
  List<Rich> get todo;
  String get untouched;
  String get retry;
  String get changeAddress;
  String get copyDetails;
  String get copied;
  String get otherReasons;
  List<Rich> get reasons;

  String get connected;
  String hello(String name);
  Rich youAre(String hub, bool admin);
  String waiting(int servers);
  String get worldsLabel;
  String worldsHint(String? free);
  String get autostart;
  String get autostartText;
  String get start;
  String get footer;
}

final class _It implements FirstRunStrings {
  const _It();
  @override
  String get feat1Title => 'Uno ospita, gli altri entrano.';
  @override
  String get feat2Title => 'Il mondo si salva in automatico.';
  @override
  String get feat3Title => 'Accesso tramite ZeroTier, senza password.';
  @override
  String get panelLabel => 'Connessione all\'hub';
  @override
  String get stepsLabel => 'Passi';
  @override
  List<String> get steps => const ['Hub', 'Rete', 'Pronto'];

  @override
  String get welcomeTitle => 'Benvenuto';
  @override
  String get welcomeText => 'Inserisci l\'indirizzo fornito dall\'admin.';
  @override
  String get addressLabel => 'Indirizzo dell\'hub';
  @override
  String get addressHintPrefilled =>
      'Già inserito dal pacchetto ricevuto. Modificalo solo su indicazione di chi gestisce l\'hub.';
  @override
  String get addressInvalid => 'Indirizzo non valido. Formato atteso: 192.0.2.10:8084.';
  @override
  String get connect => 'Connetti';
  @override
  String get whatIsZt => 'Cos\'è ZeroTier?';
  @override
  String get ztExplain =>
      'ZeroTier è la rete privata del gruppo: collega i PC come se fossero nella stessa rete '
      'locale. Deve essere installato e attivo su ogni PC che gioca.';

  @override
  String get connectingTitle => 'Connessione in corso…';
  @override
  String get connectingText => 'Di solito richiede pochi secondi.';
  @override
  String get progressLabel => 'Connessione in corso';
  @override
  String get checkAddress => 'Indirizzo valido';
  @override
  String get checkReach => 'Contatto con l\'hub…';
  @override
  String get checkWho => 'Identificazione tramite la rete ZeroTier';
  @override
  String get connectingButton => 'Connessione…';
  @override
  String get cancel => 'Annulla';

  @override
  String get errNotMemberTitle => 'PC non presente nella rete ZeroTier';
  @override
  String get errNotMemberText =>
      'L\'hub ha risposto ma non riconosce questo PC. MineSync identifica gli utenti tramite la '
      'rete ZeroTier: questo PC non è collegato o non è ancora approvato.';
  @override
  String get errUnreachableTitle => 'Hub non raggiungibile';
  @override
  String errUnreachableText(String address) =>
      'Nessuna risposta da $address: l\'hub è spento, l\'indirizzo è errato o ZeroTier non è '
      'attivo.';
  @override
  String get errTimeoutTitle => 'Tempo scaduto';
  @override
  String get errTimeoutText =>
      'L\'hub non ha risposto in tempo: la rete è lenta. Riprova tra qualche istante.';
  @override
  String get errOtherTitle => 'Errore imprevisto';
  @override
  String errOtherText(String message) => 'Risposta inattesa dall\'hub: $message';
  @override
  String get whatToDo => 'Cosa fare';
  @override
  List<Rich> get todo => const [
    [('Apri ZeroTier e controlla che la rete del gruppo sia ', false), ('connessa', true)],
    [('Al primo accesso, chiedi a chi gestisce la rete di ', false), ('approvarti', true)],
    [('Premi ', false), ('Riprova', true)],
  ];
  @override
  String get untouched => 'Nessuna modifica su questo PC.';
  @override
  String get retry => 'Riprova';
  @override
  String get changeAddress => 'Cambia indirizzo';
  @override
  String get copyDetails => 'Copia dettagli';
  @override
  String get copied => 'Dettagli copiati negli appunti';
  @override
  String get otherReasons => 'Altri motivi possibili';
  @override
  List<Rich> get reasons => const [
    [('Hub non raggiungibile', true), (': l\'hub è spento o l\'indirizzo è errato.', false)],
    [('Tempo scaduto', true), (': la rete è lenta. Riprova tra qualche istante.', false)],
    [('Fuori dalla rete', true), (': ZeroTier è spento o il PC non è ancora approvato.', false)],
  ];

  @override
  String get connected => 'Connesso';
  @override
  String hello(String name) => 'Ciao, $name';
  @override
  Rich youAre(String hub, bool admin) => [
    ('Connesso a ', false),
    (hub, true),
    (admin ? ' come admin.' : ' come membro.', false),
  ];
  @override
  String waiting(int servers) => switch (servers) {
    0 => 'Ancora nessun server. Compariranno qui.',
    1 => '1 server disponibile',
    _ => '$servers server disponibili',
  };
  @override
  String get worldsLabel => 'Cartella dei mondi su questo PC';
  @override
  String worldsHint(String? free) => free == null
      ? 'Puoi cambiarla per ogni server.'
      : 'Spazio libero: $free. Puoi cambiarla per ogni server.';
  @override
  String get autostart => 'Avvia MineSync con il computer';
  @override
  String get autostartText => 'gli aggiornamenti sono già scaricati al momento di giocare';
  @override
  String get start => 'Inizia';
  @override
  String get footer => 'L\'hub si può cambiare in qualsiasi momento da Impostazioni.';
}

final class _En implements FirstRunStrings {
  const _En();
  @override
  String get feat1Title => 'One hosts, the others join.';
  @override
  String get feat2Title => 'The world is saved automatically.';
  @override
  String get feat3Title => 'Sign-in through ZeroTier, no password.';
  @override
  String get panelLabel => 'Connect to the hub';
  @override
  String get stepsLabel => 'Steps';
  @override
  List<String> get steps => const ['Hub', 'Network', 'Ready'];

  @override
  String get welcomeTitle => 'Welcome';
  @override
  String get welcomeText => 'Enter the address provided by your admin.';
  @override
  String get addressLabel => 'Hub address';
  @override
  String get addressHintPrefilled =>
      'Already filled in from the package you received. Change it only if the hub admin asks.';
  @override
  String get addressInvalid => 'Invalid address. Expected format: 192.0.2.10:8084.';
  @override
  String get connect => 'Connect';
  @override
  String get whatIsZt => 'What is ZeroTier?';
  @override
  String get ztExplain =>
      'ZeroTier is the group\'s private network: it connects the PCs as if they were on the same '
      'local network. It must be installed and running on every PC that plays.';

  @override
  String get connectingTitle => 'Connecting…';
  @override
  String get connectingText => 'This usually takes a few seconds.';
  @override
  String get progressLabel => 'Connecting';
  @override
  String get checkAddress => 'Valid address';
  @override
  String get checkReach => 'Contacting the hub…';
  @override
  String get checkWho => 'Identifying through the ZeroTier network';
  @override
  String get connectingButton => 'Connecting…';
  @override
  String get cancel => 'Cancel';

  @override
  String get errNotMemberTitle => 'PC not on the ZeroTier network';
  @override
  String get errNotMemberText =>
      'The hub responded but does not recognise this PC. MineSync identifies users through the '
      'ZeroTier network: this PC is not joined or not approved yet.';
  @override
  String get errUnreachableTitle => 'Hub unreachable';
  @override
  String errUnreachableText(String address) =>
      'No response from $address: the hub is off, the address is wrong or ZeroTier is not running.';
  @override
  String get errTimeoutTitle => 'Timed out';
  @override
  String get errTimeoutText =>
      'The hub did not respond in time: the network is slow. Try again shortly.';
  @override
  String get errOtherTitle => 'Unexpected error';
  @override
  String errOtherText(String message) => 'Unexpected response from the hub: $message';
  @override
  String get whatToDo => 'What to do';
  @override
  List<Rich> get todo => const [
    [('Open ZeroTier and check that the group\'s network is ', false), ('connected', true)],
    [('On first use, ask the network admin to ', false), ('approve you', true)],
    [('Press ', false), ('Try again', true)],
  ];
  @override
  String get untouched => 'No changes were made on this PC.';
  @override
  String get retry => 'Try again';
  @override
  String get changeAddress => 'Change address';
  @override
  String get copyDetails => 'Copy details';
  @override
  String get copied => 'Details copied to the clipboard';
  @override
  String get otherReasons => 'Other possible reasons';
  @override
  List<Rich> get reasons => const [
    [('Hub unreachable', true), (': the hub is off or the address is wrong.', false)],
    [('Timed out', true), (': the network is slow. Try again shortly.', false)],
    [('Not on the network', true), (': ZeroTier is off or this PC is not approved yet.', false)],
  ];

  @override
  String get connected => 'Connected';
  @override
  String hello(String name) => 'Hi, $name';
  @override
  Rich youAre(String hub, bool admin) => [
    ('Connected to ', false),
    (hub, true),
    (admin ? ' as an admin.' : ' as a member.', false),
  ];
  @override
  String waiting(int servers) => switch (servers) {
    0 => 'No servers yet. They will appear here.',
    1 => '1 server available',
    _ => '$servers servers available',
  };
  @override
  String get worldsLabel => 'Worlds folder on this PC';
  @override
  String worldsHint(String? free) => free == null
      ? 'You can change it for each server.'
      : 'Free space: $free. You can change it for each server.';
  @override
  String get autostart => 'Start MineSync with the computer';
  @override
  String get autostartText => 'updates are already downloaded when it is time to play';
  @override
  String get start => 'Start';
  @override
  String get footer => 'The hub can be changed at any time from Settings.';
}
