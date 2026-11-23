// WebPlatform del browser (package:web). Solo per il web.
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'web_platform.dart';

final class BrowserPlatform extends WebPlatform {
  @override
  String? readPref(String key) {
    try {
      return web.window.localStorage.getItem(key);
    } on Object {
      return null; // storage bloccato o assente
    }
  }

  @override
  void writePref(String key, String? value) {
    try {
      if (value == null) {
        web.window.localStorage.removeItem(key);
      } else {
        web.window.localStorage.setItem(key, value);
      }
    } on Object {
      // quota piena o storage bloccato: la preferenza vale solo per questa visita
    }
  }

  @override
  List<String> get languages {
    try {
      final l = web.window.navigator.languages.toDart.map((s) => s.toDart).toList();
      return l.isEmpty ? [web.window.navigator.language] : l;
    } on Object {
      return const [];
    }
  }

  @override
  String get userAgent => web.window.navigator.userAgent;

  @override
  Uri get origin => Uri.parse(web.window.location.origin);

  @override
  void download(Uri url, {String? filename}) {
    final a = web.HTMLAnchorElement()
      ..href = url.toString()
      ..download = filename ?? '';
    web.document.body?.append(a);
    a.click();
    a.remove();
  }

  @override
  void openExternal(Uri url) {
    web.window.open(url.toString(), '_blank', 'noopener,noreferrer');
  }
}
