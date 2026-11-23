// Avvio con il sistema: file e comandi giusti per ogni sistema, senza
// toccare quello vero (HOME temporanea, comando reg finto).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_desktop/src/platform/autostart.dart';

void main() {
  late Directory home;
  setUp(() => home = Directory.systemTemp.createTempSync('ms_autostart'));
  tearDown(() => home.deleteSync(recursive: true));

  test('Linux: voce XDG in ~/.config/autostart, con --autostart', () async {
    final a = SystemAutostart(
      command: '/opt/Mine Sync/minesync-launcher',
      env: {'HOME': home.path},
      os: HostOs.linux,
    );
    expect(await a.enabled, isFalse);
    await a.setEnabled(true);
    final f = File('${home.path}/.config/autostart/minesync.desktop');
    expect(f.readAsStringSync(), contains('Exec="/opt/Mine Sync/minesync-launcher" --autostart'));
    expect(await a.enabled, isTrue);
    await a.setEnabled(false);
    expect(f.existsSync(), isFalse);
    expect(await a.enabled, isFalse);
  });

  test('Linux: XDG_CONFIG_HOME e caratteri speciali nel percorso', () async {
    final a = SystemAutostart(
      command: r'/x/$a"b',
      env: {'HOME': home.path, 'XDG_CONFIG_HOME': '${home.path}/cfg'},
      os: HostOs.linux,
    );
    await a.setEnabled(true);
    final text = File('${home.path}/cfg/autostart/minesync.desktop').readAsStringSync();
    expect(text, contains(r'Exec="/x/\$a\"b" --autostart'));
    expect(await a.enabled, isTrue);
  });

  test('macOS: LaunchAgent con RunAtLoad', () async {
    final a = SystemAutostart(
      command: '/Applications/MineSync.app/Contents/MacOS/MineSync',
      env: {'HOME': home.path},
      os: HostOs.macos,
      label: 'test.minesync',
    );
    await a.setEnabled(true);
    final f = File('${home.path}/Library/LaunchAgents/test.minesync.plist');
    final text = f.readAsStringSync();
    expect(text, contains('<string>/Applications/MineSync.app/Contents/MacOS/MineSync</string>'));
    expect(text, contains('<key>RunAtLoad</key>'));
    expect(await a.enabled, isTrue);
    await a.setEnabled(false);
    expect(f.existsSync(), isFalse);
  });

  test('Windows: valore nella chiave Run di HKCU', () async {
    final calls = <List<String>>[];
    var stored = '';
    Future<ProcessResult> reg(String exe, List<String> args) async {
      calls.add([exe, ...args]);
      if (args.first == 'add') stored = args[args.indexOf('/d') + 1];
      if (args.first == 'delete') stored = '';
      final found = args.first == 'query' && stored.isNotEmpty;
      return ProcessResult(0, args.first == 'query' && !found ? 1 : 0, found ? stored : '', '');
    }

    final a = SystemAutostart(
      command: r'C:\Users\u\AppData\Local\MineSync\MineSync.exe',
      env: const {},
      os: HostOs.windows,
      run: reg,
    );
    expect(await a.enabled, isFalse);
    await a.setEnabled(true);
    expect(calls.last, contains(r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'));
    expect(stored, r'"C:\Users\u\AppData\Local\MineSync\MineSync.exe" --autostart');
    expect(await a.enabled, isTrue);
    await a.setEnabled(false);
    expect(calls.last.sublist(0, 2), ['reg', 'delete']);
    expect(await a.enabled, isFalse);
  });

  test('comando: il launcher se c\'è, poi l\'AppImage, poi l\'eseguibile', () {
    expect(launchCommand({'MINESYNC_LAUNCHER': 'L', 'APPIMAGE': 'A'}), 'L');
    expect(launchCommand({'APPIMAGE': 'A'}), 'A');
    expect(launchCommand(const {}), Platform.resolvedExecutable);
  });
}
