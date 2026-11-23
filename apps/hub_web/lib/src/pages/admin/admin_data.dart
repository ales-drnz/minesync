// Dati dell'area Admin: impostazioni, membri, Telegram, uso del disco,
// sistema e valori propri dei server, caricati insieme all'apertura di una
// sezione e riletti quando arriva un evento che li cambia (anche da un altro
// admin). Le modifiche passano da bozze per campo: salvataggio automatico
// dopo una breve pausa (PATCH per sezione con i soli campi cambiati) oppure
// subito con «Salva e applica».
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:ms_protocol/ms_protocol.dart';

import '../../state/hub_state.dart';

/// Limiti dei campi numerici (gli stessi dell'hub, protocol.md "Settings").
const Map<String, (int, int)> fieldRanges = {
  'members.trustHours': (0, 8760),
  'members.refreshSeconds': (10, 3600),
  'history.keepLast': (1, 10000),
  'history.keepHours': (0, 8760),
  'history.keepDays': (0, 3650),
  'disk.minFreeGiB': (0, 100000),
  'disk.minFreePercent': (0, 50),
  'sessions.autosaveMinutes': (1, 1440),
  'sessions.autostopMinutes': (1, 1440),
  'sessions.crashRestarts': (0, 10),
  'protection.massDeletePercent': (1, 100),
  'protection.massDeleteMinFiles': (0, 100000000),
  'stats.sessionsKept': (1, 1000),
  'telegram.coalesceMinutes': (0, 60),
  'telegram.pushWarnMinutes': (5, 1440),
};

/// Lunghezza massima del nome dell'hub.
const maxHubName = 40;

/// Sezione «finta» per le impostazioni di Telegram, che hanno un endpoint
/// proprio (`PATCH /telegram`).
const telegramSection = 'telegram';

/// Uguaglianza profonda per i valori delle bozze (liste di pattern).
bool sameValue(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!sameValue(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is num && b is num) return a == b;
  return a == b;
}

final class AdminData extends ChangeNotifier {
  AdminData(this.app, {this.debounce = const Duration(milliseconds: 1200)}) {
    _lastSeq = _newestSeq();
    app.addListener(_onApp);
  }

  final HubState app;

  /// Pausa dopo l'ultima modifica prima del salvataggio automatico.
  final Duration debounce;

  /// Chiamati dopo un salvataggio riuscito (quanti campi) o fallito.
  void Function(int fields)? onSaved;
  void Function(Object error)? onSaveError;

  HubSettings? settings;
  Object? settingsError;
  MemberList? members;
  Object? membersError;
  TelegramStatus? telegram;
  Object? telegramError;
  HubUsage? usage;
  Object? usageError;
  SystemInfo? system;
  Object? systemError;

  /// Dettagli dei server (valori propri), caricati con [loadDetails].
  Map<String, SpaceDetails>? details;

  bool _loading = false;
  bool get loading => _loading;
  bool _disposed = false;
  int _lastSeq = 0;

  // --- caricamento ----------------------------------------------------------

  /// Carica tutto in parallelo; un pezzo che fallisce non ferma gli altri.
  Future<void> load() async {
    _loading = true;
    _notify();
    await Future.wait([
      reloadSettings(),
      reloadMembers(),
      reloadTelegram(),
      reloadUsage(),
      reloadSystem(),
    ]);
    _loading = false;
    _notify();
  }

  Future<void> _get<T>(
    Future<T> Function() f,
    void Function(T v) ok,
    void Function(Object e) ko,
  ) async {
    try {
      ok(await f());
    } on Object catch (e) {
      ko(e);
    } finally {
      _notify();
    }
  }

  Future<void> reloadSettings() => _get<HubSettings>(app.api.settings, (v) {
    settings = v;
    settingsError = null;
  }, (e) => settingsError = e);

  Future<void> reloadMembers() => _get<MemberList>(app.api.members, (v) {
    members = v;
    membersError = null;
  }, (e) => membersError = e);

  Future<void> reloadTelegram() => _get<TelegramStatus>(app.api.telegram, (v) {
    telegram = v;
    telegramError = null;
  }, (e) => telegramError = e);

  Future<void> reloadUsage() => _get<HubUsage>(app.api.usage, (v) {
    usage = v;
    usageError = null;
  }, (e) => usageError = e);

  Future<void> reloadSystem() => _get<SystemInfo>(app.api.system, (v) {
    system = v;
    systemError = null;
  }, (e) => systemError = e);

  /// Dettagli di ogni server, per sapere chi ha valori propri.
  Future<void> loadDetails() async {
    final out = <String, SpaceDetails>{};
    Future<void> one(String id) async {
      try {
        out[id] = await app.api.space(id);
      } on Object {
        // un server che non risponde conta come «eredita»
      }
    }

    await Future.wait([for (final sp in app.spaces) one(sp.id)]);
    details = out;
    _notify();
  }

  /// Server con valori propri in [section] (`sessions`, `history`,
  /// `protection`), con i campi sovrascritti.
  List<(SpaceSummary, Map<String, Object?>)> overriding(String section) {
    final d = details;
    if (d == null) return const [];
    return [
      for (final sp in app.spaces)
        if (d[sp.id]?.overrides[section] case final Map<String, Object?> m when m.isNotEmpty)
          (sp, m),
    ];
  }

  /// Aggiorna lo stato di ZTNET dopo «Verifica ora».
  void setZtnet(ZtnetStatus z) {
    final m = members;
    if (m != null) members = MemberList(members: m.members, ztnet: z);
    _notify();
  }

  void setTelegram(TelegramStatus t) {
    telegram = t;
    _notify();
  }

  // --- eventi dal vivo -------------------------------------------------------

  int _newestSeq() => app.events.isEmpty ? 0 : app.events.first.seq;

  void _onApp() {
    final fresh = app.events.takeWhile((e) => e.seq > _lastSeq).toList();
    if (fresh.isEmpty) return;
    _lastSeq = fresh.first.seq;
    final types = {for (final e in fresh) e.type};
    if (types.contains(EventType.settings)) {
      final tg = fresh.any(
        (e) => e.type == EventType.settings && e.data['section'] == telegramSection,
      );
      unawaited(reloadSettings());
      if (tg) unawaited(reloadTelegram());
    }
    if (types.contains(EventType.memberRole) || types.contains(EventType.ztnet)) {
      unawaited(reloadMembers());
    }
    if (types.contains(EventType.telegramError)) unawaited(reloadTelegram());
    if (types.any(
      (t) =>
          t == EventType.gc ||
          t == EventType.push ||
          t == EventType.generationDelete ||
          t == EventType.spaceDelete ||
          t == EventType.disk,
    )) {
      unawaited(reloadUsage());
    }
    if (types.contains(EventType.spaceUpdate) && details != null) unawaited(loadDetails());
  }

  // --- bozze -----------------------------------------------------------------

  final _draft = <String, Map<String, Object?>>{};
  final _was = <String, Object?>{};

  /// Errori per campo (`sezione.campo`), locali o restituiti dall'hub.
  final errors = <String, String>{};
  Timer? _timer;
  bool _saving = false;
  bool get saving => _saving;

  /// Campi in attesa di salvataggio.
  int get pending => _draft.values.fold(0, (n, m) => n + m.length);

  /// Campi in attesa, come chiavi `sezione.campo`.
  List<String> get pendingKeys => [
    for (final s in _draft.entries)
      for (final f in s.value.keys) '${s.key}.$f',
  ];

  Map<String, Object?> _savedSection(String section) {
    if (section == telegramSection) {
      final t = telegram?.settings ?? const TelegramSettings();
      return {
        'enabled': t.enabled,
        'chat': t.chat ?? '',
        'language': t.language,
        'coalesceMinutes': t.coalesceMinutes,
        'pushWarnMinutes': t.pushWarnMinutes,
        for (final e in t.notify.toJson().entries) 'notify.${e.key}': e.value,
        for (final e in t.topics.entries) 'topics.${e.key}': '${e.value}',
      };
    }
    final all = (settings?.sections ?? const SettingsSections()).toJson();
    return _withPercent(section, all[section]! as Map<String, Object?>);
  }

  // la soglia si mostra in percentuale intera: un campo derivato
  static Map<String, Object?> _withPercent(String section, Map<String, Object?> m) =>
      section == 'protection'
      ? {...m, 'massDeletePercent': ((m['massDeleteRatio']! as num) * 100).round()}
      : m;

  /// Valore salvato sull'hub.
  Object? saved(String section, String field) {
    final v = _savedSection(section)[field];
    if (v == null && field.startsWith('topics.')) return '';
    return v;
  }

  /// Valore di fabbrica («Predefinito: …»).
  Object? defaultOf(String section, String field) {
    if (section == telegramSection) {
      const t = TelegramSettings();
      return switch (field) {
        'enabled' => t.enabled,
        'language' => t.language,
        'coalesceMinutes' => t.coalesceMinutes,
        'pushWarnMinutes' => t.pushWarnMinutes,
        _ when field.startsWith('notify.') => true,
        _ => null,
      };
    }
    final all = (settings?.defaults ?? const SettingsSections()).toJson();
    return _withPercent(section, all[section]! as Map<String, Object?>)[field];
  }

  /// Valore mostrato: la bozza se c'è, altrimenti quello salvato.
  Object? value(String section, String field) {
    final d = _draft[section];
    if (d != null && d.containsKey(field)) return d[field];
    return saved(section, field);
  }

  T valueOf<T>(String section, String field) => value(section, field) as T;

  bool isDraft(String section, String field) => _draft[section]?.containsKey(field) ?? false;

  /// Cambiato in questa visita: il valore com'era prima, altrimenti null.
  ({Object? was})? modified(String section, String field) {
    final k = '$section.$field';
    if (!_was.containsKey(k)) return null;
    final was = _was[k];
    return sameValue(was, value(section, field)) ? null : (was: was);
  }

  String? errorOf(String section, String field) => errors['$section.$field'];

  /// Nuovo valore di un campo; [invalid] = testo dell'errore se il valore
  /// scritto non è accettabile (non si salva).
  void set(String section, String field, Object? v, {String? invalid}) {
    final k = '$section.$field';
    final saved = this.saved(section, field);
    _was.putIfAbsent(k, () => saved);
    if (invalid != null) {
      errors[k] = invalid;
      _draft[section]?.remove(field);
      if (_draft[section]?.isEmpty ?? false) _draft.remove(section);
      _notify();
      return;
    }
    errors.remove(k);
    if (sameValue(v, saved)) {
      _draft[section]?.remove(field);
      if (_draft[section]?.isEmpty ?? false) _draft.remove(section);
    } else {
      (_draft[section] ??= {})[field] = v;
    }
    _schedule();
    _notify();
  }

  /// Toglie tutte le bozze («Annulla»).
  void discard() {
    _timer?.cancel();
    errors.clear();
    _draft.clear();
    _notify();
  }

  void _schedule() {
    _timer?.cancel();
    if (_draft.isEmpty) return;
    _timer = Timer(debounce, () => unawaited(flush()));
  }

  /// Salva subito tutte le bozze, una PATCH per sezione.
  Future<void> flush() async {
    _timer?.cancel();
    if (_saving || _draft.isEmpty) return;
    _saving = true;
    _notify();
    var done = 0;
    try {
      for (final section in _draft.keys.toList()) {
        final sent = Map<String, Object?>.of(_draft[section]!);
        try {
          if (section == telegramSection) {
            telegram = await app.api.patchTelegram(_telegramPatch(sent));
          } else {
            settings = await app.api.patchSettings(section, _wire(section, sent));
          }
          final d = _draft[section];
          if (d != null) {
            for (final e in sent.entries) {
              if (sameValue(d[e.key], e.value)) d.remove(e.key);
              errors.remove('$section.${e.key}');
            }
            if (d.isEmpty) _draft.remove(section);
          }
          done += sent.length;
        } on ApiError catch (e) {
          final f = e.details['field'];
          // '' = rifiutato dall'hub: il testo lo sceglie il campo
          if (e.code == ErrorCode.badRequest && f is String) {
            errors[_errorKey(section, f)] = '';
          }
          onSaveError?.call(e);
        } on Object catch (e) {
          onSaveError?.call(e);
          break;
        }
      }
    } finally {
      _saving = false;
      _notify();
    }
    if (done > 0) onSaved?.call(done);
  }

  /// Chiave dell'errore da `details.field` (`general.name`, `topics.x`).
  static String _errorKey(String section, String field) {
    if (section == telegramSection) return '$telegramSection.$field';
    if (field == 'protection.massDeleteRatio') return 'protection.massDeletePercent';
    return field.contains('.') ? field : '$section.$field';
  }

  static Map<String, Object?> _wire(String section, Map<String, Object?> d) {
    if (section != 'protection' || !d.containsKey('massDeletePercent')) return d;
    final out = Map<String, Object?>.of(d)..remove('massDeletePercent');
    out['massDeleteRatio'] = (d['massDeletePercent']! as int) / 100;
    return out;
  }

  TelegramPatch _telegramPatch(Map<String, Object?> d) {
    TelegramNotify? notify;
    if (d.keys.any((k) => k.startsWith('notify.'))) {
      bool n(String k) => value(telegramSection, 'notify.$k')! as bool;
      notify = TelegramNotify(
        open: n('open'),
        close: n('close'),
        alerts: n('alerts'),
        status: n('status'),
      );
    }
    Map<String, String>? topics;
    if (d.keys.any((k) => k.startsWith('topics.'))) {
      topics = {
        for (final sp in app.spaces)
          sp.id: (value(telegramSection, 'topics.${sp.id}') ?? '') as String,
      };
      topics.removeWhere((_, v) => v.trim().isEmpty);
    }
    return TelegramPatch(
      enabled: d['enabled'] as bool?,
      chat: d['chat'] as String?,
      language: d['language'] as String?,
      notify: notify,
      coalesceMinutes: d['coalesceMinutes'] as int?,
      pushWarnMinutes: d['pushWarnMinutes'] as int?,
      topics: topics,
    );
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    // le bozze rimaste si salvano uscendo dalla sezione (senza più avvisare
    // i widget, che non ci sono più)
    _disposed = true;
    onSaved = null;
    onSaveError = null;
    if (_draft.isNotEmpty && !_saving) unawaited(flush());
    _timer?.cancel();
    app.removeListener(_onApp);
    super.dispose();
  }
}

/// Fornisce i dati dell'area Admin alle sezioni.
class AdminScope extends InheritedNotifier<AdminData> {
  const AdminScope({super.key, required AdminData data, required super.child})
    : super(notifier: data);

  static AdminData of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AdminScope>()!.notifier!;

  static AdminData read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AdminScope>()!.notifier!;
}
