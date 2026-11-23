// Descrizione lunga di un progetto Modrinth (Markdown con dentro, spesso,
// HTML) ridotta a blocchi di testo semplice: titoli, paragrafi, punti
// elenco. Niente HTML, niente immagini; i link restano solo se http/https e
// si aprono nel browser del sistema (li mostra chi disegna). Puro Dart.

/// Tipo di blocco.
enum MdBlockKind { heading, paragraph, bullet }

/// Un link della descrizione (solo http/https).
final class MdLink {
  const MdLink(this.text, this.url);
  final String text;
  final String url;

  @override
  bool operator ==(Object other) => other is MdLink && other.text == text && other.url == url;

  @override
  int get hashCode => Object.hash(text, url);

  @override
  String toString() => '$text <$url>';
}

/// Un blocco di testo.
final class MdBlock {
  const MdBlock(this.kind, this.text, {this.links = const []});
  final MdBlockKind kind;
  final String text;

  /// Link che compaiono nel blocco, nell'ordine.
  final List<MdLink> links;

  @override
  String toString() => '${kind.name}: $text';
}

/// Il testo semplice di una descrizione.
final class PlainText {
  const PlainText(this.blocks);
  final List<MdBlock> blocks;

  bool get isEmpty => blocks.isEmpty;

  /// Tutti i link, senza doppioni (per URL).
  List<MdLink> get links {
    final seen = <String>{};
    return [
      for (final b in blocks)
        for (final l in b.links)
          if (seen.add(l.url)) l,
    ];
  }
}

final _comment = RegExp(r'<!--[\s\S]*?-->');
final _br = RegExp(r'<br\s*/?>', caseSensitive: false);
final _blockTag = RegExp(
  r'</?(p|div|h[1-6]|li|ul|ol|center|details|summary|table|tr)\b[^>]*>',
  caseSensitive: false,
);
final _anchor = RegExp(
  r'''<a\b[^>]*href\s*=\s*["']([^"']*)["'][^>]*>([\s\S]*?)</a>''',
  caseSensitive: false,
);
final _tag = RegExp(r'<[^>]*>');
final _image = RegExp(r'!\[[^\]]*\]\([^)]*\)');
final _link = RegExp(r'\[([^\]]*)\]\(\s*([^)\s]+)(?:\s+"[^"]*")?\s*\)');
final _autolink = RegExp(r'<(https?://[^>\s]+)>');
final _heading = RegExp(r'^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$');
final _bullet = RegExp(r'^\s*(?:[-*+]|\d+[.)])\s+(.*)$');
final _rule = RegExp(r'^\s{0,3}([-*_])(\s*\1){2,}\s*$');
final _tableSep = RegExp(r'^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$');
final _fence = RegExp(r'^\s*(```|~~~)');
final _quote = RegExp(r'^\s*>\s?');
final _strong = RegExp(r'(\*\*|__)(.+?)\1');
final _em = RegExp(r'(?<![\w*])\*(?!\s)([^*\n]+?)\*(?![\w*])');
final _code = RegExp(r'`([^`]*)`');
final _spaces = RegExp(r'[ \t ]+');

// entità HTML con nome più comuni nelle descrizioni (punteggiatura
// tipografica, simboli, lettere speciali); le altre restano come sono
const _named = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  'ndash': '–',
  'mdash': '—',
  'hellip': '…',
  'lsquo': '‘',
  'rsquo': '’',
  'ldquo': '“',
  'rdquo': '”',
  'laquo': '«',
  'raquo': '»',
  'bull': '•',
  'middot': '·',
  'copy': '©',
  'reg': '®',
  'trade': '™',
  'deg': '°',
  'times': '×',
  'euro': '€',
  'pound': '£',
  'yen': '¥',
  'sect': '§',
  'iexcl': '¡',
  'iquest': '¿',
  'szlig': 'ß',
  'ccedil': 'ç',
  'Ccedil': 'Ç',
  'ntilde': 'ñ',
  'Ntilde': 'Ñ',
  'aelig': 'æ',
  'AElig': 'Æ',
  'oslash': 'ø',
  'Oslash': 'Ø',
  'aring': 'å',
  'Aring': 'Å',
  'oelig': 'œ',
  'OElig': 'Œ',
};

// vocali con accento (&eacute; &Agrave; &ouml; …): lettere di base e
// lettere accentate nello stesso ordine
const _accents = {
  'acute': ('aeiouyAEIOUY', 'áéíóúýÁÉÍÓÚÝ'),
  'grave': ('aeiouAEIOU', 'àèìòùÀÈÌÒÙ'),
  'circ': ('aeiouAEIOU', 'âêîôûÂÊÎÔÛ'),
  'uml': ('aeiouyAEIOUY', 'äëïöüÿÄËÏÖÜŸ'),
  'tilde': ('aoAO', 'ãõÃÕ'),
};

final _entity = RegExp(r'&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z][a-zA-Z0-9]{1,8});');
final _accentName = RegExp(r'^([a-zA-Z])(acute|grave|circ|uml|tilde)$');

/// Decodifica le entità HTML di [s]: con nome (`&eacute;`, `&amp;`,
/// `&quot;` …) e numeriche (`&#233;`, `&#xE9;`). Una sola passata, così
/// `&amp;lt;` diventa `&lt;` e non `<`; quelle sconosciute restano.
String decodeHtmlEntities(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(_entity, (m) {
    final e = m[1]!;
    if (e.startsWith('#')) {
      final hex = e[1] == 'x' || e[1] == 'X';
      final code = int.tryParse(e.substring(hex ? 2 : 1), radix: hex ? 16 : 10);
      if (code == null || code == 0 || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) {
        return m[0]!;
      }
      return String.fromCharCode(code);
    }
    if (_named[e] case final v?) return v;
    if (_accentName.firstMatch(e) case final a?) {
      final (base, accented) = _accents[a[2]]!;
      final i = base.indexOf(a[1]!);
      if (i >= 0) return accented[i];
    }
    return m[0]!;
  });
}

bool _httpUrl(String u) {
  final p = Uri.tryParse(u);
  return p != null && (p.scheme == 'https' || p.scheme == 'http') && p.host.isNotEmpty;
}

/// Riduce [markdown] a blocchi di testo semplice. Al più [maxBlocks] blocchi
/// e [maxChars] caratteri in tutto (il resto si taglia).
PlainText plainMarkdown(String markdown, {int maxBlocks = 80, int maxChars = 8000}) {
  var s = markdown.replaceAll('\r\n', '\n').replaceAll(_comment, '');
  // HTML: i link diventano link Markdown, i blocchi a capo, il resto via
  s = s
      .replaceAllMapped(_autolink, (m) => '[${m[1]}](${m[1]})')
      .replaceAllMapped(_anchor, (m) => '[${m[2]}](${m[1]})');
  s = s.replaceAll(_br, '\n').replaceAll(_blockTag, '\n').replaceAll(_tag, '');
  s = decodeHtmlEntities(s);
  final blocks = <MdBlock>[];
  var chars = 0;
  final para = <String>[];
  var inFence = false;

  void add(MdBlockKind kind, String raw) {
    if (blocks.length >= maxBlocks || chars >= maxChars) return;
    final links = <MdLink>[];
    var t = raw.replaceAll(_image, '');
    t = t.replaceAllMapped(_link, (m) {
      final text = m[1]!.trim(), url = m[2]!.trim();
      if (_httpUrl(url) && text.isNotEmpty) links.add(MdLink(_inline(text), url));
      return text;
    });
    t = _inline(t);
    if (t.isEmpty) return;
    if (chars + t.length > maxChars) t = '${t.substring(0, maxChars - chars).trimRight()}…';
    chars += t.length;
    blocks.add(MdBlock(kind, t, links: links));
  }

  void flush() {
    if (para.isEmpty) return;
    add(MdBlockKind.paragraph, para.join(' '));
    para.clear();
  }

  for (final line in s.split('\n')) {
    if (_fence.hasMatch(line)) {
      flush();
      inFence = !inFence;
      continue;
    }
    if (inFence) {
      if (line.trim().isNotEmpty) para.add(line.trim());
      continue;
    }
    final l = line.replaceFirst(_quote, '');
    if (l.trim().isEmpty || _rule.hasMatch(l) || _tableSep.hasMatch(l)) {
      flush();
      continue;
    }
    if (_heading.firstMatch(l) case final m?) {
      flush();
      add(MdBlockKind.heading, m[2]!);
      continue;
    }
    if (_bullet.firstMatch(l) case final m?) {
      flush();
      add(MdBlockKind.bullet, m[1]!);
      continue;
    }
    if (l.trimLeft().startsWith('|')) {
      flush();
      final cells = l.split('|').map((c) => c.trim()).where((c) => c.isNotEmpty);
      add(MdBlockKind.paragraph, cells.join(' · '));
      continue;
    }
    para.add(l.trim());
  }
  flush();
  return PlainText(blocks);
}

String _inline(String t) => t
    .replaceAllMapped(_strong, (m) => m[2]!)
    .replaceAllMapped(_em, (m) => m[1]!)
    .replaceAllMapped(_code, (m) => m[1]!)
    .replaceAll(_spaces, ' ')
    .trim();
