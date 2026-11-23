// Bot Telegram dell'hub: annuncia quando un server apre e chiude, avvisa se
// una sessione viva smette di salvare o se il disco si riempie, risponde a
// /status. Segue gli eventi dell'hub e, per i client spariti senza unlock
// (crash, corrente), guarda periodicamente le istantanee dei lock.
//
// Le sessioni si seguono anche a bot spento: riaccenderlo non perde la durata
// nel messaggio di chiusura. La configurazione cambia a caldo con [apply].
import 'dart:async';
import 'dart:collection';

import 'package:ms_protocol/ms_protocol.dart';

import '../clock.dart';
import 'config.dart';
import 'messages.dart';
import 'transport.dart';

/// Pubblica un evento dell'hub (la firma di `EventLog.publish` va bene).
typedef PublishEvent = void Function(String type, {String? actor, Map<String, Object?> data});

enum _Kind { open, close, alert, status }

/// Server aperto annunciato (o adottato al riavvio).
final class _Session {
  _Session({
    required this.member,
    required this.host,
    required this.since,
    required this.start,
    required this.lastPush,
  });

  final String member;
  String host;

  /// `since` del lock: identifica la sessione di lock.
  int since;

  /// Inizio mostrato (resta quello vero se si riapre subito).
  final int start;

  /// Ultimo push visto (tempo monotono).
  int lastPush;
  bool warned = false;
}

/// Chiusura non ancora annunciata (coalescenza, B-TG-11).
final class _Pending {
  _Pending(this.s, this.notResponding, this.atWall, this.atMono);
  final _Session s;
  final String? notResponding;
  final int atWall;
  final int atMono;
}

/// Annuncio in coda, con il destinatario fissato quando è stato accodato.
final class _Out {
  _Out(this.token, this.chat, this.text, this.thread, this.space);
  final String token;
  final String chat;
  final String text;
  final int? thread;
  final String? space;
}

final class TelegramBot {
  TelegramBot({
    required TelegramTransport transport,
    required this.clock,
    required this.spaces,
    this.events,
    String? Function()? dnsZone,
    String Function()? hubLanguage,
    PublishEvent? publish,
    void Function(String)? log,
    Future<void> Function(Duration)? sleep,
    this.backoff = const Duration(seconds: 2),
    this.retryBudget = const Duration(seconds: 90),
    this.tickEvery = const Duration(seconds: 5),
    this.pollTimeoutSec = 10,
    this.pollRetry = const Duration(seconds: 10),
    this.pollIdle = const Duration(seconds: 1),
    this.maxQueue = 64,
    TelegramConfig config = const TelegramConfig(),
  }) : api = TelegramApi(transport),
       _dnsZone = dnsZone ?? (() => null),
       _hubLanguage = hubLanguage ?? (() => 'it'),
       _publish = publish,
       _log = log ?? ((_) {}),
       _sleep = sleep ?? Future<void>.delayed,
       _cfg = config;

  final TelegramApi api;
  final Clock clock;

  /// Spazi con il lock attuale (istantanee, mai il mutex).
  final List<SpaceSummary> Function() spaces;
  final Stream<HubEvent>? events;
  final String? Function() _dnsZone;

  /// Lingua dell'hub (`it`/`en`) per `language: hub`.
  final String Function() _hubLanguage;
  final PublishEvent? _publish;
  final void Function(String) _log;
  final Future<void> Function(Duration) _sleep;

  /// Attesa base tra i tentativi di invio (se Telegram non dice retry_after).
  final Duration backoff;

  /// Tempo massimo speso ad aspettare per riprovare un messaggio.
  final Duration retryBudget;
  final Duration tickEvery;
  final int pollTimeoutSec;
  final Duration pollRetry;
  final Duration pollIdle;
  final int maxQueue;

  static const _tries = 3;

  TelegramConfig _cfg;
  final _open = <String, _Session>{};
  final _pending = <String, _Pending>{};
  final _out = ListQueue<_Out>();
  Future<void>? _drain;
  StreamSubscription<HubEvent>? _sub;
  Timer? _timer;
  bool _stopped = false;

  // stato per GET /telegram
  int? _lastSentAt;
  String? _lastSent;
  String? _lastError;
  int? _lastErrorAt;
  bool _pollErr = false;
  int _lastErrorEvent = -1 << 62;
  String? _chatTitle;
  String? _botUsername;
  final _missing = <String>{};

  // poller di /status
  int _pollGen = 0;
  String? _pollToken;
  final _recent = <TelegramChat>[];

  TelegramConfig get config => _cfg;

  /// Sessioni seguite (test e diagnostica).
  Set<String> get tracked => {..._open.keys, ..._pending.keys};

  /// Il poller di getUpdates sta girando.
  bool get polling => _pollToken != null;

  // ---------------------------------------------------------------- ciclo di vita

  /// Adotta in silenzio i lock già tenuti (riavvio dell'hub, B-TG-03), si
  /// iscrive agli eventi e, con [timers], fa girare la sorveglianza.
  void start({bool timers = true}) {
    final now = clock.monoMs();
    for (final sp in spaces()) {
      _names[sp.id] = sp.name;
      final lk = sp.lock;
      if (lk == null || lk.stale || lk.info.action != 'play') continue;
      _open[sp.id] = _Session(
        member: lk.memberId,
        host: lk.name,
        since: lk.since,
        start: lk.since,
        lastPush: now,
      );
    }
    _sub = events?.listen((e) {
      try {
        _onEvent(e);
      } catch (err, st) {
        _log('telegram: evento ${e.type}: $err\n$st');
      }
    });
    if (timers) _timer = Timer.periodic(tickEvery, (_) => tick());
    _syncPoller();
    if (_cfg.active) unawaited(_refreshInfo());
  }

  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    await _sub?.cancel();
    _pollGen++;
    _pollToken = null;
    _out.clear();
    api.transport.close();
    try {
      await _drain?.timeout(const Duration(seconds: 2));
    } catch (_) {
      // invio interrotto
    }
  }

  /// Nuova configurazione, subito valida (B-TG-15/16/17).
  void apply(TelegramConfig c) {
    final old = _cfg;
    _cfg = c;
    final dest = old.token != c.token || old.chat != c.chat || old.active != c.active;
    if (dest) {
      _lastError = null;
      _lastErrorAt = null;
      _pollErr = false;
      _missing.clear();
      if (old.token != c.token || old.chat != c.chat) {
        _chatTitle = null;
        _botUsername = null;
      }
    } else {
      _missing.removeWhere((s) => old.topics[s] != c.topics[s]);
    }
    if (!c.active) _out.clear(); // niente coda a bot spento
    if (c.active && dest) {
      _log('telegram: bot attivo (chat ${c.chat})');
      unawaited(_refreshInfo());
    } else if (!c.active && old.active) {
      _log('telegram: bot disattivato');
    }
    _syncPoller();
  }

  /// Aspetta che la coda degli annunci sia vuota.
  Future<void> idle() async {
    while (_drain != null) {
      await _drain;
    }
  }

  /// Stato per GET /telegram; [spaceIds] filtra topic e topic mancanti.
  TelegramStatus status({Set<String>? spaceIds}) {
    final c = _cfg;
    final state = !c.enabled
        ? TelegramState.disabled
        : !c.active
        ? TelegramState.incomplete
        : _lastError != null
        ? TelegramState.error
        : TelegramState.active;
    return TelegramStatus(
      settings: c.view(spaces: spaceIds),
      state: state,
      chatTitle: _chatTitle,
      botUsername: _botUsername,
      lastSentAt: _lastSentAt,
      lastSent: _lastSent,
      lastError: _lastError,
      lastErrorAt: _lastErrorAt,
      missingTopics: [
        for (final s in _missing)
          if (spaceIds == null || spaceIds.contains(s)) s,
      ]..sort(),
    );
  }

  BotTexts _texts([String? lang]) {
    final l = lang ?? _cfg.language;
    return BotTexts.of(l == 'hub' ? _hubLanguage() : l);
  }

  // ---------------------------------------------------------------- eventi

  Map<String, SpaceSummary> _snapshot() => {for (final s in spaces()) s.id: s};

  void _onEvent(HubEvent e) {
    final id = e.space;
    switch (e.type) {
      case EventType.lock:
        final sp = _snapshot()[id];
        final lk = sp?.lock;
        if (sp != null && lk != null && !lk.stale) _opened(sp, lk);
      case EventType.unlock:
        if (id != null) _closed(id);
      case EventType.force:
        if (id == null) return;
        _closed(id);
        final sp = _snapshot()[id];
        final lk = sp?.lock;
        if (sp != null && lk != null && !lk.stale) _opened(sp, lk);
      case EventType.stale:
        final s = id == null ? null : _open[id];
        if (s != null) _closed(id!, notResponding: s.host);
      case EventType.push:
        final s = id == null ? null : _open[id];
        if (s != null) {
          s
            ..lastPush = clock.monoMs()
            ..warned = false;
        }
      case EventType.spaceDelete:
        // spazio eliminato: la sessione si dimentica in silenzio (B-TG-13)
        _open.remove(id);
        _pending.remove(id);
      case EventType.disk:
        final free = e.data['free'], min = e.data['minFree'];
        if (free is int && min is int) {
          _queue(
            _Kind.alert,
            null,
            _texts().disk(free: free, minFree: min, full: e.data['level'] == 'full'),
          );
        }
    }
  }

  /// Registra un lock di gioco vivo e, se serve, ne annuncia l'apertura.
  /// Idempotente per sessione di lock: lo chiamano gli eventi e la
  /// sorveglianza periodica.
  void _opened(SpaceSummary sp, LockHolder lk) {
    if (lk.info.action != 'play') return; // push manuale: mai annunciato (B-TG-09)
    final id = sp.id;
    _names[id] = sp.name;
    final nowMono = clock.monoMs(), nowWall = clock.wallMs();
    final cur = _open[id];
    if (cur != null) {
      if (cur.since == lk.since && cur.member == lk.memberId) return;
      // la sessione precedente è finita senza che ce ne accorgessimo
      _open.remove(id);
      _flushClose(id, _Pending(cur, null, nowWall, nowMono));
    }
    final p = _pending.remove(id);
    if (p != null) {
      if (p.s.since == lk.since && p.s.member == lk.memberId) {
        // lo stesso lock tornato vivo prima che la chiusura partisse (B-TG-12)
        _open[id] = p.s;
        return;
      }
      if (p.s.member == lk.memberId && nowMono - p.atMono <= _coalesceMs) {
        // chiuso e riaperto subito dallo stesso host: nessun messaggio, la
        // sessione continua con la durata vera (B-TG-11)
        _open[id] = p.s
          ..since = lk.since
          ..lastPush = nowMono
          ..warned = false;
        return;
      }
      _flushClose(id, p); // chiusura vera: prima della nuova apertura
    }
    _open[id] = _Session(
      member: lk.memberId,
      host: lk.name,
      since: lk.since,
      start: lk.since,
      lastPush: nowMono,
    );
    final zone = _dnsZone();
    _queue(
      _Kind.open,
      id,
      _texts().open(
        name: sp.name,
        host: lk.name,
        dnsName: zone == null ? null : 'zerotier.$id.$zone',
        address: lk.ip == null ? null : hostAddress(lk.ip!, lk.info.port),
      ),
    );
  }

  int get _coalesceMs => _cfg.coalesceMinutes * 60000;

  /// Fine di una sessione: l'annuncio parte dopo la finestra di coalescenza.
  void _closed(String id, {String? notResponding}) {
    final s = _open.remove(id);
    if (s == null) return;
    final p = _Pending(s, notResponding, clock.wallMs(), clock.monoMs());
    if (_coalesceMs <= 0) {
      _flushClose(id, p);
    } else {
      _pending[id] = p;
    }
  }

  final _names = <String, String>{};

  void _flushClose(String id, _Pending p) {
    _queue(
      _Kind.close,
      id,
      _texts().close(
        name: _names[id] ?? id,
        session: Duration(milliseconds: p.atWall - p.s.start),
        notResponding: p.notResponding,
      ),
    );
  }

  /// Sorveglianza periodica: lock scaduti o tornati vivi, spazi eliminati,
  /// watchdog dei salvataggi, chiusure in attesa.
  void tick() {
    if (_stopped) return;
    try {
      final snap = _snapshot();
      for (final s in snap.values) {
        _names[s.id] = s.name;
      }
      _sweepLocks(snap);
      _watchdog(snap);
      _flushPending(snap);
    } catch (e, st) {
      _log('telegram: sorveglianza: $e\n$st');
    }
  }

  void _sweepLocks(Map<String, SpaceSummary> snap) {
    for (final e in _open.entries.toList()) {
      final sp = snap[e.key];
      if (sp == null) {
        _open.remove(e.key); // eliminato: niente da annunciare (B-TG-13)
        continue;
      }
      final lk = sp.lock, s = e.value;
      if (lk == null || lk.since != s.since || lk.memberId != s.member) {
        _closed(e.key);
      } else if (lk.stale) {
        _closed(e.key, notResponding: s.host); // B-TG-02
      } else {
        s.host = lk.name;
      }
    }
    for (final sp in snap.values) {
      final lk = sp.lock;
      if (lk != null && !lk.stale && !_open.containsKey(sp.id)) _opened(sp, lk);
    }
  }

  /// Un avviso per sessione se un server vivo non salva da tanto (B-TG-06).
  void _watchdog(Map<String, SpaceSummary> snap) {
    final now = clock.monoMs();
    final limit = _cfg.pushWarnMinutes * 60000;
    for (final e in _open.entries) {
      final s = e.value;
      if (s.warned || now - s.lastPush < limit) continue;
      final sp = snap[e.key];
      final lk = sp?.lock;
      if (sp == null || lk == null || lk.stale) continue;
      // ad avvisi spenti la sessione non si marca: riaccesi, l'avviso arriva
      if (_queue(
        _Kind.alert,
        e.key,
        _texts().notSaving(
          name: sp.name,
          host: s.host,
          since: Duration(milliseconds: now - s.lastPush),
        ),
      )) {
        s.warned = true;
      }
    }
  }

  void _flushPending(Map<String, SpaceSummary> snap) {
    final now = clock.monoMs();
    for (final e in _pending.entries.toList()) {
      if (!snap.containsKey(e.key)) {
        _pending.remove(e.key);
        continue;
      }
      if (now - e.value.atMono >= _coalesceMs) {
        _pending.remove(e.key);
        _flushClose(e.key, e.value);
      }
    }
  }

  // ---------------------------------------------------------------- coda e invio

  bool _wants(_Kind k) => switch (k) {
    _Kind.open => _cfg.notify.open,
    _Kind.close => _cfg.notify.close,
    _Kind.alert => _cfg.notify.alerts,
    _Kind.status => _cfg.notify.status,
  };

  /// Accoda senza mai bloccare l'hub. A bot spento o con quel tipo di
  /// messaggio disattivato non accoda nulla (false). Il messaggio va nel
  /// topic dello spazio, se ne ha uno ([thread] vale per /status).
  bool _queue(_Kind k, String? space, String text, {int? thread}) {
    final c = _cfg;
    if (_stopped || !c.active || !_wants(k)) return false;
    var th = thread;
    if (space != null && !_missing.contains(space)) th = c.topicOf(space);
    if (_out.length >= maxQueue) {
      _log('telegram: coda piena, annuncio scartato');
      return false;
    }
    _out.add(_Out(c.token!, c.chat!, text, th, space));
    _kick();
    return true;
  }

  void _kick() {
    if (_drain != null) return;
    _drain = _drainLoop().whenComplete(() {
      _drain = null;
      if (_out.isNotEmpty && !_stopped) _kick();
    });
  }

  Future<void> _drainLoop() async {
    while (_out.isNotEmpty && !_stopped) {
      final m = _out.removeFirst();
      // accodato prima di un cambio di configurazione: non va più mandato
      final c = _cfg;
      if (!c.active || c.token != m.token || c.chat != m.chat) continue;
      await _send(m);
    }
  }

  /// Invia riprovando gli errori transitori: rispetta retry_after (429) e non
  /// aspetta più di [retryBudget] in tutto (B-TG-10).
  Future<void> _send(_Out m) async {
    TelegramError? err;
    var spent = Duration.zero;
    for (var attempt = 1; ; attempt++) {
      try {
        await api.sendMessage(m.token, m.chat, m.text, thread: m.thread);
        _recordSent(m.token, m.chat, m.text);
        return;
      } on TelegramError catch (e) {
        if (m.thread != null && e.threadNotFound) return _fallback(m);
        err = e;
        if (!e.retryable || attempt >= _tries || _stopped) break;
        final wait = e.retryAfter ?? backoff * attempt;
        if (spent + wait > retryBudget) break;
        await _sleep(wait);
        spent += wait;
      }
    }
    _recordErr(m.token, m.chat, err.message);
    _log('telegram: annuncio non inviato: ${err.message}');
  }

  /// Il topic dello spazio non esiste più: l'annuncio va una volta nella
  /// chat principale e lo stato nomina il topic finché la mappa non cambia
  /// (B-TG-21).
  Future<void> _fallback(_Out m) async {
    final space = m.space!;
    _missing.add(space);
    try {
      await api.sendMessage(m.token, m.chat, m.text);
      _recordSent(m.token, m.chat, m.text);
      _recordErr(m.token, m.chat, _texts().topicMissing(_names[space] ?? space));
    } on TelegramError catch (e) {
      _recordErr(m.token, m.chat, e.message);
    }
  }

  void _recordSent(String token, String chat, String text) {
    if (token != _cfg.token || chat != _cfg.chat) return;
    _lastSentAt = clock.wallMs();
    _lastSent = firstLine(text);
    _lastError = null;
    _lastErrorAt = null;
    _pollErr = false;
  }

  /// [chat] null = errore del poller (vale per qualsiasi chat).
  void _recordErr(String token, String? chat, String msg, {bool fromPoll = false}) {
    if (token != _cfg.token || (chat != null && chat != _cfg.chat)) return;
    _lastError = msg;
    _lastErrorAt = clock.wallMs();
    _pollErr = fromPoll;
    final now = clock.monoMs();
    if (now - _lastErrorEvent >= const Duration(hours: 1).inMilliseconds) {
      _lastErrorEvent = now;
      _publish?.call(EventType.telegramError, data: {'error': msg});
    }
  }

  Future<void> _refreshInfo() async {
    final c = _cfg;
    final token = c.token, chat = c.chat;
    if (token == null || chat == null) return;
    try {
      final u = await api.username(token);
      final t = await api.chatTitle(token, chat);
      if (_cfg.token == token && _cfg.chat == chat) {
        _botUsername = u;
        _chatTitle = t;
      }
    } on TelegramError {
      // si vedrà al primo invio
    }
  }

  // ---------------------------------------------------------------- /status

  void _syncPoller() {
    final c = _cfg;
    final want = !_stopped && c.active && c.notify.status ? c.token : null;
    if (want == _pollToken) return;
    _pollGen++;
    _pollToken = want;
    _recent.clear();
    if (want != null) unawaited(_pollLoop(_pollGen, want));
  }

  Future<void> _pollLoop(int gen, String token) async {
    int? offset;
    while (gen == _pollGen && !_stopped) {
      List<Map<String, Object?>> ups;
      try {
        ups = await api.getUpdates(token, offset: offset, timeoutSec: pollTimeoutSec);
      } on TelegramError catch (e) {
        if (gen != _pollGen) return;
        _recordErr(token, null, e.message, fromPoll: true);
        await _sleep(pollRetry);
        continue;
      }
      if (gen != _pollGen) return;
      if (_pollErr && token == _cfg.token) {
        _lastError = null;
        _lastErrorAt = null;
        _pollErr = false;
      }
      for (final u in ups) {
        final uid = u['update_id'];
        if (uid is int && (offset == null || uid >= offset)) offset = uid + 1;
        final msg = u['message'];
        if (msg is Map<String, Object?>) {
          _remember(msg);
          _command(msg);
        }
      }
      if (ups.isEmpty) await _sleep(pollIdle);
    }
  }

  void _remember(Map<String, Object?> msg) {
    final c = _chatOf(msg);
    if (c == null) return;
    _recent.removeWhere((x) => x.id == c.id && x.thread == c.thread);
    _recent.insert(0, c);
    if (_recent.length > 50) _recent.removeLast();
  }

  static TelegramChat? _chatOf(Map<String, Object?> msg) {
    final chat = msg['chat'];
    if (chat is! Map<String, Object?> || chat['id'] is! int) return null;
    final th = msg['message_thread_id'];
    return TelegramChat(
      id: '${chat['id']}',
      type: chat['type'] is String ? chat['type']! as String : 'private',
      title: (chat['title'] ?? chat['username'] ?? chat['first_name']) as String?,
      thread: msg['is_topic_message'] == true && th is int && th > 1 ? th : null,
    );
  }

  /// Risponde a `/status` (anche `/status@<bot>`) solo nella chat configurata,
  /// nello stesso topic; in un topic di un server solo per quel server (B-TG-20).
  void _command(Map<String, Object?> msg) {
    final text = msg['text'];
    if (text is! String) return;
    final word = text.trim().split(RegExp(r'\s+')).first;
    final at = word.indexOf('@');
    final cmd = (at < 0 ? word : word.substring(0, at)).toLowerCase();
    if (cmd != '/status') return;
    if (at >= 0 &&
        _botUsername != null &&
        word.substring(at + 1).toLowerCase() != _botUsername!.toLowerCase()) {
      return; // comando per un altro bot
    }
    final chat = msg['chat'];
    if (chat is! Map<String, Object?> || '${chat['id']}' != _cfg.chat) return;
    final th = msg['message_thread_id'];
    final thread = msg['is_topic_message'] == true && th is int && th > 1 ? th : null;
    Set<String>? only;
    if (thread != null) {
      only = {
        for (final e in _cfg.topics.entries)
          if (e.value == thread) e.key,
      };
    }
    _queue(_Kind.status, null, statusText(only: only), thread: thread);
  }

  /// Testo di /status; [only] limita agli spazi indicati (vuoto o nessuno
  /// esistente = tutti).
  String statusText({Set<String>? only}) {
    final now = clock.wallMs();
    final zone = _dnsZone();
    var list = spaces();
    if (only != null && only.isNotEmpty) {
      final sel = list.where((s) => only.contains(s.id)).toList();
      if (sel.isNotEmpty) list = sel;
    }
    return _texts().status([
      for (final sp in list)
        (
          sp.name,
          switch (sp.lock) {
            final lk? when !lk.stale && lk.info.action == 'play' => (
              name: sp.name,
              host: lk.name,
              since: Duration(milliseconds: now - lk.since),
              players: lk.info.players,
              dnsName: zone == null ? null : 'zerotier.${sp.id}.$zone',
              address: lk.ip == null ? null : hostAddress(lk.ip!, lk.info.port),
            ),
            _ => null,
          },
        ),
    ]);
  }

  // ---------------------------------------------------------------- prova e trova chat

  /// Messaggio di prova con una configurazione anche non salvata, un solo
  /// tentativo. Restituisce l'ora di invio; lancia [TelegramError] (già
  /// senza token). Un topic eliminato dà un errore chiaro senza toccare lo
  /// stato (B-TG-21); gli altri errori si registrano (B-TG-18).
  Future<int> sendTest({
    required String token,
    required String chat,
    String? language,
    int? thread,
    String? spaceName,
  }) async {
    final t = _texts(language);
    final text = t.test(space: spaceName);
    try {
      await api.sendMessage(token, chat, text, thread: thread);
    } on TelegramError catch (e) {
      if (thread != null && e.threadNotFound) {
        throw TelegramError(t.topicMissing(spaceName ?? '$thread'), status: e.status);
      }
      _recordErr(token, chat, e.message);
      rethrow;
    }
    _recordSent(token, chat, text);
    return clock.wallMs();
  }

  /// Chat viste negli ultimi aggiornamenti: il buffer del poller se gira con
  /// questo token, altrimenti un getUpdates senza confermare gli offset.
  Future<List<TelegramChat>> findChats(String token) async {
    if (_pollToken == token) return List.of(_recent);
    final ups = await api.getUpdates(token);
    final out = <TelegramChat>[];
    for (final u in ups.reversed) {
      final msg = u['message'];
      final c = msg is Map<String, Object?> ? _chatOf(msg) : null;
      if (c != null && !out.any((x) => x.id == c.id && x.thread == c.thread)) out.add(c);
    }
    return out;
  }
}
