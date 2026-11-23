// Impostazioni dell'hub (settings.json): sezioni con uno schema, validate a
// ogni scrittura e applicate subito. Le sezioni sessions, history e
// protection si possono sovrascrivere per singolo spazio (overrides di
// space.json). Telegram non è una sezione di questo documento: ha i suoi
// endpoint e il suo file.
import 'package:ms_protocol/ms_protocol.dart';

/// Un campo di una sezione: tipo, valori ammessi e default.
final class _Field {
  const _Field.integer(this.name, this.def, {required int min, required int max})
    : kind = _Kind.integer,
      minV = min,
      maxV = max,
      choices = const [];
  const _Field.ratio(this.name, this.def)
    : kind = _Kind.ratio,
      minV = 0,
      maxV = 1,
      choices = const [];
  const _Field.text(this.name, this.def, {required int max})
    : kind = _Kind.text,
      minV = 1,
      maxV = max,
      choices = const [];
  const _Field.boolean(this.name, this.def)
    : kind = _Kind.boolean,
      minV = 0,
      maxV = 0,
      choices = const [];
  const _Field.choice(this.name, this.def, this.choices) : kind = _Kind.choice, minV = 0, maxV = 0;
  const _Field.patterns(this.name, this.def)
    : kind = _Kind.patterns,
      minV = 0,
      maxV = 500,
      choices = const [];

  final String name;
  final Object def;
  final _Kind kind;
  final num minV;
  final num maxV;
  final List<String> choices;

  /// Il valore validato, o un messaggio d'errore.
  (Object?, String?) check(Object? v) {
    switch (kind) {
      case _Kind.integer:
        if (v is! int) return (null, 'expected an integer');
        if (v < minV || v > maxV) return (null, 'must be between $minV and $maxV');
        return (v, null);
      case _Kind.ratio:
        if (v is! num) return (null, 'expected a number');
        final d = v.toDouble();
        if (!(d > 0 && d <= 1)) return (null, 'must be greater than 0 and at most 1');
        return (d, null);
      case _Kind.text:
        if (v is! String) return (null, 'expected a string');
        final t = v.trim();
        if (t.isEmpty || t.runes.length > maxV) return (null, 'must be 1 to $maxV characters');
        if (t.codeUnits.any((c) => c < 0x20 || c == 0x7f)) {
          return (null, 'control characters are not allowed');
        }
        return (t, null);
      case _Kind.boolean:
        if (v is! bool) return (null, 'expected true or false');
        return (v, null);
      case _Kind.choice:
        if (v is! String || !choices.contains(v)) {
          return (null, 'must be one of ${choices.join(', ')}');
        }
        return (v, null);
      case _Kind.patterns:
        if (v is! List<Object?> || v.any((e) => e is! String)) {
          return (null, 'expected a list of patterns');
        }
        if (v.length > maxV) return (null, 'at most $maxV patterns');
        final out = <String>[];
        for (final e in v.cast<String>()) {
          if (e.contains('\n') || e.contains('\r') || e.contains('\x00')) {
            return (null, 'a pattern cannot contain line breaks');
          }
          final t = e.trim();
          if (t.isEmpty) continue;
          if (t.length > 256) return (null, 'a pattern can be at most 256 characters');
          // i pattern di sistema valgono sempre e non fanno parte della lista
          if (systemExclusions.contains(t)) continue;
          out.add(t);
        }
        return (List<String>.unmodifiable(out), null);
    }
  }
}

enum _Kind { integer, ratio, text, boolean, choice, patterns }

/// Schema delle sezioni, nell'ordine dell'area Admin ([settingsSections]).
/// I default sono quelli di [SettingsSections] di ms_protocol.
const Map<String, List<_Field>> _schema = {
  'general': [
    _Field.text('name', 'MineSync', max: 40),
    _Field.choice('language', 'auto', hubLanguages),
  ],
  'members': [
    _Field.integer('trustHours', 24, min: 0, max: 8760),
    _Field.integer('refreshSeconds', 30, min: 10, max: 3600),
  ],
  'history': [
    _Field.integer('keepLast', 30, min: 1, max: 10000),
    _Field.integer('keepHours', 24, min: 0, max: 24 * 365),
    _Field.integer('keepDays', 7, min: 0, max: 3650),
  ],
  'disk': [
    _Field.integer('minFreeGiB', 1, min: 0, max: 100000),
    _Field.integer('minFreePercent', 2, min: 0, max: 50),
  ],
  'sessions': [
    _Field.integer('autosaveMinutes', 5, min: 1, max: 1440),
    _Field.boolean('autostop', true),
    _Field.integer('autostopMinutes', 30, min: 1, max: 1440),
    _Field.integer('crashRestarts', 2, min: 0, max: 10),
    _Field.boolean('portTest', true),
  ],
  'protection': [
    _Field.ratio('massDeleteRatio', 0.5),
    _Field.integer('massDeleteMinFiles', 20, min: 0, max: 100000000),
  ],
  'exclusions': [
    _Field.patterns('minecraft', minecraftExclusions),
    _Field.patterns('generic', genericExclusions),
  ],
  'stats': [_Field.integer('sessionsKept', 40, min: 1, max: 1000)],
};

/// Sezioni che uno spazio può sovrascrivere.
final Set<String> overridableSections = overridableSettingsSections.toSet();

/// Documento delle impostazioni, immutabile.
final class Settings {
  Settings._(this._data);

  /// Tutti i valori predefiniti.
  factory Settings.defaults() => Settings._({
    for (final s in _schema.entries) s.key: {for (final f in s.value) f.name: f.def},
  });

  /// Carica le sezioni salvate: i campi mancanti o non validi prendono il
  /// default (un file scritto da una versione futura non blocca l'hub).
  factory Settings.fromJson(Object? json) {
    final base = Settings.defaults()._data;
    if (json is Map<String, Object?>) {
      for (final s in _schema.entries) {
        final sec = json[s.key];
        if (sec is! Map<String, Object?>) continue;
        for (final f in s.value) {
          if (!sec.containsKey(f.name)) continue;
          final (v, err) = f.check(sec[f.name]);
          if (err == null) base[s.key]![f.name] = v!;
        }
      }
    }
    return Settings._(base);
  }

  final Map<String, Map<String, Object>> _data;

  /// Le sezioni come JSON (forma di [SettingsSections]).
  Map<String, Object?> toJson() => {
    for (final s in _data.entries) s.key: Map<String, Object>.of(s.value),
  };

  /// Vista tipizzata.
  late final SettingsSections sections = SettingsSections.fromJson(toJson());

  /// Una sezione (copia).
  Map<String, Object?> section(String name) => Map.of(_data[name] ?? const {});

  String get hubName => _data['general']!['name']! as String;
  String get language => _data['general']!['language']! as String;
  int get keepLast => _data['history']!['keepLast']! as int;
  int get keepHours => _data['history']!['keepHours']! as int;
  int get keepDays => _data['history']!['keepDays']! as int;
  double get massDeleteRatio => _data['protection']!['massDeleteRatio']! as double;
  int get massDeleteMinFiles => _data['protection']!['massDeleteMinFiles']! as int;
  DiskSettings get disk => sections.disk;
  MembersSettings get members => sections.members;
  int get sessionsKept => _data['stats']!['sessionsKept']! as int;

  /// Esclusioni del profilo [p] (senza quelle di sistema).
  List<String> exclusionsOf(Profile p) => sections.exclusions.of(p);

  /// Le sezioni sovrascrivibili di uno spazio.
  SpaceSettings get spaceSettings => SpaceSettings(
    sessions: sections.sessions,
    history: sections.history,
    protection: sections.protection,
  );

  /// Nuove impostazioni con [patch] applicata alla sezione [name]. Lancia
  /// [ApiError] `not_found` per una sezione sconosciuta, `bad_request` per un
  /// campo sconosciuto o non valido (`details.field`).
  Settings patched(String name, Object? patch) {
    if (!_schema.containsKey(name)) {
      throw ApiError(ErrorCode.notFound, 'no such settings section: $name');
    }
    return withValues(name, validateSection(name, patch));
  }

  /// Nuove impostazioni con i valori già validati [values] nella sezione [name].
  Settings withValues(String name, Map<String, Object> values) {
    final out = {for (final s in _data.entries) s.key: Map<String, Object>.of(s.value)};
    out[name]!.addAll(values);
    return Settings._(out);
  }

  /// Valori effettivi di uno spazio: queste impostazioni più [overrides].
  Settings withOverrides(Map<String, Object?> overrides) {
    if (overrides.isEmpty) return this;
    final out = {for (final s in _data.entries) s.key: Map<String, Object>.of(s.value)};
    for (final e in overrides.entries) {
      final sec = e.value;
      if (!overridableSections.contains(e.key) || sec is! Map<String, Object?>) continue;
      for (final f in _schema[e.key]!) {
        if (!sec.containsKey(f.name)) continue;
        final (v, err) = f.check(sec[f.name]);
        if (err == null) out[e.key]![f.name] = v!;
      }
    }
    return Settings._(out);
  }
}

/// Vero se [name] è una sezione di `PATCH /settings/{section}`.
bool isSettingsSection(String name) => _schema.containsKey(name);

/// Valida un aggiornamento parziale della sezione [name] e restituisce i
/// valori normalizzati. Lancia [ApiError] `bad_request`.
Map<String, Object> validateSection(String name, Object? patch, {String prefix = ''}) {
  final fields = _schema[name];
  if (fields == null) {
    throw ApiError(
      ErrorCode.badRequest,
      'unknown section: $name',
      details: {'field': '$prefix$name'},
    );
  }
  if (patch is! Map<String, Object?>) {
    throw ApiError(
      ErrorCode.badRequest,
      '$prefix$name: expected a JSON object',
      details: {'field': '$prefix$name'},
    );
  }
  final out = <String, Object>{};
  for (final e in patch.entries) {
    final f = fields.where((f) => f.name == e.key).firstOrNull;
    if (f == null) {
      throw ApiError(
        ErrorCode.badRequest,
        'unknown field $prefix$name.${e.key}',
        details: {'field': '$prefix$name.${e.key}'},
      );
    }
    final (v, err) = f.check(e.value);
    if (err != null) {
      throw ApiError(
        ErrorCode.badRequest,
        '$prefix$name.${e.key}: $err',
        details: {'field': '$prefix$name.${e.key}'},
      );
    }
    out[e.key] = v!;
  }
  return out;
}

/// Applica un aggiornamento degli overrides di uno spazio a quelli
/// attuali [current]. [patch] è `{sessions?, history?, protection?}`: ogni
/// sezione presente sostituisce quella salvata (campi assenti = ereditati;
/// `{}` o null = tutta la sezione ereditata); le sezioni non nominate restano
/// come sono. Lancia [ApiError] `bad_request` (`details.field`
/// `overrides.<sezione>[.<campo>]`).
Map<String, Object?> mergeOverrides(Map<String, Object?> current, Object? patch) {
  if (patch is! Map<String, Object?>) {
    throw const ApiError(
      ErrorCode.badRequest,
      'overrides: expected a JSON object',
      details: {'field': 'overrides'},
    );
  }
  final out = <String, Object?>{
    for (final e in current.entries)
      if (overridableSections.contains(e.key)) e.key: e.value,
  };
  for (final e in patch.entries) {
    if (!overridableSections.contains(e.key)) {
      throw ApiError(
        ErrorCode.badRequest,
        'overrides: section ${e.key} cannot be overridden',
        details: {'field': 'overrides.${e.key}'},
      );
    }
    final sec = e.value == null
        ? const <String, Object>{}
        : validateSection(e.key, e.value, prefix: 'overrides.');
    if (sec.isEmpty) {
      out.remove(e.key);
    } else {
      out[e.key] = sec;
    }
  }
  return out;
}

/// Valori e campi cambiati di un aggiornamento, per l'evento `settings`.
/// Per le esclusioni solo i nomi dei campi (le liste sono lunghe).
Map<String, Object?> settingsEventData(String section, Map<String, Object> values) => {
  'section': section,
  'fields': values.keys.toList(),
  if (section != 'exclusions') 'values': values,
};
