// Icone, logo e illustrazioni pixel di ms_ui.
//
// icons/icons.json è la fonte unica (versionata): le bitmap sono state
// estratte dal canvas di design, che sta fuori dal repository.
//
//   dart run tool/gen_icons.dart extract <cartella-canvas>
//       rilegge le bitmap dai file .dc.html del canvas e riscrive icons.json
//       (i nomi delle icone che il canvas non nomina restano quelli già
//       presenti nel JSON; le nuove si chiamano unnamedN e vanno rinominate)
//   dart run tool/gen_icons.dart           scrive lib/src/icons/icons.g.dart
//   dart run tool/gen_icons.dart --check   esce con 1 se il file non è aggiornato
import 'dart:convert';
import 'dart:io';

// ---------------------------------------------------------------------------
// Estrazione dal canvas

final _rectRe = RegExp(r'<rect x="(\d+)" y="(\d+)" width="(\d+)" height="(\d+)"([^>]*)>');
final _icoRe = RegExp(
  r'<svg class="ms-ico[^"]*"[^>]*viewBox="0 0 (\d+) (\d+)"[^>]*>(.*?)</svg>',
  dotAll: true,
);
final _galleryLabelRe = RegExp(r'^</span><span class="ms-mono ms-text-2"[^>]*>([a-z][a-z0-9]*)<');

/// Ruoli del logo: variabile --ic-* del canvas -> lettera nel JSON.
const _logoRoles = {'o': 'o', 'HH': 'h', 'GG': 'g', 'AA': 'a', 'ZZ': 'z', 'NN': 'n'};

/// Nomi dei ruoli del logo nel JSON (ordine = indice del ruolo nel codice).
const _logoRoleNames = {
  'o': 'outline',
  'h': 'light',
  'g': 'accent',
  'a': 'dark',
  'z': 'side',
  'n': 'engrave',
};

/// Ruoli delle illustrazioni (classi .ms-logo, token --ms-logo-*).
const _artRoles = ['o', 'h', 'g', 'd', 'k', 'w'];

/// Illustrazioni degli stati vuoti: etichetta nel canvas -> nome.
const _artNames = {'Blocco crepato': 'crackedBlock', 'Isola vuota': 'emptyIsland'};

/// Svg del logo "Blocco Sync" (proposta A) per griglia.
const _logoLabels = {16: 'Blocco Sync, 16 px', 32: 'Blocco Sync, 32 px', 64: 'Blocco Sync, 128 px'};

List<List<String>> _blank(int w, int h, String fill) => [
  for (var y = 0; y < h; y++) List.filled(w, fill),
];

void _paint(List<List<String>> g, String inner, String Function(String attrs) role) {
  for (final m in _rectRe.allMatches(inner)) {
    final [x, y, w, h] = [for (var i = 1; i <= 4; i++) int.parse(m.group(i)!)];
    final r = role(m.group(5)!);
    for (var yy = y; yy < y + h; yy++) {
      for (var xx = x; xx < x + w; xx++) {
        g[yy][xx] = r;
      }
    }
  }
}

List<String> _rows(List<List<String>> g) => [for (final r in g) r.join()];

/// Contenuto dell'svg senza i rettangoli (deve restare vuoto o quasi).
String _residue(String inner) => inner.replaceAll(_rectRe, '').replaceAll('</rect>', '');

Never _fail(String msg) {
  stderr.writeln('gen_icons: $msg');
  exit(1);
}

Map<String, Object?> extract(Directory canvas, Map<String, Object?>? previous) {
  final files =
      canvas.listSync().whereType<File>().where((f) => f.path.endsWith('.dc.html')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  if (files.isEmpty) _fail('nessun file .dc.html in ${canvas.path}');

  // Icone 8x8 a un colore.
  final named = <String, String>{}; // bitmap -> nome dalla galleria
  final order = <String>[]; // bitmap in ordine di comparsa
  final rows = <String, List<String>>{};
  for (final f in files) {
    final s = f.readAsStringSync();
    for (final m in _icoRe.allMatches(s)) {
      final w = int.parse(m.group(1)!), h = int.parse(m.group(2)!);
      final inner = m.group(3)!;
      if (_residue(inner).trim().isNotEmpty) {
        _fail('${f.path}: svg.ms-ico con elementi diversi da <rect>');
      }
      final g = _blank(w, h, '.');
      _paint(g, inner, (attrs) {
        if (attrs.trim().isNotEmpty) _fail('${f.path}: <rect$attrs> inatteso in un\'icona');
        return '#';
      });
      final r = _rows(g);
      final key = r.join('/');
      if (!rows.containsKey(key)) {
        rows[key] = r;
        order.add(key);
      }
      final label = _galleryLabelRe.firstMatch(s.substring(m.end))?.group(1);
      if (label != null) {
        final old = named[key];
        if (old != null && old != label) _fail('la stessa icona si chiama $old e $label');
        if (named.containsValue(label) && old == null) {
          _fail('due icone diverse si chiamano $label');
        }
        named[key] = label;
      }
    }
  }

  // Nomi già scelti nel JSON per le icone che il canvas non nomina.
  final prevIcons = (previous?['icons'] as Map<String, Object?>?) ?? {};
  final prevNames = {
    for (final e in prevIcons.entries) (e.value! as List<Object?>).join('/'): e.key,
  };
  final icons = <String, List<String>>{};
  final gallery = order.where(named.containsKey).toList();
  final others = <String, List<String>>{};
  var unnamed = 0;
  for (final key in order.where((k) => !named.containsKey(k))) {
    var name = prevNames[key];
    if (name == null || named.containsValue(name)) {
      name = 'unnamed${++unnamed}';
      stderr.writeln('gen_icons: icona senza nome ($name), rinominala in icons.json:');
      for (final r in rows[key]!) {
        stderr.writeln('    $r');
      }
    }
    if (others.containsKey(name)) _fail('nome ripetuto: $name');
    others[name] = rows[key]!;
  }
  for (final key in gallery) {
    icons[named[key]!] = rows[key]!;
  }
  for (final name in others.keys.toList()..sort()) {
    icons[name] = others[name]!;
  }

  // Logo "Blocco Sync" e sue palette (Identity.dc.html).
  final identity = File('${canvas.path}/Identity.dc.html');
  if (!identity.existsSync()) _fail('manca Identity.dc.html');
  final id = identity.readAsStringSync();
  final grids = <String, List<String>>{};
  for (final MapEntry(key: size, value: label) in _logoLabels.entries) {
    final re = RegExp(
      '<svg [^>]*viewBox="0 0 $size $size" role="img" aria-label="${RegExp.escape(label)}"'
      r'[^>]*>(.*?)</svg>',
      dotAll: true,
    );
    final found = re.allMatches(id).map((m) => m.group(1)!).toList();
    if (found.isEmpty) _fail('logo "$label" non trovato');
    List<String>? first;
    for (final inner in found) {
      final g = _blank(size, size, '.');
      final groups = RegExp(
        r'<g style="fill:var\(--ic-(\w+)\)">(.*?)</g>',
        dotAll: true,
      ).allMatches(inner).toList();
      final rest = inner.replaceAll(RegExp(r'<g style="[^"]*">.*?</g>', dotAll: true), '');
      if (rest.trim().isNotEmpty) _fail('logo "$label": elementi fuori dai gruppi');
      for (final gm in groups) {
        final role = _logoRoles[gm.group(1)!] ?? _fail('logo: ruolo --ic-${gm.group(1)} inatteso');
        _paint(g, gm.group(2)!, (_) => role);
      }
      final r = _rows(g);
      if (first != null && first.join() != r.join()) _fail('logo "$label": versioni diverse');
      first = r;
    }
    grids['$size'] = first!;
  }
  final styles = RegExp(r'const styles = \{(.*?)\};').firstMatch(id)?.group(1);
  if (styles == null) _fail('palette del logo non trovate');
  final palettes = <String, Map<String, String>>{};
  for (final pm in RegExp(r'"(\w+)": "([^"]*)"').allMatches(styles)) {
    final vars = {
      for (final v in RegExp(r'--ic-(\w+):(#[0-9a-fA-F]{6})').allMatches(pm.group(2)!))
        v.group(1)!: v.group(2)!.toLowerCase(),
    };
    palettes[pm.group(1)!] = {
      for (final MapEntry(:key, :value) in _logoRoles.entries)
        _logoRoleNames[value]!: vars[key] ?? _fail('palette ${pm.group(1)}: manca --ic-$key'),
    };
  }
  if (!palettes.containsKey('prato') || !palettes.containsKey('abisso')) {
    _fail('palette del logo incomplete: ${palettes.keys}');
  }

  // Illustrazioni degli stati vuoti (svg.ms-empty__art.ms-logo, griglia 16).
  final arts = <String, List<String>>{};
  final artRe = RegExp(
    r'<svg class="ms-empty__art ms-logo" viewBox="0 0 (\d+) (\d+)"[^>]*aria-label="([^"]+)"[^>]*>(.*?)</svg>',
    dotAll: true,
  );
  for (final f in files) {
    for (final m in artRe.allMatches(f.readAsStringSync())) {
      final name = _artNames[m.group(3)!] ?? _fail('illustrazione "${m.group(3)}" senza nome');
      final g = _blank(int.parse(m.group(1)!), int.parse(m.group(2)!), '.');
      if (_residue(m.group(4)!).trim().isNotEmpty) _fail('$name: elementi diversi da <rect>');
      _paint(g, m.group(4)!, (attrs) {
        final c = RegExp(r'^ class="(\w)"$').firstMatch(attrs)?.group(1);
        if (c == null || !_artRoles.contains(c)) _fail('$name: <rect$attrs> inatteso');
        return c;
      });
      final r = _rows(g);
      if (arts.containsKey(name) && arts[name]!.join() != r.join()) {
        _fail('$name: versioni diverse nel canvas');
      }
      arts[name] = r;
    }
  }

  return {
    'v': 1,
    'source':
        'MineSync 0.1 design canvas: svg.ms-ico (icons, ink = currentColor), '
        'Identity.dc.html proposal A "Blocco Sync" (logo), svg.ms-empty__art (arts, --ms-logo-* roles)',
    'icons': icons,
    'logo': {'roles': _logoRoleNames, 'palettes': palettes, 'grids': grids},
    'arts': {
      'roles': {for (final r in _artRoles) r: '--ms-logo-$r'},
      'items': {for (final k in arts.keys.toList()..sort()) k: arts[k]},
    },
  };
}

// ---------------------------------------------------------------------------
// Generazione del codice Dart

/// Corse orizzontali `x, y, lunghezza[, ruolo]` delle celle diverse da '.'.
List<int> runs(List<String> rows, {String Function(String)? role, List<String>? roles}) {
  final out = <int>[];
  for (var y = 0; y < rows.length; y++) {
    final r = rows[y];
    var x = 0;
    while (x < r.length) {
      final c = r[x];
      if (c == '.') {
        x++;
        continue;
      }
      var e = x + 1;
      while (e < r.length && r[e] == c) {
        e++;
      }
      out.addAll([x, y, e - x]);
      if (roles != null) {
        final i = roles.indexOf(c);
        if (i < 0) throw StateError('ruolo "$c" sconosciuto');
        out.add(i);
      }
      x = e;
    }
  }
  return out;
}

String _hex(String rgb) => '0xff${rgb.substring(1)}';

void _check(List<String> rows, int w, int h, String what) {
  if (rows.length != h || rows.any((r) => r.length != w)) {
    throw StateError('$what: attese $h righe da $w celle');
  }
}

/// `head[` + interi + `]tail`, su una riga se ci sta, altrimenti a capo entro
/// 100 colonne (la zona generata è fuori dal formattatore).
String _lit(String indent, String head, List<int> ints, String tail) {
  final one = '$indent$head[${ints.join(', ')}]$tail';
  if (one.length <= 100) return one;
  final b = StringBuffer('$indent$head[\n');
  var line = '$indent  ';
  for (final v in ints) {
    final item = '$v,';
    if (line.length + item.length > 100) {
      b.writeln(line.trimRight());
      line = '$indent  ';
    }
    line += '$item ';
  }
  b
    ..writeln(line.trimRight())
    ..write('$indent]$tail');
  return b.toString();
}

/// Disegno della bitmap per la documentazione.
String _picture(String indent, List<String> rows, String Function(String c) cell) => [
  '$indent/// ```text',
  for (final r in rows) '$indent/// ${r.split('').map(cell).join()}',
  '$indent/// ```',
].join('\n');

String generate(Map<String, Object?> j) {
  final b = StringBuffer()
    ..writeln('// GENERATO da tool/gen_icons.dart a partire da icons/icons.json:')
    ..writeln('// non modificare a mano.')
    ..writeln()
    ..writeln("import 'icon_data.dart';")
    ..writeln()
    ..writeln('// dart format off')
    ..writeln()
    ..writeln('/// Pixel icons of the design canvas (8 × 8 cells, drawn in one colour).')
    ..writeln('abstract final class MsIcons {');
  final icons = j['icons']! as Map<String, Object?>;
  for (final MapEntry(:key, :value) in icons.entries) {
    final rows = (value! as List<Object?>).cast<String>();
    _check(rows, 8, 8, key);
    b
      ..writeln(_picture('  ', rows, (c) => c == '.' ? '·' : '█'))
      ..writeln(_lit('  ', "static const $key = MsIconData('$key', 8, 8, ", runs(rows), ');'))
      ..writeln();
  }
  b
    ..writeln('  /// Every icon, in canvas order.')
    ..writeln('  static const values = <MsIconData>[');
  for (final k in icons.keys) {
    b.writeln('    $k,');
  }
  b
    ..writeln('  ];')
    ..writeln('}')
    ..writeln();

  final logo = j['logo']! as Map<String, Object?>;
  final roleMap = logo['roles']! as Map<String, Object?>;
  final roles = roleMap.keys.toList();
  final grids = logo['grids']! as Map<String, Object?>;
  b
    ..writeln('/// The "Sync block" logo: three drawings, not one scaled down. Runs carry')
    ..writeln('/// the roles of [MsLogoPalette.roles] (${roleMap.values.join(', ')}).')
    ..writeln('const msLogoArt = MsLogoArt(');
  for (final size in [16, 32, 64]) {
    final rows = (grids['$size']! as List<Object?>).cast<String>();
    _check(rows, size, size, 'logo $size');
    b.writeln(_lit('  ', 'grid$size: MsPixelArt($size, $size, ', runs(rows, roles: roles), '),'));
  }
  b
    ..writeln(');')
    ..writeln();
  final palettes = logo['palettes']! as Map<String, Object?>;
  for (final MapEntry(:key, :value) in palettes.entries) {
    final p = value! as Map<String, Object?>;
    b
      ..writeln('/// Logo colours of the $key palette (same in dark and light themes).')
      ..writeln('const msLogo${key[0].toUpperCase()}${key.substring(1)} = MsLogoPalette(');
    for (final r in roleMap.values) {
      b.writeln('  $r: ${_hex(p[r]! as String)},');
    }
    b
      ..writeln(');')
      ..writeln();
  }

  final arts = j['arts']! as Map<String, Object?>;
  final artRoles = (arts['roles']! as Map<String, Object?>).keys.toList();
  b
    ..writeln('/// Empty-state illustrations, coloured with the `--ms-logo-*` tokens')
    ..writeln('/// (roles: ${artRoles.join(', ')}).')
    ..writeln('abstract final class MsArts {');
  final items = (arts['items']! as Map<String, Object?>).entries.toList();
  for (final (i, MapEntry(:key, :value)) in items.indexed) {
    final rows = (value! as List<Object?>).cast<String>();
    _check(rows, rows.first.length, rows.length, key);
    if (i > 0) b.writeln();
    b
      ..writeln(_picture('  ', rows, (c) => c == '.' ? '·' : c))
      ..writeln(
        _lit(
          '  ',
          'static const $key = MsPixelArt(${rows.first.length}, ${rows.length}, ',
          runs(rows, roles: artRoles),
          ');',
        ),
      );
  }
  b
    ..writeln('}')
    ..writeln()
    ..writeln('// dart format on');
  return b.toString();
}

/// Codice generato e formattato come il resto del workspace.
String formatted(String code) {
  final tmp = Directory.systemTemp.createTempSync('gen_icons');
  try {
    final f = File('${tmp.path}/icons.g.dart')..writeAsStringSync(code);
    final r = Process.runSync(Platform.resolvedExecutable, ['format', '-l', '100', f.path]);
    if (r.exitCode != 0) throw StateError('dart format: ${r.stderr}');
    return f.readAsStringSync();
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

void main(List<String> args) {
  final here = File(Platform.script.toFilePath()).parent.parent.path;
  final json = File('$here/icons/icons.json');
  if (args.isNotEmpty && args.first == 'extract') {
    if (args.length != 2) _fail('uso: dart run tool/gen_icons.dart extract <cartella-canvas>');
    final prev = json.existsSync()
        ? jsonDecode(json.readAsStringSync()) as Map<String, Object?>
        : null;
    final j = extract(Directory(args[1]), prev);
    json
      ..createSync(recursive: true)
      ..writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(j)}\n');
    stdout.writeln('icons.json: ${(j['icons']! as Map).length} icone');
    return;
  }
  final code = formatted(generate(jsonDecode(json.readAsStringSync()) as Map<String, Object?>));
  final out = File('$here/lib/src/icons/icons.g.dart');
  if (args.contains('--check')) {
    if (!out.existsSync() || out.readAsStringSync() != code) {
      stderr.writeln('icons.g.dart non è aggiornato: dart run tool/gen_icons.dart');
      exit(1);
    }
    return;
  }
  out.writeAsStringSync(code);
}
