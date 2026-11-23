// Configurazione del bot Telegram: il documento salvato in telegram.json
// (token compreso, permessi 0600), la validazione di PATCH /telegram e la
// lettura dei topic (numeri o link t.me, B-TG-26).
import 'package:ms_protocol/ms_protocol.dart';

import '../jsonfile.dart';
import '../mutex.dart';

final _reToken = RegExp(r'^\d+:[A-Za-z0-9_-]{30,}$');
final _reChat = RegExp(r'^(-100\d{1,20}|\d{1,20}|@[A-Za-z][A-Za-z0-9_]{3,31})$');

/// Token nel formato di @BotFather.
bool validToken(String s) => _reToken.hasMatch(s);

/// Chat: `-100…` (supergruppo o canale), cifre, `@canale`.
bool validChat(String s) => _reChat.hasMatch(s);

/// Configurazione completa del bot, token compreso. Immutabile.
final class TelegramConfig {
  const TelegramConfig({
    this.enabled = false,
    this.token,
    this.chat,
    this.language = 'hub',
    this.notify = const TelegramNotify(),
    this.coalesceMinutes = 1,
    this.pushWarnMinutes = 30,
    this.topics = const {},
  });

  /// Dal file: campi mancanti ai valori predefiniti (B-TG-23), valori
  /// estranei ignorati.
  factory TelegramConfig.fromJson(Object? j) {
    if (j is! Map<String, Object?>) return const TelegramConfig();
    bool flag(Map<String, Object?> m, String k) => m[k] is bool ? m[k]! as bool : true;
    String? s(String k) => j[k] is String && (j[k]! as String).isNotEmpty ? j[k]! as String : null;
    int n(String k, int d, int lo, int hi) =>
        j[k] is int && (j[k]! as int) >= lo && (j[k]! as int) <= hi ? j[k]! as int : d;
    final nt = j['notify'] is Map<String, Object?>
        ? j['notify']! as Map<String, Object?>
        : const <String, Object?>{};
    final tp = j['topics'] is Map<String, Object?>
        ? j['topics']! as Map<String, Object?>
        : const <String, Object?>{};
    final lang = s('language');
    return TelegramConfig(
      enabled: j['enabled'] == true,
      token: s('token'),
      chat: s('chat'),
      language: lang != null && telegramLanguages.contains(lang) ? lang : 'hub',
      notify: TelegramNotify(
        open: flag(nt, 'open'),
        close: flag(nt, 'close'),
        alerts: flag(nt, 'alerts'),
        status: flag(nt, 'status'),
      ),
      coalesceMinutes: n('coalesceMinutes', 1, 0, 60),
      pushWarnMinutes: n('pushWarnMinutes', 30, 5, 1440),
      topics: Map.unmodifiable({
        for (final e in tp.entries)
          if (e.value is int && (e.value! as int) > 1) e.key: e.value! as int,
      }),
    );
  }

  final bool enabled;
  final String? token;
  final String? chat;

  /// `hub`, `it` o `en`.
  final String language;
  final TelegramNotify notify;
  final int coalesceMinutes;
  final int pushWarnMinutes;

  /// Spazio → thread (> 1).
  final Map<String, int> topics;

  /// Il bot può davvero inviare (B-TG-07).
  bool get active => enabled && token != null && chat != null;

  /// Thread dello spazio; null = chat principale (B-TG-19).
  int? topicOf(String space) {
    final t = topics[space];
    return t != null && t > 1 ? t : null;
  }

  TelegramConfig copyWith({
    bool? enabled,
    String? Function()? token,
    String? Function()? chat,
    String? language,
    TelegramNotify? notify,
    int? coalesceMinutes,
    int? pushWarnMinutes,
    Map<String, int>? topics,
  }) => TelegramConfig(
    enabled: enabled ?? this.enabled,
    token: token == null ? this.token : token(),
    chat: chat == null ? this.chat : chat(),
    language: language ?? this.language,
    notify: notify ?? this.notify,
    coalesceMinutes: coalesceMinutes ?? this.coalesceMinutes,
    pushWarnMinutes: pushWarnMinutes ?? this.pushWarnMinutes,
    topics: Map.unmodifiable(topics ?? this.topics),
  );

  /// Forma su disco (con il token).
  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'token': ?token,
    'chat': ?chat,
    'language': language,
    'notify': notify.toJson(),
    'coalesceMinutes': coalesceMinutes,
    'pushWarnMinutes': pushWarnMinutes,
    'topics': topics,
  };

  /// Vista pubblica (senza token, B-TG-28); [spaces] filtra i topic degli
  /// spazi che non esistono più.
  TelegramSettings view({Set<String>? spaces}) => TelegramSettings(
    enabled: enabled,
    tokenSet: token != null,
    tokenHint: token == null || token!.length < 4 ? null : token!.substring(token!.length - 4),
    chat: chat,
    language: language,
    notify: notify,
    coalesceMinutes: coalesceMinutes,
    pushWarnMinutes: pushWarnMinutes,
    topics: {
      for (final e in topics.entries)
        if (spaces == null || spaces.contains(e.key)) e.key: e.value,
    },
  );
}

// ---------------------------------------------------------------- topic

/// Topic non valido; con [linkChat] il link è di un'altra chat.
final class TopicError implements Exception {
  const TopicError([this.linkChat]);
  final String? linkChat;

  @override
  String toString() =>
      linkChat == null ? 'invalid topic' : 'the topic link belongs to chat $linkChat';
}

final _reTopicPrivate = RegExp(
  r'^(?:https?://)?(?:t|telegram)\.me/c/(\d{1,20})/(\d{1,20})(?:/\d{1,20})?/?$',
  caseSensitive: false,
);
final _reTopicPublic = RegExp(
  r'^(?:https?://)?(?:t|telegram)\.me/([A-Za-z][A-Za-z0-9_]{3,31})/(\d{1,20})(?:/\d{1,20})?/?$',
  caseSensitive: false,
);
final _reDigits = RegExp(r'^\d{1,20}$');

/// Legge un topic (B-TG-26): vuoto o `1` = chat principale (null); numero
/// intero > 1; link `t.me/c/<chat>/<thread>[/<msg>]` o
/// `t.me/<username>/<thread>[/<msg>]` (anche `telegram.me`, con query).
/// Lancia [TopicError] se non valido o, quando [chat] è confrontabile, se il
/// link è di un'altra chat.
int? parseTopic(String raw, String? chat) {
  var v = raw.trim();
  final q = v.indexOf(RegExp('[?#]'));
  if (q >= 0) v = v.substring(0, q);
  if (v.isEmpty) return null;
  String num;
  RegExpMatch? m;
  if (_reDigits.hasMatch(v)) {
    num = v;
  } else if ((m = _reTopicPrivate.firstMatch(v)) != null) {
    final link = '-100${m![1]}';
    num = m[2]!;
    if (chat != null && chat.startsWith('-100') && chat != link) throw TopicError(link);
  } else if ((m = _reTopicPublic.firstMatch(v)) != null) {
    final user = m![1]!;
    if (user.toLowerCase() == 'c' || user.toLowerCase() == 's') throw const TopicError();
    num = m[2]!;
    final link = '@$user';
    if (chat != null && chat.startsWith('@') && chat.toLowerCase() != link.toLowerCase()) {
      throw TopicError(link);
    }
  } else {
    throw const TopicError();
  }
  final n = int.tryParse(num);
  if (n == null || n <= 0) throw const TopicError();
  return n == 1 ? null : n;
}

// ---------------------------------------------------------------- patch

ApiError _bad(String field, String message) =>
    ApiError(ErrorCode.badRequest, message, details: {'field': field});

/// Applica il corpo di `PATCH /telegram` a [cur] (B-TG-24/28/30). Restituisce
/// la nuova configurazione e i nomi dei campi cambiati. Lancia [ApiError]
/// `bad_request` con `details.field`; [cur] non cambia mai.
(TelegramConfig, List<String>) applyPatch(
  TelegramConfig cur,
  Map<String, Object?> b, {
  required Set<String> spaces,
}) {
  const known = {
    'enabled',
    'token',
    'removeToken',
    'chat',
    'language',
    'notify',
    'coalesceMinutes',
    'pushWarnMinutes',
    'topics',
  };
  for (final k in b.keys) {
    if (!known.contains(k)) throw _bad(k, 'unknown field $k');
  }
  final changed = <String>[];
  var enabled = cur.enabled;
  if (b.containsKey('enabled')) {
    final v = b['enabled'];
    if (v is! bool) throw _bad('enabled', 'enabled: expected a boolean');
    enabled = v;
  }
  var token = cur.token;
  final remove = b['removeToken'];
  if (remove != null && remove is! bool) {
    throw _bad('removeToken', 'removeToken: expected a boolean');
  }
  final t = b['token'];
  if (t != null) {
    if (t is! String) throw _bad('token', 'token: expected a string');
    final ts = t.trim();
    if (ts.isNotEmpty) {
      if (!validToken(ts)) {
        throw _bad('token', 'invalid bot token (format 123456789:ABC…, from @BotFather)');
      }
      token = ts;
    }
  }
  if (remove == true) token = null;
  var chat = cur.chat;
  if (b.containsKey('chat')) {
    final c = b['chat'];
    if (c != null && c is! String) throw _bad('chat', 'chat: expected a string');
    final cs = (c as String? ?? '').trim();
    if (cs.isEmpty) {
      chat = null;
    } else if (!validChat(cs)) {
      throw _bad('chat', 'invalid chat id (e.g. -1001234567890 or @channel)');
    } else {
      chat = cs;
    }
  }
  var language = cur.language;
  if (b.containsKey('language')) {
    final l = b['language'];
    if (l is! String || !telegramLanguages.contains(l)) {
      throw _bad('language', 'language: expected one of ${telegramLanguages.join(', ')}');
    }
    language = l;
  }
  var notify = cur.notify;
  if (b.containsKey('notify')) {
    final n = b['notify'];
    if (n is! Map<String, Object?>) throw _bad('notify', 'notify: expected an object');
    bool f(String k, bool d) {
      if (!n.containsKey(k)) return d;
      final v = n[k];
      if (v is! bool) throw _bad('notify.$k', 'notify.$k: expected a boolean');
      return v;
    }

    for (final k in n.keys) {
      if (!const {'open', 'close', 'alerts', 'status'}.contains(k)) {
        throw _bad('notify.$k', 'unknown field notify.$k');
      }
    }
    notify = TelegramNotify(
      open: f('open', notify.open),
      close: f('close', notify.close),
      alerts: f('alerts', notify.alerts),
      status: f('status', notify.status),
    );
  }
  int range(String k, int d, int lo, int hi) {
    if (!b.containsKey(k)) return d;
    final v = b[k];
    if (v is! int || v < lo || v > hi) throw _bad(k, '$k: expected an integer $lo–$hi');
    return v;
  }

  final coalesce = range('coalesceMinutes', cur.coalesceMinutes, 0, 60);
  final pushWarn = range('pushWarnMinutes', cur.pushWarnMinutes, 5, 1440);

  var topics = {
    for (final e in cur.topics.entries)
      if (spaces.contains(e.key)) e.key: e.value,
  };
  if (b.containsKey('topics')) {
    final tp = b['topics'];
    if (tp is! Map<String, Object?>) throw _bad('topics', 'topics: expected an object');
    final next = <String, int>{};
    for (final e in tp.entries) {
      if (!spaces.contains(e.key)) continue; // spazi sconosciuti: si scartano
      final v = e.value;
      final s = v is int ? '$v' : (v is String ? v : null);
      if (s == null) throw _bad('topics.${e.key}', 'topic of ${e.key}: expected a string');
      try {
        final th = parseTopic(s, chat);
        if (th != null) next[e.key] = th;
      } on TopicError catch (te) {
        if (te.linkChat != null) {
          throw _bad(
            'topics.${e.key}',
            'topic of ${e.key}: the link is for chat ${te.linkChat}, not the configured chat $chat',
          );
        }
        throw _bad(
          'topics.${e.key}',
          'topic of ${e.key}: invalid value (a number greater than 1 or a t.me link)',
        );
      }
    }
    topics = next;
  }

  if (enabled && (token == null || chat == null)) {
    if (remove == true && token == null && cur.token != null) {
      throw _bad('removeToken', 'cannot remove the token while the bot stays enabled');
    }
    throw _bad(
      token == null ? 'token' : 'chat',
      'to enable the bot a token and a chat id are required',
    );
  }

  if (enabled != cur.enabled) changed.add('enabled');
  if (token != cur.token) changed.add('token');
  if (chat != cur.chat) changed.add('chat');
  if (language != cur.language) changed.add('language');
  if (notify.toJson().toString() != cur.notify.toJson().toString()) changed.add('notify');
  if (coalesce != cur.coalesceMinutes) changed.add('coalesceMinutes');
  if (pushWarn != cur.pushWarnMinutes) changed.add('pushWarnMinutes');
  if (!_sameMap(topics, cur.topics)) changed.add('topics');
  return (
    TelegramConfig(
      enabled: enabled,
      token: token,
      chat: chat,
      language: language,
      notify: notify,
      coalesceMinutes: coalesce,
      pushWarnMinutes: pushWarn,
      topics: Map.unmodifiable(topics),
    ),
    changed,
  );
}

bool _sameMap(Map<String, int> a, Map<String, int> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

// ---------------------------------------------------------------- file

/// `telegram.json` sotto /data: scritture atomiche, permessi 0600.
final class TelegramConfigFile {
  TelegramConfigFile(this.path);

  final String path;
  final _io = Mutex();
  TelegramConfig _cfg = const TelegramConfig();

  TelegramConfig get config => _cfg;

  /// Legge il file; assente o illeggibile = valori predefiniti.
  Future<TelegramConfig> load() async {
    _cfg = TelegramConfig.fromJson(await tryReadJsonFile(path));
    return _cfg;
  }

  /// Calcola, salva e adotta la configurazione restituita da [change]. Se
  /// [change] lancia, nulla cambia né in memoria né su disco (B-TG-27).
  Future<T> update<T>(Future<(TelegramConfig, T)> Function(TelegramConfig cur) change) =>
      _io.run(() async {
        final (next, out) = await change(_cfg);
        await writeJsonAtomic(path, next.toJson(), mode: 0x180);
        _cfg = next;
        return out;
      });
}
