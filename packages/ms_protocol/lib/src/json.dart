// Helper di decodifica dei modelli di Admin, storia e mondo: come quelli di models.dart,
// stretti. Un campo obbligatorio mancante o del tipo sbagliato è un
// FormatException; un campo facoltativo può mancare (o essere null), ma se
// c'è deve avere il tipo giusto. Non esportati dal pacchetto.
import 'models.dart' show obj;

bool boolean(Map<String, Object?> m, String k) {
  final v = m[k];
  return v is bool ? v : throw FormatException('$k: atteso un booleano');
}

/// Numero (intero o decimale) come double.
double number(Map<String, Object?> m, String k) {
  final v = m[k];
  return v is num ? v.toDouble() : throw FormatException('$k: atteso un numero');
}

String? optStr(Map<String, Object?> m, String k) {
  final v = m[k];
  if (v == null || v is String) return v as String?;
  throw FormatException('$k: attesa una stringa');
}

int? optInt(Map<String, Object?> m, String k) {
  final v = m[k];
  if (v == null || v is int) return v as int?;
  throw FormatException('$k: atteso un intero');
}

bool? optBool(Map<String, Object?> m, String k) {
  final v = m[k];
  if (v == null || v is bool) return v as bool?;
  throw FormatException('$k: atteso un booleano');
}

/// Oggetto facoltativo: null se manca.
Map<String, Object?>? optObj(Map<String, Object?> m, String k) =>
    m[k] == null ? null : obj(m[k], k);

/// Lista obbligatoria di oggetti decodificati con [f].
List<T> listOf<T>(Map<String, Object?> m, String k, T Function(Object?) f) {
  final v = m[k];
  if (v is! List<Object?>) throw FormatException('$k: attesa una lista');
  return [for (final e in v) f(e)];
}

/// Lista facoltativa: vuota se manca.
List<T> optListOf<T>(Map<String, Object?> m, String k, T Function(Object?) f) =>
    m[k] == null ? const [] : listOf(m, k, f);

/// Mappa stringa → intero (es. topic per spazio).
Map<String, int> intMap(Map<String, Object?> m, String k) {
  final v = m[k];
  if (v == null) return const {};
  final o = obj(v, k);
  return {
    for (final e in o.entries)
      e.key: e.value is int
          ? e.value! as int
          : throw FormatException('$k.${e.key}: atteso un intero'),
  };
}

/// Valore di un enum dal suo nome.
T enumOf<T extends Enum>(List<T> values, Object? v, String what) => values.firstWhere(
  (e) => e.name == v,
  orElse: () => throw FormatException('$what sconosciuto: $v'),
);
