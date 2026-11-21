// Elenco dei campioni di testo (puro Dart: lo usano sia i widget sia lo
// script di analisi dei golden). L'ordine corrisponde alle bande dall'alto.

class TextSample {
  const TextSample(this.id, this.font, this.size, this.lineHeight, this.weight,
      this.text, {this.snap = true});
  final String id;
  final String font; // pixelify | silkscreen | silkscreen_orig | mono
  final double size; // px di design
  final double lineHeight;
  final int weight;
  final String text;
  final bool snap;
}

const textSamples = <String, List<TextSample>>{
  'text_silkscreen': [
    TextSample('silk16', 'silkscreen', 16, 24, 400, 'GIOCA SESSIONE 128 LIBERO'),
    TextSample('silk16b', 'silkscreen', 16, 24, 700, 'GIOCA SESSIONE 128 LIBERO'),
    TextSample('silk24', 'silkscreen', 24, 32, 400, 'IN GIOCO 42%'),
    TextSample('silk32b', 'silkscreen', 32, 40, 700, 'GIOCA'),
    TextSample('silk16_orig', 'silkscreen_orig', 16, 24, 400, 'GIOCA SESSIONE 128 LIBERO'),
    TextSample('silk16_nosnap', 'silkscreen', 16, 24, 400, 'GIOCA SESSIONE 128 LIBERO', snap: false),
  ],
  'text_pixelify': [
    TextSample('pix14', 'pixelify', 14, 20, 400, 'Ultimo salvataggio 3 minuti fa'),
    TextSample('pix16', 'pixelify', 16, 24, 400, 'Sincronizza il mondo con gli amici'),
    TextSample('pix24', 'pixelify', 24, 32, 600, 'Valle del Nord'),
    TextSample('pix32', 'pixelify', 32, 40, 600, 'Sessione attiva'),
    TextSample('pix48', 'pixelify', 48, 56, 700, 'MineSync'),
    TextSample('pix22', 'pixelify', 22, 28, 400, 'Griglia nativa 22 px'),
  ],
  'text_mono': [
    TextSample('mono14', 'mono', 14, 20, 400, '12:00:07 INFO Salvataggio completato in 41 ms'),
    TextSample('mono14b', 'mono', 14, 20, 700, '12:00:08 WARN Il server è in ritardo'),
  ],
};
