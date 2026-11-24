// Voce del menu e icona su Linux: scritte per l'utente quando l'app parte
// dal launcher o dall'AppImage, mai da un avvio di sviluppo.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_desktop/src/platform/desktop_entry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('la voce punta al launcher, con l\'id della finestra e Exec protetto', () {
    final text = desktopEntry(r'/home/alice/App "prova"/MineSync$.AppImage');
    expect(text, contains(r'Exec="/home/alice/App \"prova\"/MineSync\$.AppImage"'));
    expect(text, contains('Icon=$linuxAppId'));
    expect(text, contains('StartupWMClass=$linuxAppId'));
  });

  test('installa voce e icona nella cartella dell\'utente, solo se servono', () async {
    if (!Platform.isLinux) return;
    final dir = Directory.systemTemp.createTempSync('ms_entry');
    addTearDown(() => dir.deleteSync(recursive: true));
    final env = {
      'HOME': dir.path,
      'XDG_DATA_HOME': '${dir.path}/data',
      'APPIMAGE': '/home/alice/MineSync.AppImage',
    };
    await installLinuxDesktopEntry(env, log: (s) => fail(s));
    final entry = File('${dir.path}/data/applications/$linuxAppId.desktop');
    final icon = File('${dir.path}/data/icons/hicolor/256x256/apps/$linuxAppId.png');
    expect(entry.readAsStringSync(), contains('Exec="/home/alice/MineSync.AppImage"'));
    expect(icon.lengthSync(), greaterThan(0));

    // senza launcher né AppImage (flutter run) non si scrive nulla
    final dev = Directory.systemTemp.createTempSync('ms_entry_dev');
    addTearDown(() => dev.deleteSync(recursive: true));
    await installLinuxDesktopEntry({'HOME': dev.path});
    expect(Directory('${dev.path}/.local/share/applications').existsSync(), isFalse);
  });
}
