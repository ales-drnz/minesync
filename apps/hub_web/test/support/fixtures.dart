// Dati di esempio della web UI: hub, membri alice/bob/carol, server
// Survival/Creativo/Avventura, attività, download. Solo nomi generici e
// indirizzi di documentazione (192.0.2.x).
import 'package:ms_protocol/ms_protocol.dart';

/// Ora fissa dei test: 22 novembre 2026, 18:00 UTC.
final testNow = DateTime.utc(2026, 11, 22, 18);
int at(int h, int m, {int day = 22}) => DateTime.utc(2026, 11, day, h, m).millisecondsSinceEpoch;

const alice = Me(id: 'a1a1a1a1a1', name: 'alice', admin: true);
const bob = Me(id: 'b2b2b2b2b2', name: 'bob', admin: false);
const carol = Me(id: 'c3c3c3c3c3', name: 'carol', admin: false);

HubInfo sampleHub({Me me = alice, bool lowDisk = false, String language = 'auto'}) => HubInfo(
  name: 'Hub di casa',
  version: '0.1.0',
  api: 1,
  time: testNow.millisecondsSinceEpoch,
  disk: lowDisk
      ? const DiskInfo(free: 180 << 30, total: 2000 << 30, minFree: 40 << 30)
      : const DiskInfo(free: 1200 << 30, total: 2000 << 30, minFree: 1 << 30),
  me: me,
  language: language,
  dnsZone: 'minesync.internal',
);

GenerationSummary sampleGen(int n, {String author = 'bob', int ts = 0, int size = 900 << 20}) =>
    GenerationSummary(
      n: n,
      parent: n - 1,
      digest: n.toRadixString(16).padLeft(64, '0'),
      authorId: author,
      author: author,
      message: '',
      ts: ts == 0 ? at(17, 56) : ts,
      kind: GenerationKind.autosave,
      stats: GenerationStats(files: 1200, size: size, added: 3, changed: 40),
    );

List<SpaceSummary> sampleSpaces() => [
  SpaceSummary(
    id: 'survival',
    name: 'Survival',
    profile: Profile.minecraft,
    createdAt: 0,
    head: sampleGen(41, author: 'bob', size: 1900 << 20),
    dnsName: 'zerotier.survival.minesync.internal',
    world: const WorldChip(mcVersion: '1.21.1', loader: Loader.fabric, mods: 42),
    lock: LockHolder(
      memberId: bob.id,
      name: 'bob',
      since: at(16, 46),
      lastBeat: at(17, 59),
      stale: false,
      ip: '192.0.2.10',
      info: const LockInfo(action: 'play', players: ['bob', 'carol', 'alice'], port: 25565),
    ),
  ),
  SpaceSummary(
    id: 'creativo',
    name: 'Creativo',
    profile: Profile.minecraft,
    createdAt: 0,
    head: sampleGen(128, author: 'carol', ts: at(22, 47, day: 21), size: 31 << 30),
    world: const WorldChip(mcVersion: '1.21.1', loader: Loader.vanilla),
    lock: null,
  ),
  SpaceSummary(
    id: 'avventura',
    name: 'Avventura',
    profile: Profile.minecraft,
    createdAt: 0,
    head: sampleGen(9, author: 'carol', size: 4 << 30),
    world: const WorldChip(mcVersion: '1.21.1', loader: Loader.neoforge, mods: 214),
    lock: LockHolder(
      memberId: carol.id,
      name: 'carol',
      since: at(15, 0),
      lastBeat: at(17, 57),
      stale: true,
      info: const LockInfo(action: 'play'),
    ),
  ),
];

/// Attività di esempio, dalla più vecchia (una per tipo usato nel design).
List<HubEvent> sampleEvents() => [
  HubEvent(
    seq: 1,
    ts: at(14, 5),
    type: EventType.settings,
    actor: 'alice',
    data: const {
      'section': 'sessions',
      'fields': ['autosaveMinutes'],
    },
  ),
  HubEvent(
    seq: 2,
    ts: at(15, 30),
    type: EventType.gc,
    space: 'creativo',
    data: const {'generations': 6, 'blobs': 40, 'bytes': 1500 << 20},
  ),
  HubEvent(
    seq: 3,
    ts: at(16, 12),
    type: EventType.restore,
    space: 'survival',
    actor: 'bob',
    data: const {'n': 40, 'restoredFrom': 37},
  ),
  HubEvent(
    seq: 4,
    ts: at(16, 40),
    type: EventType.unlock,
    space: 'creativo',
    actor: 'carol',
    data: const {'durationMs': 7500000},
  ),
  HubEvent(
    seq: 6,
    ts: at(17, 2),
    type: EventType.disk,
    data: {'free': 180 << 30, 'total': 2000 << 30, 'minFree': 40 << 30, 'level': 'warn'},
  ),
  HubEvent(
    seq: 5,
    ts: at(16, 46),
    type: EventType.lock,
    space: 'survival',
    actor: 'bob',
    data: const {'action': 'play'},
  ),
  HubEvent(
    seq: 7,
    ts: at(17, 49),
    type: EventType.stale,
    space: 'avventura',
    data: const {'holder': 'carol', 'lastBeat': 0},
  ),
  HubEvent(
    seq: 8,
    ts: at(17, 52),
    type: EventType.push,
    space: 'survival',
    actor: 'bob',
    data: const {
      'n': 41,
      'kind': 'autosave',
      'stats': {'files': 1200, 'size': 38 << 20},
    },
  ),
];

DlListing sampleDownloads() => const DlListing(
  files: [
    DlFile(
      name: 'MineSync-0.1.0-setup.exe',
      os: DlOs.windows,
      size: 52 << 20,
      arch: 'x64',
      version: '0.1.0',
      sha256: '3b1f0000000000000000000000000000000000000000000000000000000e09c',
    ),
    DlFile(
      name: 'MineSync-0.1.0.dmg',
      os: DlOs.macos,
      size: 61 << 20,
      arch: 'universal',
      version: '0.1.0',
      sha256: 'a7d20000000000000000000000000000000000000000000000000000005f11',
    ),
    DlFile(
      name: 'MineSync-0.1.0-x86_64.AppImage',
      os: DlOs.linux,
      size: 58 << 20,
      arch: 'x64',
      version: '0.1.0',
      sha256: '0c6e000000000000000000000000000000000000000000000000000000092ad',
    ),
  ],
  updates: [UpdateChannel(platform: 'linux-x64', version: '0.1.0', signed: true)],
  signedSums: true,
);

/// User agent di prova.
const uaWindows =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/140.0 Safari/537.36';
const uaMac =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) '
    'Version/18.0 Safari/605.1.15';
const uaLinux = 'Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0';
const uaAndroid =
    'Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/140.0 Mobile Safari/537.36';
const uaIphone =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
