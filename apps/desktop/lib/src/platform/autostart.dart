// Avvio con il sistema (opt-in), senza plugin:
//   Linux:   ~/.config/autostart/minesync.desktop (XDG Autostart)
//   macOS:   ~/Library/LaunchAgents/<id>.plist con RunAtLoad
//   Windows: valore "MineSync" in HKCU\Software\Microsoft\Windows\CurrentVersion\Run
// Il comando è il launcher (MINESYNC_LAUNCHER, passato da lui), non la
// cartella della versione, che cambia a ogni aggiornamento. L'app avviata
// così riceve --autostart e resta nella barra di sistema.
import 'dart:io';

import 'platform.dart';

/// Argomento con cui il sistema avvia l'app all'accesso.
const autostartArg = '--autostart';

/// Esegue un comando (sostituibile nei test).
typedef CommandRunner = Future<ProcessResult> Function(String exe, List<String> args);

Future<ProcessResult> _run(String exe, List<String> args) => Process.run(exe, args);

enum HostOs { linux, macos, windows }

HostOs get hostOs => Platform.isWindows
    ? HostOs.windows
    : Platform.isMacOS
    ? HostOs.macos
    : HostOs.linux;

/// Comando da registrare: il launcher se c'è (l'AppImage stessa se si gira
/// da lì), altrimenti l'eseguibile in esecuzione.
String launchCommand(Map<String, String> env) =>
    env['MINESYNC_LAUNCHER'] ?? env['APPIMAGE'] ?? Platform.resolvedExecutable;

final class SystemAutostart implements AutostartService {
  SystemAutostart({
    required this.command,
    required this.env,
    HostOs? os,
    this.run = _run,
    this.label = 'io.github.alesdrnz.minesync',
  }) : os = os ?? hostOs;

  final String command;
  final Map<String, String> env;
  final HostOs os;
  final CommandRunner run;

  /// Etichetta del LaunchAgent su macOS.
  final String label;

  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _valueName = 'MineSync';

  String get _home => env['HOME'] ?? env['USERPROFILE'] ?? '.';

  /// File che registra l'avvio (Linux e macOS).
  String get entryPath => switch (os) {
    HostOs.linux => () {
      final xdg = env['XDG_CONFIG_HOME'];
      final base = xdg != null && xdg.isNotEmpty ? xdg : '$_home/.config';
      return '$base/autostart/minesync.desktop';
    }(),
    HostOs.macos => '$_home/Library/LaunchAgents/$label.plist',
    HostOs.windows => '',
  };

  String get _windowsValue => '"$command" $autostartArg';

  @override
  Future<bool> get enabled async {
    if (os == HostOs.windows) {
      final r = await run('reg', ['query', _runKey, '/v', _valueName]);
      return r.exitCode == 0 && '${r.stdout}'.contains(command);
    }
    final f = File(entryPath);
    return f.existsSync() && f.readAsStringSync().contains(_escape(command));
  }

  @override
  Future<void> setEnabled(bool on) async {
    if (os == HostOs.windows) {
      final args = on
          ? ['add', _runKey, '/v', _valueName, '/t', 'REG_SZ', '/d', _windowsValue, '/f']
          : ['delete', _runKey, '/v', _valueName, '/f'];
      final r = await run('reg', args);
      // "delete" di un valore che non c'è esce con 1: va bene lo stesso
      if (r.exitCode != 0 && on) throw ProcessException('reg', args, '${r.stderr}', r.exitCode);
      return;
    }
    final f = File(entryPath);
    if (!on) {
      if (f.existsSync()) f.deleteSync();
      return;
    }
    f.parent.createSync(recursive: true);
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(os == HostOs.linux ? _desktopEntry() : _launchAgent(), flush: true);
    tmp.renameSync(f.path);
  }

  String _desktopEntry() =>
      '''
[Desktop Entry]
Type=Application
Name=MineSync
Exec="${_escape(command)}" $autostartArg
Icon=minesync
Terminal=false
X-GNOME-Autostart-enabled=true
''';

  String _launchAgent() =>
      '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>${_xml(command)}</string>
    <string>$autostartArg</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
''';

  /// Exec delle voci .desktop: dentro le virgolette vanno protetti " ` $ \.
  String _escape(String s) =>
      os == HostOs.linux ? s.replaceAllMapped(RegExp(r'["`$\\]'), (m) => '\\${m[0]}') : _xml(s);

  static String _xml(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
}
