// Esclusioni di uno spazio: pattern glob valutati allo stesso modo da client
// e hub, su ogni sistema operativo.
//
// Regole (separatore sempre "/", confronto senza maiuscole/minuscole su
// tutti i sistemi, così Windows e Linux escludono gli stessi file):
//   - "nome", "*.lock" (senza "/")  → glob sul nome a qualunque profondità;
//   - "a/b.txt", "config/*.bak"     → glob segmento per segmento dalla radice;
//   - "**" come segmento intero     → zero o più cartelle;
//   - nei segmenti: "*", "?", classi "[abc]", "[a-z]", "[!x]".
// Un file è escluso se un pattern combacia con il suo percorso o se una delle
// sue cartelle è esclusa: la scansione (che pota le cartelle) e il confronto
// con un manifest (che vede solo file) danno sempre la stessa risposta.

/// Pattern di sistema, sempre attivi e non modificabili.
const List<String> systemExclusions = ['.minesync*', '.minesync*/**', '*.minesyncpart'];

/// Esclusioni predefinite del profilo `minecraft`.
const List<String> minecraftExclusions = [
  // diagnostica e file rigenerati a ogni avvio
  'logs/**', 'crash-reports/**', 'debug/**', 'spark/**',
  'hs_err_pid*.log', 'replay_pid*.log', '*.hprof',
  // usercache.json e usernamecache.json si sincronizzano: danno all'hub i
  // nomi dei giocatori
  // il lock del mondo copiato su un'altra macchina fa credere al server che
  // il mondo sia già aperto
  '*.lock',
  // cache dei loader: si rigenerano e contengono jar validi solo lì
  '.fabric/**', '.mixin.out/**', '.cache/**',
  // backup automatici dei mod di backup
  'backups/**', 'simplebackups/**', 'ftbbackups/**', 'ftbbackups2/**',
  'aroma1997/**', 'world_backup*/**',
  // libraries/, versions/ e i runtime inclusi NON si escludono: su Forge e
  // NeoForge libraries/ la crea l'installer e senza il server non parte.
  // file di sistema
  '.DS_Store', '._*', 'Thumbs.db', 'desktop.ini',
  '.Spotlight-V100/**', '.Trashes/**', r'$RECYCLE.BIN/**',
  '.git/**',
];

/// Esclusioni predefinite del profilo `generic`.
const List<String> genericExclusions = ['.DS_Store', 'Thumbs.db', 'desktop.ini', '.git/**'];

final class _Pattern {
  _Pattern(this.raw, this.segs, this.prune);

  /// Il pattern come scritto (senza spazi ai lati).
  final String raw;
  final List<String> segs;

  /// Il pattern può escludere un'intera cartella: quelli che finiscono in
  /// "/**" e i nomi esatti senza caratteri jolly. Un glob sul nome come
  /// "*.lock" esclude solo file.
  final bool prune;
}

/// Insieme compilato di esclusioni.
final class Exclusions {
  /// Compila [patterns] (più quelli di sistema). Righe vuote e commenti
  /// "#" sono ignorati.
  factory Exclusions(Iterable<String> patterns) {
    final out = <_Pattern>[];
    for (final raw in [...systemExclusions, ...patterns]) {
      final written = raw.trim();
      var p = written.replaceAll(r'\', '/');
      if (p.isEmpty || p.startsWith('#')) continue;
      while (p.startsWith('/')) {
        p = p.substring(1);
      }
      p = p.toLowerCase();
      if (p.startsWith('**/')) {
        final rest = p.substring(3);
        if (rest.isNotEmpty && !rest.contains('/')) p = rest;
      }
      if (!p.contains('/')) {
        out.add(_Pattern(written, ['**', p], !_hasWildcard(p)));
      } else {
        out.add(_Pattern(written, p.split('/'), p.endsWith('/**')));
      }
    }
    return Exclusions._(out);
  }

  Exclusions._(this._patterns);

  final List<_Pattern> _patterns;

  /// Vero se il file [path] è escluso.
  bool excludes(String path) => firstMatch(path) != null;

  /// Il primo pattern (come scritto) che esclude il file [path], o null.
  /// Prima i pattern che combaciano con il percorso, poi quelli che
  /// escludono una sua cartella; a parità, nell'ordine della lista (quelli
  /// di sistema per primi).
  String? firstMatch(String path) {
    final segs = _norm(path);
    for (final p in _patterns) {
      if (_globSegs(p.segs, 0, segs, 0)) return p.raw;
    }
    for (var i = 1; i < segs.length; i++) {
      final dir = segs.sublist(0, i);
      for (final p in _patterns) {
        if (p.prune && _globSegs(p.segs, 0, dir, 0)) return p.raw;
      }
    }
    return null;
  }

  /// Vero se l'intera cartella [path] è esclusa (per potare la scansione).
  bool excludesDir(String path) => _dirExcluded(_norm(path));

  bool _dirExcluded(List<String> segs) {
    for (final p in _patterns) {
      if (p.prune && _globSegs(p.segs, 0, segs, 0)) return true;
    }
    return false;
  }

  static List<String> _norm(String path) {
    var p = path.replaceAll(r'\', '/').toLowerCase();
    while (p.startsWith('/')) {
      p = p.substring(1);
    }
    while (p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p.split('/');
  }
}

bool _hasWildcard(String s) => s.contains('*') || s.contains('?') || s.contains('[');

bool _globSegs(List<String> pat, int pi, List<String> segs, int si) {
  while (pi < pat.length) {
    if (pat[pi] == '**') {
      if (pi == pat.length - 1) return true;
      for (var k = si; k <= segs.length; k++) {
        if (_globSegs(pat, pi + 1, segs, k)) return true;
      }
      return false;
    }
    if (si >= segs.length) return false;
    if (!globMatch(pat[pi], segs[si])) return false;
    pi++;
    si++;
  }
  return si == segs.length;
}

/// Glob su un singolo segmento: "*" (qualunque sequenza), "?" (un carattere),
/// classi "[...]" con intervalli e negazione "!" o "^". Un pattern
/// malformato (classe non chiusa) non combacia con niente.
bool globMatch(String pattern, String name) {
  final p = pattern.runes.toList();
  final s = name.runes.toList();
  var pi = 0, si = 0;
  var starP = -1, starS = 0;
  while (si < s.length) {
    if (pi < p.length) {
      final c = p[pi];
      if (c == 0x2a /* * */ ) {
        starP = pi++;
        starS = si;
        continue;
      }
      if (c == 0x3f /* ? */ ) {
        pi++;
        si++;
        continue;
      }
      if (c == 0x5b /* [ */ ) {
        final r = _matchClass(p, pi, s[si]);
        if (r == null) return false;
        if (r.$1) {
          pi = r.$2;
          si++;
          continue;
        }
      } else if (c == s[si]) {
        pi++;
        si++;
        continue;
      }
    }
    if (starP >= 0) {
      pi = starP + 1;
      si = ++starS;
      continue;
    }
    return false;
  }
  while (pi < p.length && p[pi] == 0x2a) {
    pi++;
  }
  return pi == p.length;
}

/// Confronta [ch] con la classe che inizia in p[start] ("["). Restituisce
/// (combacia, indice dopo "]") o null se la classe non è chiusa.
(bool, int)? _matchClass(List<int> p, int start, int ch) {
  var i = start + 1;
  var negate = false;
  if (i < p.length && (p[i] == 0x21 || p[i] == 0x5e)) {
    negate = true;
    i++;
  }
  var matched = false;
  var first = true;
  while (i < p.length && (p[i] != 0x5d || first)) {
    first = false;
    final lo = p[i];
    if (i + 2 < p.length && p[i + 1] == 0x2d && p[i + 2] != 0x5d) {
      if (ch >= lo && ch <= p[i + 2]) matched = true;
      i += 3;
    } else {
      if (ch == lo) matched = true;
      i++;
    }
  }
  if (i >= p.length) return null;
  return (matched != negate, i + 1);
}
