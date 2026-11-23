// Descrizione Markdown/HTML dei progetti ridotta a testo semplice: niente
// HTML né immagini, link solo http/https.
import 'package:ms_modpack/ms_modpack.dart';
import 'package:test/test.dart';

void main() {
  test('titoli, paragrafi, elenchi, enfasi e codice', () {
    final t = plainMarkdown('''
# Benvenuti
Un **modpack** con *tante*   mod
su due righe.

## Cosa c'è
- Pokémon
* `strutture` nuove
1. dungeon

---
''');
    expect(t.blocks.map((b) => '${b.kind.name}: ${b.text}'), [
      'heading: Benvenuti',
      'paragraph: Un modpack con tante mod su due righe.',
      "heading: Cosa c'è",
      'bullet: Pokémon',
      'bullet: strutture nuove',
      'bullet: dungeon',
    ]);
  });

  test('HTML tolto, immagini tolte, link http/https tenuti, javascript: no', () {
    final t = plainMarkdown('''
<center><img src="https://cdn.example/banner.png"></center>
<p>Unisciti al <a href="https://discord.example/x">Discord</a> &amp; divertiti<br>oggi</p>
![logo](https://cdn.example/logo.png) [![badge](https://img.example/b.svg)](https://example.org)
Vedi [la wiki](https://wiki.example/pack "titolo") e [non questo](javascript:alert(1)).
Anche <https://example.com/auto>.
<script>alert(1)</script>
''');
    final text = t.blocks.map((b) => b.text).join('\n');
    expect(text, isNot(contains('<')));
    expect(text, isNot(contains('img')));
    expect(text, contains('Unisciti al Discord & divertiti'));
    expect(text, contains('Vedi la wiki e non questo'));
    expect(t.links, [
      const MdLink('Discord', 'https://discord.example/x'),
      const MdLink('la wiki', 'https://wiki.example/pack'),
      const MdLink('https://example.com/auto', 'https://example.com/auto'),
    ]);
  });

  test('entità HTML con nome e numeriche decodificate', () {
    expect(decodeHtmlEntities('Pok&eacute;mon &amp; amici'), 'Pokémon & amici');
    expect(
      decodeHtmlEntities('&quot;Ciao&quot; &#39;x&#39; &#233;&#xE9;&#XC8;'),
      '"Ciao" \'x\' ééÈ',
    );
    expect(decodeHtmlEntities('&Agrave; &ouml; &ntilde; &hellip; &rsquo;'), 'À ö ñ … ’');
    // una passata sola; sconosciute e numeri non validi restano
    expect(
      decodeHtmlEntities('&amp;lt; &boh; &#0; &#xD800; & solo'),
      '&lt; &boh; &#0; &#xD800; & solo',
    );
    final t = plainMarkdown(
      '# Pok&eacute;mon\nAvventura &ndash; con &#x1F600; e &laquo;amici&raquo;',
    );
    expect(t.blocks.map((b) => b.text), ['Pokémon', 'Avventura – con 😀 e «amici»']);
  });

  test('tabelle, citazioni, blocchi di codice e tetti', () {
    final t = plainMarkdown('''
| Mod | Versione |
|-----|:--------:|
| Create | 6 |

> citazione

```
codice
```
''');
    expect(t.blocks.map((b) => b.text), ['Mod · Versione', 'Create · 6', 'citazione', 'codice']);
    final long = plainMarkdown(List.filled(200, 'riga\n\n').join(), maxBlocks: 10);
    expect(long.blocks, hasLength(10));
    final cut = plainMarkdown('a' * 100, maxChars: 10);
    expect(cut.blocks.single.text, '${'a' * 10}…');
    expect(plainMarkdown('').isEmpty, isTrue);
  });
}
