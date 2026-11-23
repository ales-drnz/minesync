// Endpoint del bot Telegram (solo admin): GET/PATCH /telegram,
// POST /telegram/test, POST /telegram/find-chat. Nessuna risposta contiene
// mai il token (B-TG-28).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ms_protocol/ms_protocol.dart';

import '../clock.dart';
import '../members.dart' show Identity;
import 'bot.dart';
import 'config.dart';
import 'transport.dart';

const _bodyLimit = 64 << 10;

final class TelegramRoutes {
  TelegramRoutes({
    required this.bot,
    required this.file,
    required this.clock,
    required this.spaceNames,
    this.publish,
    this.onChanged,
    this.testInterval = const Duration(seconds: 3),
  });

  final TelegramBot bot;
  final TelegramConfigFile file;
  final Clock clock;

  /// Id → nome degli spazi esistenti.
  final Map<String, String> Function() spaceNames;
  final PublishEvent? publish;

  /// Dopo un PATCH che ha cambiato qualcosa (es. «Ultima modifica» dell'Admin).
  final Future<void> Function(Identity who)? onChanged;

  /// Distanza minima tra due prove (B-TG-29).
  final Duration testInterval;
  int? _lastTest;

  /// Gestisce la richiesta se è sua; [segs] sono i segmenti dopo /api/v1.
  /// Gli errori escono come [ApiError], li trasforma in risposta il server.
  Future<bool> handle(HttpRequest req, Identity who, bool admin, List<String> segs) async {
    if (segs.isEmpty || segs[0] != 'telegram') return false;
    if (!admin) throw const ApiError(ErrorCode.forbidden, 'admin only');
    switch ((req.method, segs)) {
      case ('GET', ['telegram']):
        await _json(req, _status());
      case ('PATCH', ['telegram']):
        final b = await _readObject(req);
        final ids = spaceNames().keys.toSet();
        final changed = await file.update((cur) async => applyPatch(cur, b, spaces: ids));
        bot.apply(file.config);
        if (changed.isNotEmpty) {
          // solo i nomi dei campi, mai i valori (B-EVENTS-04)
          publish?.call(
            EventType.settings,
            actor: who.name,
            data: {'section': 'telegram', 'fields': changed},
          );
          await onChanged?.call(who);
        }
        await _json(req, _status());
      case ('POST', ['telegram', 'test']):
        await _json(req, await _test(await _readObject(req, optional: true)));
      case ('POST', ['telegram', 'find-chat']):
        final b = await _readObject(req, optional: true);
        final token = _optString(b, 'token') ?? file.config.token;
        if (token == null) {
          throw const ApiError(
            ErrorCode.badRequest,
            'no bot token: send one or save it first',
            details: {'field': 'token'},
          );
        }
        if (!validToken(token)) {
          throw const ApiError(
            ErrorCode.badRequest,
            'invalid bot token',
            details: {'field': 'token'},
          );
        }
        final List<TelegramChat> chats;
        try {
          chats = await bot.findChats(token);
        } on TelegramError catch (e) {
          throw _upstream(e);
        }
        await _json(req, {
          'chats': [for (final c in chats) c.toJson()],
        });
      default:
        throw const ApiError(ErrorCode.notFound, 'no such endpoint');
    }
    return true;
  }

  Map<String, Object?> _status() => bot.status(spaceIds: spaceNames().keys.toSet()).toJson();

  static ApiError _upstream(TelegramError e) =>
      ApiError(ErrorCode.upstream, 'telegram error: ${e.message}', details: {'error': e.message});

  Future<Map<String, Object?>> _test(Map<String, Object?> b) async {
    final cfg = file.config;
    final bt = _optString(b, 'token');
    if (bt != null && !validToken(bt)) {
      throw const ApiError(ErrorCode.badRequest, 'invalid bot token', details: {'field': 'token'});
    }
    final bc = _optString(b, 'chat');
    if (bc != null && !validChat(bc)) {
      throw const ApiError(ErrorCode.badRequest, 'invalid chat id', details: {'field': 'chat'});
    }
    final lang = _optString(b, 'language');
    if (lang != null && !telegramLanguages.contains(lang)) {
      throw const ApiError(
        ErrorCode.badRequest,
        'invalid language',
        details: {'field': 'language'},
      );
    }
    final token = bt ?? cfg.token, chat = bc ?? cfg.chat;
    if (token == null || chat == null) {
      throw const ApiError(
        ErrorCode.badRequest,
        'nothing to test: a bot token and a chat id are required',
        details: {'field': 'token'},
      );
    }
    final spaceId = _optString(b, 'spaceId');
    String? spaceName;
    if (spaceId != null) {
      spaceName = spaceNames()[spaceId];
      if (spaceName == null) throw ApiError(ErrorCode.notFound, 'space $spaceId: not found');
    }
    int? thread;
    if (b.containsKey('topic')) {
      final t = b['topic'];
      final ts = t is int ? '$t' : (t is String ? t : null);
      if (ts == null) {
        throw const ApiError(
          ErrorCode.badRequest,
          'topic: expected a string',
          details: {'field': 'topic'},
        );
      }
      try {
        thread = parseTopic(ts, chat);
      } on TopicError catch (e) {
        throw ApiError(
          ErrorCode.badRequest,
          e.linkChat == null
              ? 'invalid topic (a number greater than 1 or a t.me link)'
              : 'the topic link is for chat ${e.linkChat}, not $chat',
          details: {'field': 'topic'},
        );
      }
    } else if (spaceId != null) {
      thread = cfg.topicOf(spaceId);
    }
    final now = clock.monoMs();
    final last = _lastTest;
    if (last != null && now - last < testInterval.inMilliseconds) {
      final wait = testInterval.inMilliseconds - (now - last);
      throw ApiError(
        ErrorCode.rateLimited,
        'wait before sending another test message',
        details: {'retryMs': wait},
      );
    }
    _lastTest = now;
    final int sentAt;
    try {
      sentAt = await bot.sendTest(
        token: token,
        chat: chat,
        language: lang,
        thread: thread,
        spaceName: spaceName,
      );
    } on TelegramError catch (e) {
      throw _upstream(e);
    }
    return TelegramTestResult(sentAt: sentAt, chat: chat, thread: thread).toJson();
  }

  static String? _optString(Map<String, Object?> b, String k) {
    final v = b[k];
    if (v == null) return null;
    if (v is! String) {
      throw ApiError(ErrorCode.badRequest, '$k: expected a string', details: {'field': k});
    }
    final s = v.trim();
    return s.isEmpty ? null : s;
  }

  static Future<void> _json(HttpRequest req, Object? body) async {
    final res = req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await res.close();
  }

  static Future<Map<String, Object?>> _readObject(HttpRequest req, {bool optional = false}) async {
    final b = BytesBuilder(copy: false);
    await for (final c in req) {
      b.add(c);
      if (b.length > _bodyLimit) {
        throw const ApiError(
          ErrorCode.tooLarge,
          'body larger than $_bodyLimit bytes',
          details: {'limit': _bodyLimit},
        );
      }
    }
    if (b.isEmpty) {
      if (optional) return const {};
      throw const ApiError(ErrorCode.badRequest, 'expected a JSON object');
    }
    final Object? j;
    try {
      j = jsonDecode(utf8.decode(b.takeBytes()));
    } on FormatException {
      throw const ApiError(ErrorCode.badRequest, 'invalid JSON body');
    }
    if (j is! Map<String, Object?>) {
      throw const ApiError(ErrorCode.badRequest, 'expected a JSON object');
    }
    return j;
  }
}
