// Dove stanno le cose, per sistema operativo.
//
// Windows: installazione per utente in %LOCALAPPDATA%\MineSync (niente admin):
//   MineSync.exe (launcher, a cui punta il collegamento del menu Start) e
//   versions\<v>\ accanto. Radice = cartella del launcher.
// Linux, cartella portabile: minesync-launcher + versions/<v>/ accanto.
//   Radice = cartella del launcher.
// Linux, AppImage: l'AppImage (sola lettura) contiene il launcher e una
//   versione di partenza in $APPDIR/bootstrap; le versioni scaricate vanno in
//   $XDG_DATA_HOME/MineSync (di solito ~/.local/share/MineSync).
// macOS: MineSync.app è il launcher (piccolo, firmato) con la versione di
//   partenza in Contents/Resources/bootstrap; le versioni vanno in
//   ~/Library/Application Support/MineSync/versions/<v>/MineSync.app.
//
// Nei casi "sola lettura" (AppImage, .app) il launcher non si aggiorna da
// solo: cambia solo installando un pacchetto nuovo.
import 'dart:io';

import 'package:path/path.dart' as p;

/// Disposizione dell'installazione vista dal launcher.
final class LauncherLayout {
  const LauncherLayout({
    required this.root,
    required this.selfPath,
    this.bootstrapDir,
    this.selfUpdate = true,
  });

  /// Calcola la disposizione per il launcher in [selfPath]. Variabili per i
  /// test: MINESYNC_ROOT_OVERRIDE, MINESYNC_BOOTSTRAP_OVERRIDE.
  factory LauncherLayout.detect(
    Map<String, String> env,
    String selfPath, {
    bool? macOS,
    bool? linux,
  }) {
    final l = _detect(env, selfPath, macOS ?? Platform.isMacOS, linux ?? Platform.isLinux);
    final boot = env['MINESYNC_BOOTSTRAP_OVERRIDE'];
    if (boot == null || boot.isEmpty) return l;
    return LauncherLayout(
      root: l.root,
      selfPath: selfPath,
      bootstrapDir: boot,
      selfUpdate: l.selfUpdate,
    );
  }

  static LauncherLayout _detect(
    Map<String, String> env,
    String selfPath,
    bool isMac,
    bool isLinux,
  ) {
    final override = env['MINESYNC_ROOT_OVERRIDE'];
    final dir = p.dirname(selfPath);
    if (override != null && override.isNotEmpty) {
      return LauncherLayout(root: override, selfPath: selfPath);
    }
    final home = env['HOME'] ?? '.';
    final appBundle = _macAppBundle(selfPath);
    if (isMac && appBundle != null) {
      return LauncherLayout(
        root: p.join(home, 'Library', 'Application Support', 'MineSync'),
        selfPath: selfPath,
        bootstrapDir: p.join(appBundle, 'Contents', 'Resources', 'bootstrap'),
        selfUpdate: false,
      );
    }
    final appDir = env['APPDIR'];
    if (isLinux && env['APPIMAGE'] != null && appDir != null) {
      final xdg = env['XDG_DATA_HOME'];
      final data = xdg != null && xdg.isNotEmpty ? xdg : p.join(home, '.local', 'share');
      return LauncherLayout(
        root: p.join(data, 'MineSync'),
        selfPath: selfPath,
        bootstrapDir: p.join(appDir, 'bootstrap'),
        selfUpdate: false,
      );
    }
    return LauncherLayout(root: dir, selfPath: selfPath, bootstrapDir: p.join(dir, 'bootstrap'));
  }

  /// Radice dell'installazione (state.json, versions/, run/).
  final String root;

  /// Il launcher in esecuzione.
  final String selfPath;

  /// Versione di partenza inclusa nel pacchetto (cartella con
  /// .manifest.json), o null. Se più nuova della corrente viene installata.
  final String? bootstrapDir;

  /// Se il launcher può sostituire sé stesso con quello di una versione nuova.
  final bool selfUpdate;

  static String? _macAppBundle(String self) {
    final macos = p.dirname(self);
    final contents = p.dirname(macos);
    final app = p.dirname(contents);
    if (p.basename(macos) == 'MacOS' &&
        p.basename(contents) == 'Contents' &&
        app.endsWith('.app')) {
      return app;
    }
    return null;
  }
}
