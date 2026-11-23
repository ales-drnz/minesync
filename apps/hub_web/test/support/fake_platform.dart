// WebPlatform finto: preferenze in memoria, lingue e user agent scelti dal
// test, scaricamenti, link e copie registrati, nessuna immagine di rete.
import 'package:flutter/widgets.dart';
import 'package:minesync_hub_web/src/platform/web_platform.dart';

import 'fixtures.dart';

final class FakePlatform extends WebPlatform {
  FakePlatform({
    this.languages = const ['it-IT', 'it', 'en'],
    this.userAgent = uaWindows,
    Map<String, String>? prefs,
    this.storageBroken = false,
  }) : prefs = prefs ?? {};

  final Map<String, String> prefs;

  /// Simula lo storage bloccato (navigazione privata): letture null,
  /// scritture ignorate.
  final bool storageBroken;

  @override
  List<String> languages;

  @override
  String userAgent;

  @override
  Uri get origin => Uri.parse('http://192.0.2.1:8084');

  final downloads = <Uri>[];
  final opened = <Uri>[];
  final copied = <String>[];

  @override
  String? readPref(String key) => storageBroken ? null : prefs[key];

  @override
  void writePref(String key, String? value) {
    if (storageBroken) return;
    if (value == null) {
      prefs.remove(key);
    } else {
      prefs[key] = value;
    }
  }

  @override
  void download(Uri url, {String? filename}) => downloads.add(url);

  @override
  void openExternal(Uri url) => opened.add(url);

  @override
  Future<void> copy(String text) async => copied.add(text);

  @override
  ImageProvider? networkImage(Uri url) => null;
}
