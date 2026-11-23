// Genera lib/src/tokens.g.dart da tokens/tokens.json, la fonte unica dei
// token (la stessa del canvas di design e dell'hub web).
//   dart run tool/gen_tokens.dart          scrive il file
//   dart run tool/gen_tokens.dart --check  esce con 1 se il file non è aggiornato
import 'dart:convert';
import 'dart:io';

String camel(String s) {
  final p = s.split('-');
  return p.first + p.skip(1).map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join();
}

String color(String hex) {
  final h = hex.substring(1);
  final argb = h.length == 6 ? 'ff$h' : '${h.substring(6)}${h.substring(0, 6)}';
  return 'Color(0x$argb)';
}

String generate(Map<String, Object?> t) {
  final b = StringBuffer()
    ..writeln('// GENERATO da tool/gen_tokens.dart a partire da tokens/tokens.json:')
    ..writeln('// non modificare a mano.')
    ..writeln('// ignore_for_file: public_member_api_docs')
    ..writeln()
    ..writeln("import 'dart:ui' show Color;")
    ..writeln();
  final schemes = t['colors']! as Map<String, Object?>;
  final first = schemes.values.first! as Map<String, Object?>;
  final names = first.keys.toList();
  b
    ..writeln('/// Colori di uno schema (palette × tema).')
    ..writeln('final class MsColors {')
    ..writeln('  const MsColors({');
  for (final n in names) {
    b.writeln('    required this.${camel(n)},');
  }
  b.writeln('  });');
  for (final n in names) {
    b
      ..writeln()
      ..writeln('  /// --ms-$n')
      ..writeln('  final Color ${camel(n)};');
  }
  b
    ..writeln('}')
    ..writeln();
  for (final e in schemes.entries) {
    final m = e.value! as Map<String, Object?>;
    if (m.keys.join(',') != names.join(',')) throw StateError('schema ${e.key}: chiavi diverse');
    b.writeln('const MsColors ${camel(e.key)} = MsColors(');
    for (final n in names) {
      b.writeln('  ${camel(n)}: ${color(m[n]! as String)},');
    }
    b
      ..writeln(');')
      ..writeln();
  }
  void ints(String cls, String doc, Map<String, Object?> m, String prefix) {
    b
      ..writeln('/// $doc')
      ..writeln('abstract final class $cls {');
    for (final e in m.entries) {
      b.writeln(
        '  static const double ${prefix.isEmpty ? camel(e.key) : '$prefix${e.key}'} = ${e.value};',
      );
    }
    b
      ..writeln('}')
      ..writeln();
  }

  ints(
    'MsSpace',
    'Spaziature in pixel di design (--ms-s-N).',
    t['space']! as Map<String, Object?>,
    's',
  );
  ints('MsSize', 'Misure fisse in pixel di design.', t['size']! as Map<String, Object?>, '');
  ints('MsZ', 'Livelli di sovrapposizione.', t['z']! as Map<String, Object?>, '');
  b
    ..writeln('/// Durate delle animazioni (--ms-dur-N).')
    ..writeln('abstract final class MsDuration {');
  for (final e in (t['duration']! as Map<String, Object?>).entries) {
    b.writeln('  static const Duration d${e.key} = Duration(milliseconds: ${e.value});');
  }
  b
    ..writeln('}')
    ..writeln()
    ..writeln('/// Scala tipografica: dimensione e interlinea in pixel di design.')
    ..writeln('abstract final class MsTypeScale {');
  for (final e in (t['type']! as Map<String, Object?>).entries) {
    final v = e.value! as Map<String, Object?>;
    b.writeln('  static const (double, double) ${camel(e.key)} = (${v['size']}, ${v['line']});');
  }
  b.writeln('}');
  return b.toString();
}

/// Codice generato e formattato come il resto del workspace.
String formatted(String code) {
  final tmp = Directory.systemTemp.createTempSync('gen_tokens');
  try {
    final f = File('${tmp.path}/tokens.g.dart')..writeAsStringSync(code);
    final r = Process.runSync(Platform.resolvedExecutable, ['format', '-l', '100', f.path]);
    if (r.exitCode != 0) throw StateError('dart format: ${r.stderr}');
    return f.readAsStringSync();
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

void main(List<String> args) {
  final here = File(Platform.script.toFilePath()).parent.parent.path;
  final t = jsonDecode(File('$here/tokens/tokens.json').readAsStringSync()) as Map<String, Object?>;
  final code = formatted(generate(t));
  final out = File('$here/lib/src/tokens.g.dart');
  if (args.contains('--check')) {
    if (!out.existsSync() || out.readAsStringSync() != code) {
      stderr.writeln('tokens.g.dart non è aggiornato: dart run tool/gen_tokens.dart');
      exit(1);
    }
    return;
  }
  out.writeAsStringSync(code);
}
