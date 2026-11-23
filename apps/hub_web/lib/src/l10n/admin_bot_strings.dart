// Testi dell'area Admin: Esclusioni predefinite e bot Telegram.
import 'package:ms_l10n/ms_l10n.dart';

abstract final class AdminBotStrings {
  const AdminBotStrings();

  static AdminBotStrings of(Lang l) => switch (l) {
    Lang.it => const _It(),
    Lang.en => const _En(),
  };

  // --- Esclusioni ----------------------------------------------------------
  String get exTitle;
  String get exLead;

  /// Sintassi: (esempio, cosa vuol dire).
  List<(String, String)> get exSyntax;
  String get profile;
  String profileCount(String name, int n);
  String get minecraft;
  String get generic;
  String get system;
  String removePattern(String p);
  String get newPattern;
  String get newPatternHint;
  String get add;
  String get duplicate;
  String get tooLong;
  String get testTitle;
  String get testHint;
  String get testPlaceholder;
  String get testButton;
  String get excluded;
  String get byRule;
  String get bySystem;
  String get goesToHub;
  String get exNote;

  // --- Telegram: stato -----------------------------------------------------
  String get pillActive;
  String get pillOff;
  String get pillIncomplete;
  String get pillError;
  String get offTitle;
  String get offText;
  String get incompleteTitle;
  String get incompleteText;
  String activeTitle(String? chat);
  String lastSent(String when, String text);
  String get noMessage;
  String get errorTitle;
  String errorText(String when, String error);
  String missingTopics(String names);

  // --- Telegram: campi -----------------------------------------------------
  String get enabled;
  String get enabledHint;
  String get token;
  String get tokenHint;
  String get tokenNone;
  String get replace;
  String get removeToken;
  String get addToken;
  String get tokenDialogTitle;
  String get tokenDialogHelp;
  String get tokenSaved;
  String get removeTitle;
  String get removeBody;
  String get removeConfirm;
  String get tokenRemoved;
  String get chat;
  String get chatHint;
  String get chatHow;
  List<String> get chatSteps;
  String get findChat;
  String get findNone;
  String get useChat;
  String chatKind(String type);
  String get language;
  String get langHub;
  String get announce;
  String get nOpen;
  String get nOpenD;
  String get nClose;
  String get nCloseD;
  String get nAlerts;
  String get nAlertsD;
  String get nStatus;
  String get nStatusD;
  String get coalesce;
  String get coalesceHint;
  String get pushWarn;
  String get pushWarnHint;
  String get topics;
  String get topicsHint;
  String get colServer;
  String get colTopic;
  String get colTest;
  String get colResult;
  String topicPlaceholder(String name);
  String testTopicFor(String name);
  String get testRow;
  String arrived(String time);
  String get mainChat;
  String get topicMissing;
  String get preview;
  String previewOpen(String name);
  String previewHost(String who, String address);
  String previewIp(String ip);
  String get sendTest;
  String testSent(String time);
  String get testFailed;
}

final class _It extends AdminBotStrings {
  const _It();
  @override
  String get exTitle => 'Esclusioni predefinite';
  @override
  String get exLead =>
      'File e cartelle mai inviati all\'hub. Valgono per tutti i server del profilo, anche '
      'quelli già creati; ogni server può aggiungerne di proprie.';
  @override
  List<(String, String)> get exSyntax => const [
    ('*', 'qualsiasi testo'),
    ('**', 'qualsiasi cartella'),
    ('logs/**', 'tutta la cartella'),
    ('*.bak', 'senza / vale a ogni livello'),
  ];
  @override
  String get profile => 'Profilo';
  @override
  String profileCount(String name, int n) => '$name ($n server)';
  @override
  String get minecraft => 'Minecraft';
  @override
  String get generic => 'Generico';
  @override
  String get system => 'di sistema';
  @override
  String removePattern(String p) => 'Rimuovi $p';
  @override
  String get newPattern => 'Nuovo pattern';
  @override
  String get newPatternHint => 'es. bluemap/** oppure *.bak';
  @override
  String get add => 'Aggiungi';
  @override
  String get duplicate => 'Pattern già presente';
  @override
  String get tooLong => 'Al massimo 256 caratteri';
  @override
  String get testTitle => 'Verifica un percorso';
  @override
  String get testHint =>
      'Inserisci un percorso del server per verificare se viene inviato all\'hub.';
  @override
  String get testPlaceholder => 'es. logs/latest.log';
  @override
  String get testButton => 'Verifica';
  @override
  String get excluded => 'Escluso';
  @override
  String get byRule => 'dalla regola';
  @override
  String get bySystem => 'regola di sistema';
  @override
  String get goesToHub => 'Inviato all\'hub';
  @override
  String get exNote =>
      'I server le ereditano: una modifica qui vale dal loro prossimo salvataggio. Le regole di '
      'sistema sono necessarie a MineSync e non si possono rimuovere.';

  @override
  String get pillActive => 'Attivo';
  @override
  String get pillOff => 'Disattivato';
  @override
  String get pillIncomplete => 'Incompleto';
  @override
  String get pillError => 'Errore';
  @override
  String get offTitle => 'Bot disattivato';
  @override
  String get offText => 'Nessun messaggio inviato. Le impostazioni restano salvate.';
  @override
  String get incompleteTitle => 'Attivo ma incompleto';
  @override
  String get incompleteText => 'Token del bot o chat mancante: nessun messaggio viene inviato.';
  @override
  String activeTitle(String? chat) => chat == null ? 'Attivo' : 'Attivo nella chat «$chat»';
  @override
  String lastSent(String when, String text) => 'Ultimo messaggio $when: «$text». Nessun errore.';
  @override
  String get noMessage => 'Nessun messaggio inviato finora.';
  @override
  String get errorTitle => 'Ultimo invio non riuscito';
  @override
  String errorText(String when, String error) => '$when: $error';
  @override
  String missingTopics(String names) =>
      'Il topic di $names non esiste più: i messaggi vanno nella chat principale.';

  @override
  String get enabled => 'Bot attivo';
  @override
  String get enabledHint =>
      'Se disattivato, nessun messaggio viene inviato e le impostazioni restano salvate.';
  @override
  String get token => 'Token del bot';
  @override
  String get tokenHint =>
      'Si crea con BotFather su Telegram. Non viene mai mostrato per intero, nemmeno agli admin.';
  @override
  String get tokenNone => 'Nessun token';
  @override
  String get replace => 'Sostituisci';
  @override
  String get removeToken => 'Rimuovi';
  @override
  String get addToken => 'Aggiungi token';
  @override
  String get tokenDialogTitle => 'Token del bot';
  @override
  String get tokenDialogHelp =>
      'Incolla il token di BotFather: un numero, due punti e una lunga sequenza di lettere. Dopo '
      'il salvataggio non viene più mostrato per intero.';
  @override
  String get tokenSaved => 'Token salvato';
  @override
  String get removeTitle => 'Rimuovere il token?';
  @override
  String get removeBody =>
      'Il bot viene disattivato e non invia messaggi finché non viene aggiunto un nuovo token.';
  @override
  String get removeConfirm => 'Rimuovi il token';
  @override
  String get tokenRemoved => 'Token rimosso, bot disattivato';
  @override
  String get chat => 'Chat';
  @override
  String get chatHint => 'ID del gruppo o del canale di destinazione.';
  @override
  String get chatHow => 'Come trovare l\'ID della chat';
  @override
  List<String> get chatSteps => const [
    '1. Aggiungi il bot al gruppo.',
    '2. Scrivi un messaggio qualsiasi nel gruppo.',
    '3. Premi «Trova chat»: l\'hub legge gli ultimi messaggi ricevuti dal bot.',
  ];
  @override
  String get findChat => 'Trova chat';
  @override
  String get findNone => 'Nessuna chat trovata. Scrivi un messaggio nel gruppo e riprova.';
  @override
  String get useChat => 'Usa questa';
  @override
  String chatKind(String type) => switch (type) {
    'group' || 'supergroup' => 'gruppo',
    'channel' => 'canale',
    'private' => 'chat privata',
    _ => type,
  };
  @override
  String get language => 'Lingua dei messaggi';
  @override
  String get langHub => 'Come l\'hub';
  @override
  String get announce => 'Cosa annunciare';
  @override
  String get nOpen => 'Server aperto';
  @override
  String get nOpenD => 'chi ospita, indirizzo fisso e IP';
  @override
  String get nClose => 'Server chiuso';
  @override
  String get nCloseD => 'durata; avviso anche se l\'app di chi ospita non risponde più';
  @override
  String get nAlerts => 'Avvisi';
  @override
  String get nAlertsD => 'un server aperto non salva da tempo, disco quasi pieno';
  @override
  String get nStatus => 'Risposta a /status';
  @override
  String get nStatusD => 'stato di tutti i server su richiesta';
  @override
  String get coalesce => 'Unisci chiusura e riapertura entro';
  @override
  String get coalesceHint => 'In caso di riavvio rapido viene inviato un solo messaggio.';
  @override
  String get pushWarn => 'Avvisa se un server aperto non salva sull\'hub da';
  @override
  String get pushWarnHint => 'Di solito indica che l\'app di chi ospita ha perso la connessione.';
  @override
  String get topics => 'Topic per server';
  @override
  String get topicsHint =>
      'In un gruppo con i topic ogni server può avere il suo thread: numero o link t.me. '
      'Vuoto = chat principale.';
  @override
  String get colServer => 'Server';
  @override
  String get colTopic => 'ID del topic';
  @override
  String get colTest => 'Verifica';
  @override
  String get colResult => 'Esito';
  @override
  String topicPlaceholder(String name) => 'Topic di $name';
  @override
  String testTopicFor(String name) => 'Verifica il topic di $name';
  @override
  String get testRow => 'Verifica';
  @override
  String arrived(String time) => 'Ricevuto alle $time';
  @override
  String get mainChat => 'chat principale';
  @override
  String get topicMissing => 'il topic non esiste più';
  @override
  String get preview => 'Anteprima del messaggio';
  @override
  String previewOpen(String name) => '$name è aperto';
  @override
  String previewHost(String who, String address) => 'Ospita $who, entra su $address';
  @override
  String previewIp(String ip) => 'IP diretto $ip';
  @override
  String get sendTest => 'Invia un messaggio di prova';
  @override
  String testSent(String time) => 'Messaggio di prova ricevuto alle $time';
  @override
  String get testFailed => 'Invio di prova non riuscito';
}

final class _En extends AdminBotStrings {
  const _En();
  @override
  String get exTitle => 'Default exclusions';
  @override
  String get exLead =>
      'Files and folders never sent to the hub. They apply to every server of the profile, '
      'existing ones included; each server can add its own.';
  @override
  List<(String, String)> get exSyntax => const [
    ('*', 'any text'),
    ('**', 'any folder'),
    ('logs/**', 'the whole folder'),
    ('*.bak', 'without / it applies at every level'),
  ];
  @override
  String get profile => 'Profile';
  @override
  String profileCount(String name, int n) => '$name ($n server${n == 1 ? '' : 's'})';
  @override
  String get minecraft => 'Minecraft';
  @override
  String get generic => 'Generic';
  @override
  String get system => 'system';
  @override
  String removePattern(String p) => 'Remove $p';
  @override
  String get newPattern => 'New pattern';
  @override
  String get newPatternHint => 'e.g. bluemap/** or *.bak';
  @override
  String get add => 'Add';
  @override
  String get duplicate => 'Pattern already present';
  @override
  String get tooLong => 'At most 256 characters';
  @override
  String get testTitle => 'Test a path';
  @override
  String get testHint => 'Enter a server path to check whether it is sent to the hub.';
  @override
  String get testPlaceholder => 'e.g. logs/latest.log';
  @override
  String get testButton => 'Test';
  @override
  String get excluded => 'Excluded';
  @override
  String get byRule => 'by the rule';
  @override
  String get bySystem => 'system rule';
  @override
  String get goesToHub => 'Sent to the hub';
  @override
  String get exNote =>
      'Servers inherit them: a change here applies from their next save. System rules are '
      'required by MineSync and cannot be removed.';

  @override
  String get pillActive => 'Active';
  @override
  String get pillOff => 'Off';
  @override
  String get pillIncomplete => 'Incomplete';
  @override
  String get pillError => 'Error';
  @override
  String get offTitle => 'Bot turned off';
  @override
  String get offText => 'No messages are sent. The settings are kept.';
  @override
  String get incompleteTitle => 'Active but incomplete';
  @override
  String get incompleteText => 'Bot token or chat missing: no messages are sent.';
  @override
  String activeTitle(String? chat) => chat == null ? 'Active' : 'Active in the chat "$chat"';
  @override
  String lastSent(String when, String text) => 'Last message $when: "$text". No errors.';
  @override
  String get noMessage => 'No message sent so far.';
  @override
  String get errorTitle => 'Last message failed';
  @override
  String errorText(String when, String error) => '$when: $error';
  @override
  String missingTopics(String names) =>
      'The topic of $names no longer exists: messages go to the main chat.';

  @override
  String get enabled => 'Bot on';
  @override
  String get enabledHint => 'When off, no messages are sent and the settings are kept.';
  @override
  String get token => 'Bot token';
  @override
  String get tokenHint =>
      'Created with BotFather on Telegram. It is never shown in full, not even to admins.';
  @override
  String get tokenNone => 'No token';
  @override
  String get replace => 'Replace';
  @override
  String get removeToken => 'Remove';
  @override
  String get addToken => 'Add token';
  @override
  String get tokenDialogTitle => 'Bot token';
  @override
  String get tokenDialogHelp =>
      'Paste the token from BotFather: a number, a colon and a long run of letters. After saving '
      'it is no longer shown in full.';
  @override
  String get tokenSaved => 'Token saved';
  @override
  String get removeTitle => 'Remove the token?';
  @override
  String get removeBody =>
      'The bot is turned off and sends no messages until a new token is added.';
  @override
  String get removeConfirm => 'Remove the token';
  @override
  String get tokenRemoved => 'Token removed, bot turned off';
  @override
  String get chat => 'Chat';
  @override
  String get chatHint => 'ID of the destination group or channel.';
  @override
  String get chatHow => 'How to find the chat ID';
  @override
  List<String> get chatSteps => const [
    '1. Add the bot to the group.',
    '2. Write any message in the group.',
    '3. Press "Find chat": the hub reads the last messages received by the bot.',
  ];
  @override
  String get findChat => 'Find chat';
  @override
  String get findNone => 'No chat found. Write a message in the group and try again.';
  @override
  String get useChat => 'Use this';
  @override
  String chatKind(String type) => switch (type) {
    'group' || 'supergroup' => 'group',
    'channel' => 'channel',
    'private' => 'private chat',
    _ => type,
  };
  @override
  String get language => 'Message language';
  @override
  String get langHub => 'Same as the hub';
  @override
  String get announce => 'What to announce';
  @override
  String get nOpen => 'Server opened';
  @override
  String get nOpenD => 'who hosts, fixed address and IP';
  @override
  String get nClose => 'Server closed';
  @override
  String get nCloseD => 'duration; also a warning if the host\'s app stops responding';
  @override
  String get nAlerts => 'Alerts';
  @override
  String get nAlertsD => 'an open server has not saved for a while, disk almost full';
  @override
  String get nStatus => 'Reply to /status';
  @override
  String get nStatusD => 'state of every server on request';
  @override
  String get coalesce => 'Merge close and reopen within';
  @override
  String get coalesceHint => 'A quick restart sends only one message.';
  @override
  String get pushWarn => 'Warn if an open server has not saved to the hub for';
  @override
  String get pushWarnHint => 'It usually means the host\'s app lost its connection.';
  @override
  String get topics => 'Topic per server';
  @override
  String get topicsHint =>
      'In a group with topics each server can have its own thread: number or t.me link. '
      'Empty = main chat.';
  @override
  String get colServer => 'Server';
  @override
  String get colTopic => 'Topic ID';
  @override
  String get colTest => 'Test';
  @override
  String get colResult => 'Result';
  @override
  String topicPlaceholder(String name) => '$name topic';
  @override
  String testTopicFor(String name) => 'Test the $name topic';
  @override
  String get testRow => 'Test';
  @override
  String arrived(String time) => 'Received at $time';
  @override
  String get mainChat => 'main chat';
  @override
  String get topicMissing => 'the topic no longer exists';
  @override
  String get preview => 'Message preview';
  @override
  String previewOpen(String name) => '$name is open';
  @override
  String previewHost(String who, String address) => 'Hosted by $who, join on $address';
  @override
  String previewIp(String ip) => 'Direct IP $ip';
  @override
  String get sendTest => 'Send a test message';
  @override
  String testSent(String time) => 'Test message received at $time';
  @override
  String get testFailed => 'Test message failed';
}
