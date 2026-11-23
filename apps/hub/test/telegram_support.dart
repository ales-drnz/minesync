// Supporto ai test del bot Telegram: un Telegram finto in memoria (nessuna
// rete) e un "mondo" finto di spazi e lock che pubblica gli eventi dell'hub.
import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:minesync_hub/minesync_hub.dart';
import 'package:minesync_hub/src/telegram/transport.dart';
import 'package:ms_protocol/ms_protocol.dart';

const tgToken = '123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const tgToken2 = '987654321:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const tgChat = '-1001234567890';
const tgChat2 = '-1009876543210';

/// Un messaggio arrivato al Telegram finto.
final class Sent {
  Sent(this.token, this.chat, this.text, this.thread);
  final String token;
  final String chat;
  final String text;
  final int? thread;

  @override
  String toString() => 'Sent($chat#$thread: $text)';
}

/// Telegram finto: registra le chiamate, può fallire a comando.
final class FakeTelegram implements TelegramTransport {
  final sent = <Sent>[];
  final calls = <String>[];

  /// Risposte programmate per i prossimi sendMessage (null = successo).
  final plan = ListQueue<TgReply?>();

  /// Thread che non esistono più.
  final deletedThreads = <int>{};

  /// Se impostato, sendMessage lancia un errore di rete con l'URL completo.
  bool networkDown = false;

  /// Se impostato, sendMessage aspetta questo cancello.
  Completer<void>? gate;

  /// Aggiornamenti in arrivo per getUpdates.
  final updates = <Map<String, Object?>>[];
  int getUpdatesCalls = 0;
  int _nextUpdate = 1;

  void say(
    String text, {
    String chat = tgChat,
    int? thread,
    bool topic = true,
    String type = 'supergroup',
  }) {
    updates.add({
      'update_id': _nextUpdate++,
      'message': {
        'text': text,
        'chat': {'id': int.parse(chat), 'type': type, 'title': 'Gruppo'},
        'message_thread_id': ?thread,
        if (thread != null && topic) 'is_topic_message': true,
      },
    });
  }

  static TgReply ok([Object? result = true]) => (status: 200, body: {'ok': true, 'result': result});

  static TgReply fail(int status, String desc, {int? retryAfter}) => (
    status: status,
    body: {
      'ok': false,
      'error_code': status,
      'description': desc,
      if (retryAfter != null) 'parameters': {'retry_after': retryAfter},
    },
  );

  @override
  Future<TgReply> call(
    String token,
    String method,
    Map<String, Object?> body,
    Duration timeout,
  ) async {
    calls.add(method);
    switch (method) {
      case 'getMe':
        return ok({'id': 1, 'is_bot': true, 'username': 'msbot'});
      case 'getChat':
        return ok({'id': int.parse(body['chat_id']! as String), 'title': 'Gruppo'});
      case 'getUpdates':
        getUpdatesCalls++;
        final off = body['offset'] as int? ?? 0;
        for (var i = 0; i < 20; i++) {
          final out = [
            for (final u in updates)
              if ((u['update_id']! as int) >= off) u,
          ];
          if (out.isNotEmpty) return ok(out);
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        return ok(<Object?>[]);
      case 'sendMessage':
        if (gate != null) await gate!.future;
        if (networkDown) {
          throw SocketException('connection refused (https://api.telegram.org/bot$token/x)');
        }
        final th = body['message_thread_id'] as int?;
        if (th != null && deletedThreads.contains(th)) {
          return fail(400, 'Bad Request: message thread not found');
        }
        final p = plan.isEmpty ? null : plan.removeFirst();
        if (p != null) return p;
        sent.add(Sent(token, body['chat_id']! as String, body['text']! as String, th));
        return ok({'message_id': sent.length});
    }
    return fail(404, 'Not Found');
  }

  @override
  void close() {}
}

/// Spazi e lock finti; pubblica gli eventi come farebbe l'hub.
final class FakeWorld {
  FakeWorld(this.clock);

  final FakeClock clock;
  final _spaces = <String, SpaceSummary>{};
  final _events = StreamController<HubEvent>.broadcast(sync: true);
  int _seq = 0;

  Stream<HubEvent> get events => _events.stream;
  List<SpaceSummary> spaces() => _spaces.values.toList();

  void emit(String type, {String? space, Map<String, Object?> data = const {}}) =>
      _events.add(HubEvent(seq: ++_seq, ts: clock.wallMs(), type: type, space: space, data: data));

  void add(String id, String name) => _spaces[id] = SpaceSummary(
    id: id,
    name: name,
    profile: Profile.minecraft,
    createdAt: 0,
    head: null,
    lock: null,
  );

  void _setLock(String id, LockHolder? l) {
    final s = _spaces[id]!;
    _spaces[id] = SpaceSummary(
      id: s.id,
      name: s.name,
      profile: s.profile,
      createdAt: 0,
      head: null,
      lock: l,
    );
  }

  LockHolder? lockOf(String id) => _spaces[id]?.lock;

  /// [who] prende il lock di gioco (o di push con [action]).
  void play(
    String id,
    String who, {
    String? ip = '192.0.2.10',
    int? port,
    List<String> players = const [],
    String action = 'play',
    bool event = true,
  }) {
    _setLock(
      id,
      LockHolder(
        memberId: 'id-$who',
        name: who,
        since: clock.wallMs(),
        lastBeat: clock.wallMs(),
        stale: false,
        // il LAN c'è nel lock in memoria ma il bot non deve mai usarlo
        info: LockInfo(
          client: 'test',
          action: action,
          players: players,
          port: port,
          lan: '198.51.100.77',
        ),
        ip: ip,
      ),
    );
    if (event) emit(EventType.lock, space: id);
  }

  void setStale(String id, bool stale) {
    final l = lockOf(id)!;
    _setLock(
      id,
      LockHolder(
        memberId: l.memberId,
        name: l.name,
        since: l.since,
        lastBeat: l.lastBeat,
        stale: stale,
        info: l.info,
        ip: l.ip,
      ),
    );
  }

  void release(String id) {
    _setLock(id, null);
    emit(EventType.unlock, space: id);
  }

  void delete(String id, {bool event = true}) {
    _spaces.remove(id);
    if (event) emit(EventType.spaceDelete, space: id);
  }

  Future<void> close() => _events.close();
}

TelegramConfig tgConfig({
  bool enabled = true,
  String? token = tgToken,
  String? chat = tgChat,
  String language = 'it',
  TelegramNotify notify = const TelegramNotify(),
  int coalesce = 0,
  int pushWarn = 30,
  Map<String, int> topics = const {},
}) => TelegramConfig(
  enabled: enabled,
  token: token,
  chat: chat,
  language: language,
  notify: notify,
  coalesceMinutes: coalesce,
  pushWarnMinutes: pushWarn,
  topics: topics,
);

/// Bot, Telegram finto e mondo finto collegati.
final class BotRig {
  BotRig({
    TelegramConfig? config,
    String? zone = 'mc.test',
    bool start = true,
    List<void Function(FakeWorld)> before = const [],
  }) : clock = FakeClock(DateTime.utc(2026, 5, 1, 12)) {
    world = FakeWorld(clock);
    world
      ..add('survival', 'Survival')
      ..add('creativo', 'Creativo')
      ..add('avventura', 'Avventura');
    for (final f in before) {
      f(world);
    }
    bot = TelegramBot(
      transport: tg,
      clock: clock,
      spaces: world.spaces,
      events: world.events,
      dnsZone: () => zone,
      hubLanguage: () => hubLang,
      publish: (type, {actor, data = const {}}) => published.add((type, data)),
      sleep: (d) async => waits.add(d),
      pollIdle: const Duration(milliseconds: 1),
      config: config ?? tgConfig(),
    );
    if (start) bot.start(timers: false);
  }

  final FakeClock clock;
  final tg = FakeTelegram();
  late final FakeWorld world;
  late final TelegramBot bot;
  final waits = <Duration>[];
  final published = <(String, Map<String, Object?>)>[];
  String hubLang = 'it';

  /// Messaggi inviati finora (dopo aver svuotato la coda).
  Future<List<Sent>> sent() async {
    await bot.idle();
    return tg.sent;
  }

  Future<List<String>> texts() async => [for (final s in await sent()) s.text];

  /// Avanza l'orologio e fa girare la sorveglianza.
  Future<void> after(Duration d) async {
    clock.advance(d);
    bot.tick();
    await bot.idle();
  }

  Future<void> close() async {
    await bot.stop();
    await world.close();
  }
}

/// Aspetta che [cond] diventi vero (al più 3 s).
Future<void> until(bool Function() cond) async {
  for (var i = 0; i < 300 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
