// Metadati delle mod dai loro jar (B-META-02, B-META-03): Forge/NeoForge
// (`META-INF/mods.toml`, `META-INF/neoforge.mods.toml`, sottoinsieme minimo
// di TOML), Fabric (`fabric.mod.json`) e Quilt (`quilt.mod.json`). Tutto ciò
// che sta in un jar è un dato non fidato: le homepage passano da [safeUrl]
// (B-META-05), le icone sono accettate solo se PNG e piccole.
import 'dart:convert';
import 'dart:typed_data';

import 'package:ms_protocol/ms_protocol.dart' show Loader;

import 'zip.dart';

/// Tetto ai file di metadati letti da un jar.
const modMetaMax = 1 << 20;

/// Tetto alle icone (PNG).
const modIconMax = 512 << 10;

/// Metadati dichiarati da una mod.
final class ModMeta {
  const ModMeta({
    this.id,
    this.name,
    this.version,
    this.loader,
    this.mcVersion,
    this.authors = const [],
    this.description,
    this.homepage,
    this.license,
    this.iconPath,
  });

  final String? id;
  final String? name;
  final String? version;
  final Loader? loader;

  /// Versione (o intervallo) di Minecraft richiesta dalle dipendenze.
  final String? mcVersion;
  final List<String> authors;
  final String? description;

  /// Solo http/https ([safeUrl]).
  final String? homepage;
  final String? license;

  /// Percorso dell'icona dentro il jar, se dichiarata.
  final String? iconPath;
}

/// Solo URL assoluti `http`/`https`, senza spazi intorno; tutto il resto
/// (`javascript:`, `data:`, `//host`, `ftp:`, testo) diventa null
/// (B-META-05).
String? safeUrl(String? s) {
  if (s == null) return null;
  final t = s.trim();
  final u = Uri.tryParse(t);
  if (u == null || !u.hasAuthority || u.host.isEmpty) return null;
  final scheme = u.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  // niente spazi o controlli dentro l'URL
  if (t.codeUnits.any((c) => c <= 0x20 || c == 0x7f)) return null;
  return t;
}

/// Vero se [b] inizia con la firma PNG.
bool isPng(List<int> b) =>
    b.length >= 8 &&
    b[0] == 0x89 &&
    b[1] == 0x50 &&
    b[2] == 0x4E &&
    b[3] == 0x47 &&
    b[4] == 0x0D &&
    b[5] == 0x0A &&
    b[6] == 0x1A &&
    b[7] == 0x0A;

/// Legge i metadati di un jar già aperto; null se non ne dichiara.
Future<ModMeta?> readModMeta(ZipArchive jar) async {
  for (final (name, neo) in const [
    ('META-INF/neoforge.mods.toml', true),
    ('META-INF/mods.toml', false),
  ]) {
    final b = await jar.readNamed(name, max: modMetaMax);
    if (b != null) return parseModsToml(utf8.decode(b, allowMalformed: true), neoforge: neo);
  }
  for (final (name, quilt) in const [('fabric.mod.json', false), ('quilt.mod.json', true)]) {
    final b = await jar.readNamed(name, max: modMetaMax);
    if (b == null) continue;
    final m = quilt ? parseQuiltJson(b) : parseFabricJson(b);
    if (m != null) return m;
  }
  return null;
}

/// L'icona [path] del jar se è un PNG di al più [max] byte, altrimenti null.
Future<Uint8List?> readModIcon(ZipArchive jar, String path, {int max = modIconMax}) async {
  final e = jar.find(path.startsWith('/') ? path.substring(1) : path);
  if (e == null) return null;
  final b = await jar.read(e, max: max);
  return b != null && isPng(b) ? b : null;
}

// ---------------------------------------------------------------- Fabric / Quilt

Object? _json(Uint8List b) {
  var s = utf8.decode(b, allowMalformed: true);
  if (s.startsWith('﻿')) s = s.substring(1);
  try {
    return jsonDecode(s);
  } on FormatException {
    // il lettore di Fabric (Gson in modalità tollerante) accetta a capo e
    // tabulazioni grezzi dentro le stringhe: diverse mod reali li hanno nella
    // descrizione. Si riprova con quei caratteri sostituiti dalle sequenze
    // di escape.
    try {
      return jsonDecode(escapeRawControlChars(s));
    } on FormatException {
      return null;
    }
  }
}

/// [s] con i caratteri di controllo grezzi dentro le stringhe JSON resi come
/// sequenze di escape (`\n`, `\t`, `\u0001`…); fuori dalle stringhe nulla
/// cambia.
String escapeRawControlChars(String s) {
  final out = StringBuffer();
  var inString = false, escaped = false;
  for (final c in s.codeUnits) {
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (c == 0x5c) {
        escaped = true;
      } else if (c == 0x22) {
        inString = false;
      } else if (c < 0x20) {
        out.write(switch (c) {
          0x0a => r'\n',
          0x0d => r'\r',
          0x09 => r'\t',
          _ => '\\u${c.toRadixString(16).padLeft(4, '0')}',
        });
        continue;
      }
    } else if (c == 0x22) {
      inString = true;
    }
    out.writeCharCode(c);
  }
  return out.toString();
}

String? _s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;

List<String> _people(Object? v) {
  if (v is String) return [if (v.trim().isNotEmpty) v.trim()];
  if (v is! List<Object?>) return const [];
  return [
    for (final e in v)
      if (_s(e) case final n?)
        n
      else if (e is Map<String, Object?> && _s(e['name']) != null)
        _s(e['name'])!,
  ];
}

String? _license(Object? v) {
  if (v is String) return _s(v);
  if (v is List<Object?>) {
    final l = [for (final e in v) ?_s(e)];
    return l.isEmpty ? null : l.join(', ');
  }
  return null;
}

/// `icon` è una stringa o un oggetto dimensione → percorso: si prende la più
/// grande.
String? _icon(Object? v) {
  if (v is String) return _s(v);
  if (v is Map<String, Object?>) {
    String? best;
    var bestSize = -1;
    for (final e in v.entries) {
      final size = int.tryParse(e.key) ?? 0;
      if (_s(e.value) != null && size > bestSize) {
        best = _s(e.value);
        bestSize = size;
      }
    }
    return best;
  }
  return null;
}

String? _depVersion(Object? deps) {
  if (deps is! Map<String, Object?>) return null;
  final v = deps['minecraft'];
  if (v is String) return _s(v);
  if (v is List<Object?>) {
    final l = [for (final e in v) ?_s(e)];
    return l.isEmpty ? null : l.join(' || ');
  }
  return null;
}

/// `fabric.mod.json` (B-META-03).
ModMeta? parseFabricJson(Uint8List bytes) {
  final j = _json(bytes);
  if (j is! Map<String, Object?>) return null;
  final contact = j['contact'];
  return ModMeta(
    id: _s(j['id']),
    name: _s(j['name']) ?? _s(j['id']),
    version: _s(j['version']),
    loader: Loader.fabric,
    mcVersion: _depVersion(j['depends']),
    authors: _people(j['authors']),
    description: _s(j['description']),
    homepage: contact is Map<String, Object?> ? safeUrl(_s(contact['homepage'])) : null,
    license: _license(j['license']),
    iconPath: _icon(j['icon']),
  );
}

/// `quilt.mod.json`: tutto sta sotto `quilt_loader`, i dati descrittivi
/// sotto `quilt_loader.metadata`.
ModMeta? parseQuiltJson(Uint8List bytes) {
  final j = _json(bytes);
  if (j is! Map<String, Object?>) return null;
  final ql = j['quilt_loader'];
  if (ql is! Map<String, Object?>) return null;
  final md = ql['metadata'] is Map<String, Object?>
      ? ql['metadata']! as Map<String, Object?>
      : const <String, Object?>{};
  final contrib = md['contributors'];
  final contact = md['contact'];
  String? mc;
  final deps = ql['depends'];
  if (deps is List<Object?>) {
    for (final d in deps) {
      if (d is Map<String, Object?> && d['id'] == 'minecraft') {
        final v = d['versions'];
        mc = v is String
            ? _s(v)
            : (v is List<Object?> ? [for (final e in v) ?_s(e)].join(' || ') : null);
      }
    }
  }
  return ModMeta(
    id: _s(ql['id']),
    name: _s(md['name']) ?? _s(ql['id']),
    version: _s(ql['version']),
    loader: Loader.quilt,
    mcVersion: mc == null || mc.isEmpty ? null : mc,
    authors: contrib is Map<String, Object?>
        ? [
            for (final k in contrib.keys)
              if (k.trim().isNotEmpty) k.trim(),
          ]
        : const [],
    description: _s(md['description']),
    homepage: contact is Map<String, Object?> ? safeUrl(_s(contact['homepage'])) : null,
    license: _license(md['license']),
    iconPath: _icon(md['icon']),
  );
}

// ---------------------------------------------------------------- mods.toml

/// Valori di un sottoinsieme di TOML: tabelle `[x]`, array di tabelle
/// `[[x]]`, chiavi `k = v` con stringhe base, letterali e multi-riga,
/// numeri, booleani e array di stringhe. Il resto si salta.
final class _Toml {
  /// Chiavi a livello di file.
  final top = <String, Object?>{};

  /// Ogni tabella (anche negli array) in ordine: nome e chiavi.
  final tables = <(String, Map<String, Object?>)>[];
}

_Toml _parseToml(String text) {
  final t = _Toml();
  var cur = t.top;
  final lines = const LineSplitter().convert(text);
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('[')) {
      final inner = line.startsWith('[[')
          ? line.substring(2, _closing(line, ']]'))
          : line.substring(1, _closing(line, ']'));
      cur = <String, Object?>{};
      t.tables.add((inner.trim().replaceAll('"', ''), cur));
      continue;
    }
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    final key = line.substring(0, eq).trim().replaceAll('"', '');
    final (value, used) = _tomlValue(line.substring(eq + 1).trim(), lines, i);
    i += used;
    cur[key] = value;
  }
  return t;
}

int _closing(String line, String close) {
  final i = line.lastIndexOf(close);
  return i < 0 ? line.length : i;
}

/// Valore che inizia in [v] (riga [i]); restituisce anche le righe in più
/// consumate dalle stringhe multi-riga.
(Object?, int) _tomlValue(String v, List<String> lines, int i) {
  for (final q in const ["'''", '"""']) {
    if (!v.startsWith(q)) continue;
    final rest = v.substring(3);
    final end = rest.indexOf(q);
    if (end >= 0) return (_unescape(rest.substring(0, end), q == '"""'), 0);
    final b = StringBuffer(rest);
    for (var j = i + 1; j < lines.length; j++) {
      final e = lines[j].indexOf(q);
      if (e >= 0) {
        b
          ..write('\n')
          ..write(lines[j].substring(0, e));
        return (
          _unescape(b.toString().replaceFirst(RegExp(r'^\r?\n'), ''), q == '"""').trim(),
          j - i,
        );
      }
      b
        ..write('\n')
        ..write(lines[j]);
    }
    return (_unescape(b.toString(), q == '"""').trim(), lines.length - 1 - i);
  }
  if (v.startsWith('"') || v.startsWith("'")) {
    final q = v[0];
    final b = StringBuffer();
    for (var k = 1; k < v.length; k++) {
      final c = v[k];
      if (q == '"' && c == r'\' && k + 1 < v.length) {
        b.write(_escape(v[++k]));
        continue;
      }
      if (c == q) return (b.toString(), 0);
      b.write(c);
    }
    return (b.toString(), 0);
  }
  if (v.startsWith('[')) {
    final out = <String>[];
    for (final m in RegExp(r'''"((?:[^"\\]|\\.)*)"|'([^']*)' ''').allMatches(v)) {
      out.add(m[1] != null ? _unescape(m[1]!, true) : m[2]!);
    }
    return (out, 0);
  }
  final hash = v.indexOf('#');
  final bare = (hash >= 0 ? v.substring(0, hash) : v).trim();
  if (bare == 'true') return (true, 0);
  if (bare == 'false') return (false, 0);
  return (int.tryParse(bare) ?? bare, 0);
}

String _escape(String c) => switch (c) {
  'n' => '\n',
  't' => '\t',
  'r' => '\r',
  _ => c,
};

String _unescape(String s, bool basic) {
  if (!basic || !s.contains(r'\')) return s;
  final b = StringBuffer();
  for (var k = 0; k < s.length; k++) {
    if (s[k] == r'\' && k + 1 < s.length) {
      b.write(_escape(s[++k]));
    } else {
      b.write(s[k]);
    }
  }
  return b.toString();
}

String? _ts(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;

/// `mods.toml` / `neoforge.mods.toml` (B-META-02): chiavi di file
/// (`license`, `logoFile`) e del primo `[[mods]]`; la versione di Minecraft
/// dal blocco `[[dependencies.<id>]]` con `modId = "minecraft"`.
ModMeta parseModsToml(String text, {bool neoforge = false}) {
  final t = _parseToml(text);
  final mod = t.tables.where((e) => e.$1 == 'mods').map((e) => e.$2).firstOrNull ?? const {};
  final id = _ts(mod['modId']);
  String? mc;
  var neo = neoforge;
  for (final (name, m) in t.tables) {
    if (!name.startsWith('dependencies')) continue;
    if (m['modId'] == 'minecraft') mc ??= _ts(m['versionRange']);
    if (m['modId'] == 'neoforge') neo = true;
  }
  final authors = mod['authors'] ?? t.top['authors'];
  final version = _ts(mod['version']);
  return ModMeta(
    id: id,
    name: _ts(mod['displayName']) ?? id,
    // ${file.jarVersion} è riempito al build: senza MANIFEST non lo sappiamo
    version: version == null || version.contains(r'${') ? null : version,
    loader: neo ? Loader.neoforge : Loader.forge,
    mcVersion: mc,
    authors: switch (authors) {
      final String s => [
        for (final a in s.split(RegExp(r',\s*|\s+and\s+')))
          if (a.trim().isNotEmpty) a.trim(),
      ],
      final List<Object?> l => [for (final a in l) ?_ts(a)],
      _ => const [],
    },
    description: _ts(mod['description']),
    homepage: safeUrl(_ts(mod['displayURL'])),
    license: _ts(t.top['license']),
    iconPath: _ts(mod['logoFile']) ?? _ts(t.top['logoFile']),
  );
}
