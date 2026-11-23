// Servizi del browser usati dall'app, astratti per i test: preferenze
// locali, lingue del browser, sistema operativo, indirizzo della pagina,
// scaricamenti, link esterni e appunti.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

abstract class WebPlatform {
  /// Preferenza salvata nel browser (null se assente o se lo storage non è
  /// disponibile, es. navigazione privata).
  String? readPref(String key);

  /// Salva (o con null toglie) una preferenza; gli errori si ignorano.
  void writePref(String key, String? value);

  /// Lingue preferite del browser (come `Accept-Language`), in ordine.
  List<String> get languages;

  /// User agent, per riconoscere il sistema operativo.
  String get userAgent;

  /// Indirizzo della pagina (l'hub).
  Uri get origin;

  /// Fa scaricare [url] al browser.
  void download(Uri url, {String? filename});

  /// Apre [url] in una nuova scheda.
  void openExternal(Uri url);

  /// Copia negli appunti.
  Future<void> copy(String text) => Clipboard.setData(ClipboardData(text: text));

  /// Immagine di rete (icone dei mondi e delle mod); null = non caricare.
  ImageProvider? networkImage(Uri url) => NetworkImage(url.toString());
}
