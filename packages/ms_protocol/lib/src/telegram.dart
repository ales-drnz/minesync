// Bot Telegram: impostazioni e stato. Il token non esce mai dall'hub: le
// risposte hanno solo tokenSet e tokenHint (B-TG-28).
import 'json.dart';
import 'models.dart' show integer, obj, str, strings;

/// Lingua dei messaggi del bot: `hub` segue Admin › Generale.
const List<String> telegramLanguages = ['hub', 'it', 'en'];

enum TelegramState {
  /// Spento dall'admin.
  disabled,

  /// Acceso ma senza token o chat: non invia nulla.
  incomplete,
  active,

  /// Acceso, ma l'ultimo invio è fallito.
  error;

  static TelegramState parse(Object? v) => enumOf(values, v, 'stato del bot');
}

/// Cosa annunciare.
final class TelegramNotify {
  const TelegramNotify({
    this.open = true,
    this.close = true,
    this.alerts = true,
    this.status = true,
  });

  factory TelegramNotify.fromJson(Object? j) {
    final m = obj(j, 'notify');
    return TelegramNotify(
      open: boolean(m, 'open'),
      close: boolean(m, 'close'),
      alerts: boolean(m, 'alerts'),
      status: boolean(m, 'status'),
    );
  }

  /// Server aperto.
  final bool open;

  /// Server chiuso (anche «non risponde»).
  final bool close;

  /// Nessun salvataggio da troppo, disco quasi pieno.
  final bool alerts;

  /// Risponde a /status (solo così il bot legge gli aggiornamenti).
  final bool status;

  Map<String, Object?> toJson() => {
    'open': open,
    'close': close,
    'alerts': alerts,
    'status': status,
  };
}

/// Impostazioni salvate, come le restituisce l'hub (senza token).
final class TelegramSettings {
  const TelegramSettings({
    this.enabled = false,
    this.tokenSet = false,
    this.tokenHint,
    this.chat,
    this.language = 'hub',
    this.notify = const TelegramNotify(),
    this.coalesceMinutes = 1,
    this.pushWarnMinutes = 30,
    this.topics = const {},
  });

  factory TelegramSettings.fromJson(Object? j) {
    final m = obj(j, 'telegram');
    return TelegramSettings(
      enabled: boolean(m, 'enabled'),
      tokenSet: boolean(m, 'tokenSet'),
      tokenHint: optStr(m, 'tokenHint'),
      chat: optStr(m, 'chat'),
      language: str(m, 'language'),
      notify: TelegramNotify.fromJson(m['notify']),
      coalesceMinutes: integer(m, 'coalesceMinutes'),
      pushWarnMinutes: integer(m, 'pushWarnMinutes'),
      topics: intMap(m, 'topics'),
    );
  }

  final bool enabled;
  final bool tokenSet;

  /// Ultimi 4 caratteri del token.
  final String? tokenHint;

  /// `-100…`, cifre o `@canale`, come stringa.
  final String? chat;
  final String language;
  final TelegramNotify notify;

  /// Chiusura e riapertura dello stesso host entro questi minuti = nessun
  /// messaggio (0–60).
  final int coalesceMinutes;

  /// Avviso se un server aperto non salva da tanti minuti (5–1440).
  final int pushWarnMinutes;

  /// Id dello spazio → thread (sempre > 1). Senza voce = chat principale.
  final Map<String, int> topics;

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'tokenSet': tokenSet,
    if (tokenHint != null) 'tokenHint': tokenHint,
    if (chat != null) 'chat': chat,
    'language': language,
    'notify': notify.toJson(),
    'coalesceMinutes': coalesceMinutes,
    'pushWarnMinutes': pushWarnMinutes,
    'topics': topics,
  };
}

/// `GET /telegram` e risposta di `PATCH /telegram`.
final class TelegramStatus {
  const TelegramStatus({
    required this.settings,
    required this.state,
    this.chatTitle,
    this.botUsername,
    this.lastSentAt,
    this.lastSent,
    this.lastError,
    this.lastErrorAt,
    this.missingTopics = const [],
  });

  factory TelegramStatus.fromJson(Object? j) {
    final m = obj(j, 'telegram');
    return TelegramStatus(
      settings: TelegramSettings.fromJson(m['settings']),
      state: TelegramState.parse(m['state']),
      chatTitle: optStr(m, 'chatTitle'),
      botUsername: optStr(m, 'botUsername'),
      lastSentAt: optInt(m, 'lastSentAt'),
      lastSent: optStr(m, 'lastSent'),
      lastError: optStr(m, 'lastError'),
      lastErrorAt: optInt(m, 'lastErrorAt'),
      missingTopics: strings(m, 'missingTopics'),
    );
  }

  final TelegramSettings settings;
  final TelegramState state;

  /// Titolo della chat (getChat), se noto.
  final String? chatTitle;
  final String? botUsername;

  /// Ultimo messaggio inviato: quando e la prima riga.
  final int? lastSentAt;
  final String? lastSent;

  /// Ultimo errore di Telegram, testo dell'API (mai il token).
  final String? lastError;
  final int? lastErrorAt;

  /// Spazi il cui topic non esiste più (B-TG-21).
  final List<String> missingTopics;

  Map<String, Object?> toJson() => {
    'settings': settings.toJson(),
    'state': state.name,
    if (chatTitle != null) 'chatTitle': chatTitle,
    if (botUsername != null) 'botUsername': botUsername,
    if (lastSentAt != null) 'lastSentAt': lastSentAt,
    if (lastSent != null) 'lastSent': lastSent,
    if (lastError != null) 'lastError': lastError,
    if (lastErrorAt != null) 'lastErrorAt': lastErrorAt,
    if (missingTopics.isNotEmpty) 'missingTopics': missingTopics,
  };
}

/// Corpo di `PATCH /telegram`: solo i campi presenti cambiano.
final class TelegramPatch {
  const TelegramPatch({
    this.enabled,
    this.token,
    this.removeToken = false,
    this.chat,
    this.language,
    this.notify,
    this.coalesceMinutes,
    this.pushWarnMinutes,
    this.topics,
  });

  final bool? enabled;

  /// Nuovo token; null o vuoto = invariato.
  final String? token;

  /// Toglie il token (rifiutato se il bot resta acceso).
  final bool removeToken;
  final String? chat;
  final String? language;
  final TelegramNotify? notify;
  final int? coalesceMinutes;
  final int? pushWarnMinutes;

  /// Id dello spazio → numero di thread o link `t.me/…` (B-TG-26); `""` o
  /// `"1"` = chat principale. Se presente sostituisce tutta la mappa.
  final Map<String, String>? topics;

  Map<String, Object?> toJson() => {
    'enabled': ?enabled,
    if (token != null && token!.isNotEmpty) 'token': token,
    if (removeToken) 'removeToken': true,
    'chat': ?chat,
    'language': ?language,
    if (notify != null) 'notify': notify!.toJson(),
    'coalesceMinutes': ?coalesceMinutes,
    'pushWarnMinutes': ?pushWarnMinutes,
    'topics': ?topics,
  };
}

/// Risposta di `POST /telegram/test`.
final class TelegramTestResult {
  const TelegramTestResult({required this.sentAt, required this.chat, this.thread});

  factory TelegramTestResult.fromJson(Object? j) {
    final m = obj(j, 'test');
    return TelegramTestResult(
      sentAt: integer(m, 'sentAt'),
      chat: str(m, 'chat'),
      thread: optInt(m, 'thread'),
    );
  }

  final int sentAt;
  final String chat;
  final int? thread;

  Map<String, Object?> toJson() => {
    'sentAt': sentAt,
    'chat': chat,
    if (thread != null) 'thread': thread,
  };
}

/// Una chat vista negli ultimi aggiornamenti del bot («Trova chat»).
final class TelegramChat {
  const TelegramChat({required this.id, required this.type, this.title, this.thread});

  factory TelegramChat.fromJson(Object? j) {
    final m = obj(j, 'chat');
    return TelegramChat(
      id: str(m, 'id'),
      type: str(m, 'type'),
      title: optStr(m, 'title'),
      thread: optInt(m, 'thread'),
    );
  }

  /// Id come stringa (es. `-100…`).
  final String id;

  /// `group`, `supergroup`, `channel`, `private`.
  final String type;
  final String? title;

  /// Thread del messaggio, se scritto in un topic.
  final int? thread;

  Map<String, Object?> toJson() => {
    'id': id,
    'type': type,
    if (title != null) 'title': title,
    if (thread != null) 'thread': thread,
  };
}
