// Sessioni di esempio per i test delle schermate: stato impostato a mano,
// ora fissa, nomi e indirizzi generici (192.0.2.x).
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_desktop/src/state/app_state.dart';
import 'package:ms_core/ms_core.dart';

/// Ora fissa delle anteprime.
final sampleNow = DateTime(2026, 11, 22, 18, 42, 19);

DateTime at(int h, int m, [int s = 0]) => DateTime(2026, 11, 22, h, m, s);

List<ConsoleEntry> sampleConsole() => [
  ConsoleEntry(
    at: at(17, 30, 4),
    kind: ConsoleKind.dim,
    level: 'MS',
    note: ConsoleNote.starting,
    args: const ['run.sh', '21.0.5', 6144],
  ),
  ConsoleEntry(
    at: at(17, 30, 11),
    kind: ConsoleKind.info,
    level: 'INFO',
    text: 'Preparing level "world"',
  ),
  ConsoleEntry(
    at: at(17, 30, 19),
    kind: ConsoleKind.info,
    level: 'INFO',
    text: 'Done (8.214s)! For help, type "help"',
  ),
  ConsoleEntry(at: at(17, 30, 19), kind: ConsoleKind.ok, level: 'MS', note: ConsoleNote.ready),
  ConsoleEntry(
    at: at(17, 31, 2),
    kind: ConsoleKind.join,
    level: 'JOIN',
    text: 'bob joined the game',
  ),
  ConsoleEntry(
    at: at(17, 35, 40),
    kind: ConsoleKind.info,
    level: 'INFO',
    text: '<bob> ciao! porto i semi',
  ),
  ConsoleEntry(
    at: at(17, 52, 13),
    kind: ConsoleKind.warn,
    level: 'WARN',
    text: "Can't keep up! Is the server overloaded? Running 2300ms or 46 ticks behind",
  ),
  ConsoleEntry(at: at(18, 5), kind: ConsoleKind.ok, level: 'MS', note: ConsoleNote.autosaved),
  ConsoleEntry(
    at: at(18, 5, 7),
    kind: ConsoleKind.ok,
    level: 'MS',
    note: ConsoleNote.uploaded,
    args: const [130],
  ),
  ConsoleEntry(
    at: at(18, 12, 44),
    kind: ConsoleKind.err,
    level: 'ERR',
    text: '[create] Failed to load contraption data at -112 64 380, skipping',
  ),
  ConsoleEntry(at: at(18, 20, 31), kind: ConsoleKind.cmd, level: 'CMD', text: '> time set day'),
  ConsoleEntry(
    at: at(18, 20, 31),
    kind: ConsoleKind.info,
    level: 'INFO',
    text: 'Set the time to 1000',
  ),
  ConsoleEntry(
    at: at(18, 33, 58),
    kind: ConsoleKind.join,
    level: 'JOIN',
    text: 'carol joined the game',
  ),
  ConsoleEntry(
    at: at(18, 34, 20),
    kind: ConsoleKind.info,
    level: 'INFO',
    text: '<carol> bob dove sei?',
  ),
  ConsoleEntry(at: at(18, 35), kind: ConsoleKind.ok, level: 'MS', note: ConsoleNote.autosaved),
  ConsoleEntry(
    at: at(18, 35, 9),
    kind: ConsoleKind.ok,
    level: 'MS',
    note: ConsoleNote.uploaded,
    args: const [131],
  ),
];

/// Una sessione "in gioco" su Survival, senza rete.
SessionController sampleSession({
  SessionPhase phase = SessionPhase.running,
  void Function(SessionController)? setup,
}) {
  final s = SessionController(
    client: HubClient(Uri.parse('http://192.0.2.1:8084/')),
    space: 'survival',
    name: 'Survival',
    folder: '/home/alice/MineSync/survival',
    me: 'alice',
    clock: () => sampleNow,
  );
  addTearDown(() {
    s.client.close(force: true);
    s.dispose();
  });
  s.debugSet(
    phase: phase,
    startedAt: at(17, 29),
    runningSince: at(17, 30, 19),
    players: {'alice': at(17, 30, 40), 'bob': at(17, 31, 2), 'carol': at(18, 33, 58)},
    console: sampleConsole(),
    saved: SavedInfo(131, at(18, 35, 9)),
    launch: const LaunchInfo(
      label: 'run.sh',
      javaVersion: '21.0.5',
      xmxMiB: 6144,
      port: 25565,
      maxPlayers: 10,
    ),
    addresses: const ['192.0.2.10', '192.0.2.24'],
    notices: [
      SessionNoticeEntry(at(18, 12), 'saveNotConfirmed'),
      SessionNoticeEntry(at(17, 30), 'keptMine', n: 128),
    ],
  );
  setup?.call(s);
  return s;
}
