// server.properties ed eula.txt: formato .properties di Java (commenti con
// # o !, separatori = : o spazio, escape \uXXXX, righe continuate con \).
import 'dart:convert';
import 'dart:io';

import 'package:ms_core/ms_core.dart' show writeAtomic;
import 'package:path/path.dart' as p;

/// Porta di default di un server Java Edition.
const int defaultServerPort = 25565;

/// Interpreta un testo in formato .properties. Tiene tutte le chiavi, anche
/// quelle sconosciute, nell'ordine del file; l'ultima occorrenza vince.
Map<String, String> parseProperties(String text) {
  final out = <String, String>{};
  if (text.startsWith('﻿')) text = text.substring(1);
  final lines = const LineSplitter().convert(text);
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trimLeft();
    if (line.isEmpty || line.startsWith('#') || line.startsWith('!')) continue;
    // continuazione: un numero dispari di \ in fondo alla riga
    while (_endsWithContinuation(line) && i + 1 < lines.length) {
      line = line.substring(0, line.length - 1) + lines[++i].trimLeft();
    }
    if (_endsWithContinuation(line)) line = line.substring(0, line.length - 1);
    final (key, value) = _splitEntry(line);
    out[_unescape(key)] = _unescape(value);
  }
  return out;
}

bool _endsWithContinuation(String line) {
  var n = 0;
  for (var i = line.length - 1; i >= 0 && line[i] == r'\'; i--) {
    n++;
  }
  return n.isOdd;
}

(String, String) _splitEntry(String line) {
  var i = 0;
  while (i < line.length) {
    final c = line[i];
    if (c == r'\') {
      i += 2;
      continue;
    }
    if (c == '=' || c == ':' || c == ' ' || c == '\t' || c == '\f') break;
    i++;
  }
  if (i > line.length) i = line.length;
  final key = line.substring(0, i);
  var j = i;
  while (j < line.length && (line[j] == ' ' || line[j] == '\t' || line[j] == '\f')) {
    j++;
  }
  if (j < line.length && (line[j] == '=' || line[j] == ':')) j++;
  while (j < line.length && (line[j] == ' ' || line[j] == '\t' || line[j] == '\f')) {
    j++;
  }
  return (key, line.substring(j));
}

String _unescape(String s) {
  if (!s.contains(r'\')) return s;
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c != r'\' || i + 1 >= s.length) {
      b.write(c);
      continue;
    }
    final n = s[++i];
    switch (n) {
      case 't':
        b.write('\t');
      case 'n':
        b.write('\n');
      case 'r':
        b.write('\r');
      case 'f':
        b.write('\f');
      case 'u':
        final code = i + 4 < s.length ? int.tryParse(s.substring(i + 1, i + 5), radix: 16) : null;
        if (code == null) {
          b.write('u'); // escape malformato: come Java non si può, si tiene il testo
        } else {
          b.writeCharCode(code);
          i += 4;
        }
      default:
        b.write(n);
    }
  }
  return b.toString();
}

/// Legge `server.properties` di [root]; mappa vuota se manca.
Map<String, String> readServerProperties(String root) {
  final f = File(p.join(root, 'server.properties'));
  try {
    return parseProperties(utf8.decode(f.readAsBytesSync(), allowMalformed: true));
  } on FileSystemException {
    return {};
  }
}

/// Porta del server: [defaultServerPort] se assente o vuota, null se il
/// valore non è una porta valida.
int? serverPort(Map<String, String> props) {
  final raw = props['server-port']?.trim();
  if (raw == null || raw.isEmpty) return defaultServerPort;
  final port = int.tryParse(raw);
  if (port == null || port < 1 || port > 65535) return null;
  return port;
}

/// L'EULA di Minecraft è accettata in `eula.txt` di [root].
bool isEulaAccepted(String root) {
  try {
    final text = File(p.join(root, 'eula.txt')).readAsStringSync();
    return parseProperties(text)['eula']?.trim().toLowerCase() == 'true';
  } on FileSystemException {
    return false;
  }
}

final _eulaLine = RegExp(r'^\s*eula\s*[=:\s]');

/// Scrive `eula=true` in `eula.txt` di [root] in modo atomico, lasciando
/// intatte le altre righe (commenti con data e link di Mojang compresi).
Future<void> acceptEula(String root) async {
  final path = p.join(root, 'eula.txt');
  final file = File(path);
  String text;
  try {
    text = await file.readAsString();
  } on FileSystemException {
    text = '';
  }
  final nl = text.contains('\r\n') ? '\r\n' : '\n';
  final lines = text.isEmpty ? <String>[] : text.split(RegExp(r'\r?\n'));
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  var found = false;
  for (var i = 0; i < lines.length; i++) {
    final trimmed = lines[i].trimLeft();
    if (trimmed.startsWith('#') || trimmed.startsWith('!')) continue;
    if (_eulaLine.hasMatch('${lines[i]} ') || trimmed == 'eula') {
      lines[i] = 'eula=true';
      found = true;
    }
  }
  if (!found) {
    if (lines.isEmpty) {
      lines.add(
        '#By changing the setting below to TRUE you are indicating your agreement to our EULA '
        '(https://aka.ms/MinecraftEULA).',
      );
    }
    lines.add('eula=true');
  }
  await writeAtomic(path, utf8.encode(lines.join(nl) + nl));
}
