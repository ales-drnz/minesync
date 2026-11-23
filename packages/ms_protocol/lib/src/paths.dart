// Validazione dei percorsi dei manifest: la stessa regola su client e hub,
// applicata a tutto ciò che si manda e si riceve. Un percorso valido è anche
// creabile su Windows, macOS e Linux.
import 'dart:convert';

import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Lunghezza massima di un percorso, in byte UTF-8.
const int maxPathBytes = 1024;

/// Prefisso riservato alle cartelle di stato di MineSync: mai sincronizzato.
const String reservedPrefix = '.minesync';

const _forbiddenChars = '<>:"|?*\\';

final _reservedDevice = RegExp(
  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$',
  caseSensitive: false,
);

/// Motivo per cui un percorso non è valido.
enum PathProblem {
  empty,
  tooLong,
  notNfc,
  absolute,
  trailingSlash,
  emptySegment,
  dotSegment,
  controlChar,
  forbiddenChar,
  trailingDotOrSpace,
  reservedName,
  reservedPrefix,
}

/// Ritorna null se [path] è valido, altrimenti il primo problema trovato.
PathProblem? checkPath(String path) {
  if (path.isEmpty) return PathProblem.empty;
  if (utf8.encode(path).length > maxPathBytes) return PathProblem.tooLong;
  if (unorm.nfc(path) != path) return PathProblem.notNfc;
  if (path.startsWith('/')) return PathProblem.absolute;
  if (path.endsWith('/')) return PathProblem.trailingSlash;
  for (final unit in path.codeUnits) {
    if (unit < 0x20 || unit == 0x7f) return PathProblem.controlChar;
    if (_forbiddenChars.contains(String.fromCharCode(unit))) {
      return PathProblem.forbiddenChar;
    }
  }
  final segments = path.split('/');
  if (segments.first.toLowerCase().startsWith(reservedPrefix)) {
    return PathProblem.reservedPrefix;
  }
  for (final s in segments) {
    if (s.isEmpty) return PathProblem.emptySegment;
    if (s == '.' || s == '..') return PathProblem.dotSegment;
    if (s.endsWith('.') || s.endsWith(' ')) return PathProblem.trailingDotOrSpace;
    if (_reservedDevice.hasMatch(s)) return PathProblem.reservedName;
  }
  return null;
}

/// Vero se [path] è valido.
bool isValidPath(String path) => checkPath(path) == null;

/// Chiave di confronto per le collisioni di maiuscole/minuscole: due
/// percorsi con la stessa chiave diventerebbero lo stesso file su Windows e
/// macOS. Si usa la forma NFC in minuscolo (sufficiente per i nomi reali).
String caseFoldKey(String path) => unorm.nfc(path).toLowerCase();

/// Coppie di percorsi in collisione (stessa [caseFoldKey]). Vuoto se nessuna.
List<(String, String)> caseCollisions(Iterable<String> paths) {
  final seen = <String, String>{};
  final out = <(String, String)>[];
  for (final p in paths) {
    final k = caseFoldKey(p);
    final prev = seen[k];
    if (prev != null) {
      out.add((prev, p));
    } else {
      seen[k] = p;
    }
  }
  return out;
}

/// Confronto tra percorsi nell'ordine dei byte UTF-8, che coincide con
/// l'ordine dei code point (non con quello delle unità UTF-16 di Dart).
int comparePaths(String a, String b) {
  final ia = a.runes.iterator, ib = b.runes.iterator;
  while (true) {
    final ha = ia.moveNext(), hb = ib.moveNext();
    if (!ha || !hb) return (ha ? 1 : 0) - (hb ? 1 : 0);
    final d = ia.current - ib.current;
    if (d != 0) return d;
  }
}
