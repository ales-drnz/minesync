// Chiamate alla Bot API di Telegram. Il trasporto è un'interfaccia così i
// test usano un Telegram finto in memoria, senza rete. Il token compare solo
// nell'URL della richiesta e non finisce mai in un errore o in un log.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Risposta grezza dell'API: stato HTTP e corpo JSON decodificato.
typedef TgReply = ({int status, Object? body});

/// Trasporto verso la Bot API.
abstract interface class TelegramTransport {
  /// Chiama `bot<token>/<method>` con [body] in JSON. Lancia su errori di
  /// rete (il messaggio può contenere l'URL: lo ripulisce [TelegramApi]).
  Future<TgReply> call(String token, String method, Map<String, Object?> body, Duration timeout);

  void close();
}

/// Trasporto reale su dart:io.
final class HttpTelegramTransport implements TelegramTransport {
  HttpTelegramTransport({this.base = 'https://api.telegram.org'});

  final String base;
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 10);

  @override
  Future<TgReply> call(
    String token,
    String method,
    Map<String, Object?> body,
    Duration timeout,
  ) async {
    Future<TgReply> run() async {
      final req = await _client.postUrl(Uri.parse('$base/bot$token/$method'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close();
      final bytes = <int>[];
      await for (final c in res) {
        bytes.addAll(c);
        if (bytes.length > 4 << 20) throw const FormatException('response too large');
      }
      Object? j;
      try {
        j = jsonDecode(utf8.decode(bytes));
      } on FormatException {
        j = null;
      }
      return (status: res.statusCode, body: j);
    }

    return run().timeout(timeout);
  }

  @override
  void close() => _client.close(force: true);
}

/// Errore di Telegram o della rete, già senza token.
final class TelegramError implements Exception {
  const TelegramError(
    this.message, {
    this.status,
    this.retryable = false,
    this.retryAfter,
    this.threadNotFound = false,
  });

  /// Testo dell'API così com'è (`Bad Request: chat not found`), o l'errore
  /// di rete ripulito.
  final String message;

  /// Stato HTTP; null per gli errori di rete.
  final int? status;

  /// Ha senso riprovare (rete, 5xx, 429); non per token o chat sbagliati.
  final bool retryable;

  /// `parameters.retry_after` di una risposta 429.
  final Duration? retryAfter;

  /// Il topic (message_thread_id) non esiste più.
  final bool threadNotFound;

  @override
  String toString() => message;
}

/// Toglie [token] da un testo (gli errori di rete possono contenere l'URL).
String redactToken(String s, String token) {
  var out = s;
  if (token.isNotEmpty) out = out.replaceAll(token, '<token>');
  // per sicurezza anche qualunque altro .../bot<id>:<segreto>/...
  return out.replaceAll(RegExp(r'bot\d+:[A-Za-z0-9_-]+'), 'bot<token>');
}

/// Le chiamate della Bot API usate dall'hub.
final class TelegramApi {
  TelegramApi(this.transport);

  final TelegramTransport transport;

  Future<Object?> _call(
    String token,
    String method,
    Map<String, Object?> body, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final TgReply r;
    try {
      r = await transport.call(token, method, body, timeout);
    } on TimeoutException {
      throw const TelegramError('network error: timed out', retryable: true);
    } catch (e) {
      throw TelegramError('network error: ${redactToken('$e', token)}', retryable: true);
    }
    final m = r.body is Map<String, Object?>
        ? r.body! as Map<String, Object?>
        : const <String, Object?>{};
    if (r.status == 200 && m['ok'] == true) return m['result'];
    final desc = m['description'] is String ? (m['description']! as String).trim() : '';
    final params = m['parameters'];
    Duration? after;
    if (params is Map<String, Object?> && params['retry_after'] is int) {
      final s = params['retry_after']! as int;
      if (s > 0) after = Duration(seconds: s > 3600 ? 3600 : s);
    }
    final status = r.status == 200 ? 400 : r.status;
    throw TelegramError(
      redactToken(desc.isEmpty ? 'HTTP $status' : desc, token),
      status: status,
      retryable: status >= 500 || status == 429,
      retryAfter: after,
      threadNotFound: desc.toLowerCase().contains('thread not found'),
    );
  }

  /// Invia un messaggio HTML. [thread] > 1: nel topic del gruppo forum (1 è
  /// il Generale e Telegram lo rifiuta: non si manda mai).
  Future<void> sendMessage(String token, String chat, String text, {int? thread}) =>
      _call(token, 'sendMessage', {
        'chat_id': chat,
        'text': text,
        'parse_mode': 'HTML',
        'link_preview_options': {'is_disabled': true},
        if (thread != null && thread > 1) 'message_thread_id': thread,
      });

  /// Aggiornamenti con long polling di [timeoutSec] secondi.
  Future<List<Map<String, Object?>>> getUpdates(
    String token, {
    int? offset,
    int timeoutSec = 0,
  }) async {
    final r = await _call(token, 'getUpdates', {
      'offset': ?offset,
      'timeout': timeoutSec,
      'allowed_updates': ['message'],
    }, timeout: Duration(seconds: timeoutSec + 15));
    return [
      if (r is List<Object?>)
        for (final u in r)
          if (u is Map<String, Object?>) u,
    ];
  }

  /// Nome utente del bot (`getMe`).
  Future<String?> username(String token) async {
    final r = await _call(token, 'getMe', const {});
    return r is Map<String, Object?> && r['username'] is String ? r['username']! as String : null;
  }

  /// Titolo della chat (`getChat`).
  Future<String?> chatTitle(String token, String chat) async {
    final r = await _call(token, 'getChat', {'chat_id': chat});
    if (r is! Map<String, Object?>) return null;
    final t = r['title'] ?? r['username'] ?? r['first_name'];
    return t is String ? t : null;
  }
}
