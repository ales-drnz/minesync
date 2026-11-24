// Voce dell'app nel menu e nella barra delle applicazioni di Linux.
//
// Su KDE e GNOME (soprattutto con Wayland) la barra delle applicazioni prende
// nome e icona dal file .desktop installato con lo stesso id della finestra
// (APPLICATION_ID del runner GTK). L'AppImage lo contiene ma il sistema non
// lo vede: all'avvio dal launcher o dall'AppImage si scrivono nella cartella
// dell'utente la voce e l'icona, solo se cambiate.
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

/// Id della finestra GTK (linux/CMakeLists.txt, APPLICATION_ID).
const linuxAppId = 'io.github.alesdrnz.minesync_desktop';

/// Installa voce e icona per l'utente. Non fa nulla fuori da Linux o quando
/// l'app non parte dal launcher o dall'AppImage (es. `flutter run`), per non
/// puntare la voce a un eseguibile di sviluppo.
Future<void> installLinuxDesktopEntry(Map<String, String> env, {void Function(String)? log}) async {
  if (!Platform.isLinux) return;
  final command = env['MINESYNC_LAUNCHER'] ?? env['APPIMAGE'];
  final home = env['HOME'];
  if (command == null || home == null) return;
  final data = env['XDG_DATA_HOME'] ?? '$home/.local/share';
  try {
    final icon = File('$data/icons/hicolor/256x256/apps/$linuxAppId.png');
    final png = (await rootBundle.load(
      'packages/ms_ui/assets/brand/minesync-256.png',
    )).buffer.asUint8List();
    if (!icon.existsSync() || !_same(icon.readAsBytesSync(), png)) {
      icon.parent.createSync(recursive: true);
      icon.writeAsBytesSync(png, flush: true);
    }
    final entry = File('$data/applications/$linuxAppId.desktop');
    final text = desktopEntry(command);
    if (!entry.existsSync() || entry.readAsStringSync() != text) {
      entry.parent.createSync(recursive: true);
      final tmp = File('${entry.path}.tmp')..writeAsStringSync(text, flush: true);
      tmp.renameSync(entry.path);
    }
  } on Object catch (e) {
    log?.call('voce del menu non installata: $e');
  }
}

/// Contenuto della voce .desktop che avvia [command].
String desktopEntry(String command) =>
    '''
[Desktop Entry]
Type=Application
Name=MineSync
GenericName=Minecraft world sync
GenericName[it]=Sincronizzazione dei mondi di Minecraft
Comment=Play on your Minecraft server with friends, one host at a time
Comment[it]=Giocate sul vostro server Minecraft tra amici, un host alla volta
Exec="${_escape(command)}"
Icon=$linuxAppId
Terminal=false
Categories=Game;
Keywords=minecraft;server;sync;world;
StartupWMClass=$linuxAppId
''';

/// Exec delle voci .desktop: dentro le virgolette vanno protetti " ` $ \.
String _escape(String s) => s.replaceAllMapped(RegExp(r'["`$\\]'), (m) => '\\${m[0]}');

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
