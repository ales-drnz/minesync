// Dati di esempio della pagina Server: mondo, giocatori, mod, statistiche,
// storia, differenze e dettaglio di Survival (in gioco), Creativo (libero) e
// Avventura (stale). Solo nomi generici e indirizzi di documentazione.
import 'package:minesync_hub_web/src/state/hub_state.dart';
import 'package:ms_protocol/ms_protocol.dart';

import 'harness.dart';

/// Stato con i dati di esempio della pagina Server già nell'API finta.
HubState serverState({Me me = alice, void Function(FakeHubApi api)? setup}) {
  final api = FakeHubApi(hub: sampleHub(me: me));
  api.spaceList = [
    for (final sp in api.spaceList)
      switch (sp.id) {
        'survival' => withPortCheck(sp, PortState.reachable),
        'creativo' => withLastSession(sp),
        _ => sp,
      },
  ];
  addServerFixtures(api);
  setup?.call(api);
  return testState(me: me, api: api);
}

const _uuidBob = '0b0b0b0b-0000-4000-8000-000000000001';
const _uuidCarol = '0c0c0c0c-0000-4000-8000-000000000002';
const _uuidAlice = '0a0a0a0a-0000-4000-8000-000000000003';
const _uuidDave = '0d0d0d0d-0000-4000-8000-000000000004';

const survivalChip = WorldChip(
  mcVersion: '1.21.1',
  loader: Loader.fabric,
  loaderVersion: '0.16.5',
  mods: 42,
);

WorldInfo sampleWorld() => const WorldInfo(
  n: 41,
  chip: survivalChip,
  level: LevelInfo(
    name: 'Survival dei Pini',
    version: '1.21.1',
    difficulty: Difficulty.normal,
    hardcore: false,
    gameMode: GameMode.survival,
    day: 412,
    timeTicks: 412 * 24000 + 6000,
    spawn: BlockPos(128, 72, -340),
    seed: '-4172144997902289642',
  ),
  properties: ServerProperties(
    motd: 'Benvenuti su Survival',
    maxPlayers: 10,
    pvp: true,
    whitelist: true,
    whitelistCount: 3,
    viewDistance: 12,
    simulationDistance: 10,
    port: 25565,
  ),
  modsBytes: 318 << 20,
  players: 4,
);

PlayerList samplePlayers() => PlayerList(
  n: 41,
  ts: at(17, 56),
  players: const [
    PlayerInfo(
      uuid: _uuidBob,
      name: 'bob',
      op: true,
      whitelisted: true,
      online: true,
      playTicks: (61 * 3600 + 12 * 60) * 20,
      deaths: 23,
      mobKills: 1842,
      distanceCm: 412 * 100000,
    ),
    PlayerInfo(
      uuid: _uuidCarol,
      name: 'carol',
      whitelisted: true,
      online: true,
      playTicks: (44 * 3600 + 30 * 60) * 20,
      deaths: 41,
      mobKills: 2310,
      distanceCm: 365 * 100000,
    ),
    PlayerInfo(
      uuid: _uuidAlice,
      name: 'alice',
      op: true,
      whitelisted: true,
      online: true,
      playTicks: (12 * 3600 + 6 * 60) * 20,
      deaths: 9,
      mobKills: 377,
      distanceCm: 88 * 100000,
    ),
    PlayerInfo(
      uuid: _uuidDave,
      name: 'dave',
      lastSeen: 1763000000000,
      playTicks: 18 * 60 * 20,
      deaths: 1,
      mobKills: 3,
      distanceCm: 80000,
    ),
  ],
);

ModInfo _mod(
  String file,
  int size, {
  String? name,
  String? version,
  List<String> authors = const [],
  String? description,
  String? homepage,
  String? license,
  int? since,
  int? updated,
  bool changed = false,
}) => ModInfo(
  file: file,
  size: size,
  h: '9f2c${'0' * 56}41ab',
  name: name,
  version: version,
  loader: name == null ? null : Loader.fabric,
  mcVersion: name == null ? null : '1.21.1',
  authors: authors,
  description: description,
  homepage: homepage,
  license: license,
  since: since,
  updated: updated,
  changed: changed,
);

ModList sampleMods() => ModList(
  n: 41,
  chip: survivalChip,
  bytes: 318 << 20,
  mods: [
    _mod(
      'biomi-lontani-1.9.0.jar',
      38 << 20,
      name: 'Biomi Lontani',
      version: '1.9.0',
      authors: ['alice'],
      license: 'MIT',
      since: 3,
    ),
    _mod(
      'forziere-plus-2.0.4.jar',
      620 << 10,
      name: 'Forziere Plus',
      version: '2.0.4',
      since: 5,
      changed: true,
    ),
    _mod('server-tweak-local.jar', 84 << 10, since: 40),
    _mod(
      'turbo-render-0.6.0.jar',
      1100 << 10,
      name: 'Turbo Render',
      version: '0.6.0',
      authors: ['studio-pixel', 'ninfea'],
      description: 'Più fotogrammi e meno scatti, senza cambiare l\'aspetto del gioco.',
      homepage: 'https://turbo-render.example/',
      license: 'LGPL-3.0',
      since: 12,
      updated: 33,
    ),
  ],
);

SpaceStats sampleStats() => SpaceStats(
  kept: 40,
  sessions: [
    SessionRecord(memberId: bob.id, name: 'bob', start: at(16, 46)),
    SessionRecord(
      memberId: carol.id,
      name: 'carol',
      start: at(20, 42, day: 21),
      end: at(22, 47, day: 21),
      ended: SessionEnd.released,
    ),
    SessionRecord(
      memberId: bob.id,
      name: 'bob',
      start: at(14, 0, day: 20),
      end: at(19, 42, day: 20),
      ended: SessionEnd.released,
    ),
  ],
  play: const [
    RankEntry(name: 'bob', ms: 61 * 3600000),
    RankEntry(name: 'carol', ms: 44 * 3600000),
    RankEntry(name: 'alice', ms: 12 * 3600000),
  ],
  hosting: [
    RankEntry(name: 'bob', ms: 38 * 3600000, memberId: bob.id),
    RankEntry(name: 'carol', ms: 20 * 3600000, memberId: carol.id),
  ],
);

GenerationSummary _gen(
  int n, {
  String author = 'bob',
  required int ts,
  GenerationKind kind = GenerationKind.autosave,
  String message = '',
  int? restoredFrom,
  List<DamagedFile> damaged = const [],
  int size = 1900 << 20,
  int added = 2,
  int changed = 31,
  int removed = 0,
}) => GenerationSummary(
  n: n,
  parent: n - 1,
  digest: n.toRadixString(16).padLeft(64, '0'),
  authorId: author,
  author: author,
  message: message,
  ts: ts,
  kind: kind,
  stats: GenerationStats(files: 1284, size: size, added: added, changed: changed, removed: removed),
  restoredFrom: restoredFrom,
  damaged: damaged,
);

List<GenerationSummary> sampleHistory() => [
  _gen(41, ts: at(17, 56), size: 1900 << 20),
  _gen(
    40,
    ts: at(16, 12),
    kind: GenerationKind.restore,
    restoredFrom: 37,
    damaged: const [
      DamagedFile(path: 'world/region/r.-1.2.mca', bad: 3, total: 1024),
      DamagedFile(path: 'world/DIM-1/region/r.0.0.mca', bad: 1, total: 1024),
    ],
    added: 0,
    changed: 48,
    removed: 3,
  ),
  _gen(39, author: 'carol', ts: at(22, 47, day: 21), kind: GenerationKind.push, size: 1940 << 20),
  _gen(
    37,
    author: 'alice',
    ts: at(19, 5, day: 17),
    kind: GenerationKind.push,
    message: 'Prima del drago',
  ),
];

GenerationChanges sampleDiff40() => const GenerationChanges(
  n: 40,
  parent: 39,
  added: DiffSection.empty,
  changed: DiffSection(
    total: 48,
    items: [
      DiffEntry(path: 'world/level.dat', size: 6 << 10, prevSize: 6 << 10),
      DiffEntry(path: 'world/region/r.0.0.mca', size: 9800 << 10, prevSize: 9600 << 10),
    ],
  ),
  removed: DiffSection(
    total: 3,
    items: [
      DiffEntry(path: 'logs/latest.log', size: 220 << 10),
      DiffEntry(path: 'world/data/raids.dat', size: 1 << 10),
      DiffEntry(path: 'world/poi/r.3.1.mca', size: 12 << 10),
    ],
  ),
  damaged: [
    DamagedReport(
      file: DamagedFile(path: 'world/region/r.-1.2.mca', bad: 3, total: 1024),
      lastIntact: 39,
    ),
    DamagedReport(file: DamagedFile(path: 'world/DIM-1/region/r.0.0.mca', bad: 1, total: 1024)),
  ],
);

SpaceDetails sampleDetails(SpaceSummary sp, {Map<String, Object?> overrides = const {}}) =>
    SpaceDetails(
      sp,
      exclusions: const ['logs/**', 'crash-reports/**', 'bluemap/**'],
      ownExclusions: const ['bluemap/**'],
      profileExclusions: const [
        'logs/**',
        'crash-reports/**',
        'debug/**',
        'spark/**',
        'hs_err_pid*.log',
        'replay_pid*.log',
        '*.hprof',
        '*.lock',
      ],
      settings: SpaceSettings(
        history: overrides.containsKey('history')
            ? const HistorySettings(keepLast: 20, keepHours: 24, keepDays: 3)
            : const HistorySettings(),
      ),
      inherited: const SpaceSettings(),
      overrides: overrides,
      usage: SpaceUsage(
        generations: 41,
        oldest: 1,
        logical: 18 << 30,
        referenced: 6 << 30,
        exclusive: 5 << 30,
        computedAt: at(17, 0),
      ),
    );

/// Mette i dati di esempio in [api] per tutti e tre i server.
void addServerFixtures(FakeHubApi api) {
  for (final sp in api.spaceList) {
    api.worlds[sp.id] = sp.id == 'survival'
        ? sampleWorld()
        : WorldInfo(n: sp.headN, chip: sp.world ?? const WorldChip());
    api.playerLists[sp.id] = sp.id == 'survival'
        ? samplePlayers()
        : PlayerList(n: sp.headN, ts: 0, players: const []);
    api.modLists[sp.id] = sp.id == 'survival'
        ? sampleMods()
        : ModList(n: sp.headN, chip: sp.world ?? const WorldChip(), bytes: 0, mods: const []);
    api.spaceStats[sp.id] = sp.id == 'survival'
        ? sampleStats()
        : const SpaceStats(kept: 40, sessions: []);
    api.history[sp.id] = sp.id == 'survival' ? sampleHistory() : const [];
    api.details[sp.id] = sampleDetails(
      sp,
      overrides: sp.id == 'survival'
          ? const {
              'history': {'keepLast': 20, 'keepDays': 3},
            }
          : const {},
    );
  }
  api.diffs[('survival', 40)] = sampleDiff40();
  api.diffs[('survival', 41)] = const GenerationChanges(
    n: 41,
    parent: 40,
    added: DiffSection(
      total: 2,
      items: [DiffEntry(path: 'world/stats/x.json', size: 3 << 10)],
    ),
    changed: DiffSection.empty,
    removed: DiffSection.empty,
  );
  api.freedBytes[('survival', 39)] = 120 << 20;
  api.hubUsage = HubUsage(
    disk: api.hubInfo.disk,
    blobs: 58 << 30,
    dl: 200 << 20,
    spaces: const {},
    computedAt: at(17, 0),
  );
  api.gcPreviewResult = const GcPreview(
    keep: 20,
    spaces: [GcPreviewRow(id: 'survival', name: 'Survival', now: 41, after: 20, bytes: 3 << 30)],
    now: 41,
    after: 20,
    bytes: 3 << 30,
  );
  api.gcResult = const GcReport(generations: 21, blobs: 300, bytes: 3 << 30);
  api.onRestore = (id, n) => _gen(
    api.spaceList.firstWhere((s) => s.id == id).headN + 1,
    author: 'alice',
    ts: at(18, 0),
    kind: GenerationKind.restore,
    restoredFrom: n,
  );
  api.onRestoreFile = (id, r) =>
      _gen(42, author: 'alice', ts: at(18, 0), kind: GenerationKind.restore);
  api.onUpdateSpace = (id, p) {
    final old = api.details[id]!;
    var sp = old.summary;
    if (p.name != null) {
      sp = SpaceSummary(
        id: sp.id,
        name: p.name!,
        profile: sp.profile,
        createdAt: sp.createdAt,
        head: sp.head,
        lock: sp.lock,
        dnsName: sp.dnsName,
        world: sp.world,
        lastSession: sp.lastSession,
      );
      api.spaceList = [for (final s in api.spaceList) s.id == id ? sp : s];
    }
    final d = SpaceDetails(
      sp,
      exclusions: old.exclusions,
      ownExclusions: p.exclusions ?? old.ownExclusions,
      profileExclusions: old.profileExclusions,
      settings: old.settings,
      inherited: old.inherited,
      overrides: p.overrides ?? old.overrides,
      usage: old.usage,
    );
    return api.details[id] = d;
  };
}

/// Ultima sessione di Creativo (per "Libero · ultima sessione").
SpaceSummary withLastSession(SpaceSummary sp) => SpaceSummary(
  id: sp.id,
  name: sp.name,
  profile: sp.profile,
  createdAt: sp.createdAt,
  head: sp.head,
  lock: sp.lock,
  dnsName: 'zerotier.${sp.id}.minesync.internal',
  world: sp.world,
  lastSession: SessionRecord(
    memberId: carol.id,
    name: 'carol',
    start: at(20, 42, day: 21),
    end: at(22, 47, day: 21),
    ended: SessionEnd.released,
  ),
);

/// Il patch ricevuto dall'API finta per [id] (ultimo).
String? lastPatch(FakeHubApi api, String id) =>
    api.calls.lastWhere((c) => c.startsWith('updateSpace $id '), orElse: () => '');

/// Errore di "qualcuno gioca" come lo manda l'hub.
const lockedError = ApiError(
  ErrorCode.locked,
  'locked',
  details: {
    'lock': {'name': 'bob'},
  },
);

/// [sp] con l'esito della prova della porta sul lock.
SpaceSummary withPortCheck(SpaceSummary sp, PortState state) {
  final l = sp.lock!;
  return SpaceSummary(
    id: sp.id,
    name: sp.name,
    profile: sp.profile,
    createdAt: sp.createdAt,
    head: sp.head,
    dnsName: sp.dnsName,
    world: survivalChip,
    lastSession: sp.lastSession,
    lock: LockHolder(
      memberId: l.memberId,
      name: l.name,
      since: l.since,
      lastBeat: l.lastBeat,
      stale: l.stale,
      ip: l.ip,
      info: l.info,
      portCheck: PortCheck(
        state: state,
        port: 25565,
        checkedAt: state == PortState.pending ? null : at(17, 52),
      ),
    ),
  );
}
