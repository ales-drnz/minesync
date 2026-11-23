// Dati e API finta dell'area Admin: impostazioni, membri alice/bob/carol,
// ZTNET, Telegram (token mai vero: solo le ultime 4 cifre finte), uso del
// disco, sistema, anteprime di pulizia, prova delle esclusioni. Gli errori
// da provare si impostano nei campi `…Error`.
import 'package:minesync_hub_web/src/api/hub_api.dart';
import 'package:ms_protocol/ms_protocol.dart';

import 'fake_hub_api.dart';
import 'fixtures.dart';

HubSettings sampleSettings({SettingsChange? changed}) => HubSettings(
  sections: const SettingsSections(
    general: GeneralSettings(name: 'Homelab'),
    history: HistorySettings(keepLast: 30, keepHours: 24, keepDays: 14),
    protection: ProtectionSettings(massDeleteRatio: 0.4),
  ),
  changed:
      changed ?? SettingsChange(by: 'alice', byId: alice.id, at: at(14, 5), section: 'sessions'),
);

MemberList sampleMembers({ZtnetState state = ZtnetState.ok}) => MemberList(
  members: [
    MemberInfo(
      id: alice.id,
      name: 'alice',
      role: MemberRole.admin,
      ip: '192.0.2.11',
      lastSeen: at(18, 0),
      fromConfig: true,
    ),
    MemberInfo(
      id: carol.id,
      name: 'carol',
      role: MemberRole.admin,
      ip: '192.0.2.12',
      lastSeen: at(17, 57),
    ),
    MemberInfo(
      id: bob.id,
      name: 'bob',
      role: MemberRole.member,
      ip: '192.0.2.10',
      lastSeen: at(21, 40, day: 19),
    ),
    const MemberInfo(
      id: 'd4d4d4d4d4',
      name: '',
      role: MemberRole.member,
      ip: '192.0.2.40',
      authorized: false,
    ),
  ],
  ztnet: ZtnetStatus(
    state: state,
    members: 3,
    lastRefresh: DateTime.utc(2026, 11, 22, 17, 59, 48).millisecondsSinceEpoch,
    lastError: 'nessuna risposta per 10 s',
    lastErrorAt: at(3, 12, day: 21),
    url: 'http://192.0.2.2:3000',
    tokenHint: '7f2a',
    networkHint: '3c91',
  ),
);

TelegramStatus sampleTelegram({TelegramState state = TelegramState.active}) => TelegramStatus(
  settings: TelegramSettings(
    enabled: state != TelegramState.disabled,
    tokenSet: true,
    tokenHint: '0000',
    chat: '-1000000000001',
    topics: const {'creativo': 12},
  ),
  state: state,
  chatTitle: 'Amici del server',
  botUsername: 'esempio_bot',
  lastSentAt: at(17, 52),
  lastSent: 'Survival salvato sull\'hub',
  lastError: state == TelegramState.error ? 'Bad Request: chat not found' : null,
  lastErrorAt: state == TelegramState.error ? at(17, 40) : null,
);

HubUsage sampleUsage() => HubUsage(
  disk: sampleHub().disk,
  blobs: 54 << 30,
  dl: 400 << 20,
  computedAt: at(17, 50),
  spaces: {
    'survival': SpaceUsage(
      generations: 41,
      logical: 70 << 30,
      referenced: 19 << 30,
      exclusive: 18 << 30,
      computedAt: at(17, 50),
    ),
    'creativo': SpaceUsage(
      generations: 128,
      logical: 400 << 30,
      referenced: 31 << 30,
      exclusive: 30 << 30,
      computedAt: at(17, 50),
    ),
    'avventura': SpaceUsage(
      generations: 9,
      logical: 30 << 30,
      referenced: 4 << 30,
      exclusive: 4 << 30,
      computedAt: at(17, 50),
    ),
  },
);

SystemInfo sampleSystem() => SystemInfo(
  version: '0.1.0',
  build: '2026-11-14',
  startedAt: testNow.subtract(const Duration(days: 12, hours: 4)).millisecondsSinceEpoch,
  time: testNow.millisecondsSinceEpoch,
  disk: sampleHub().disk,
  http: ':8084',
  dns: const DnsStatus(on: true, zone: 'minesync.internal', addr: ':53'),
  dataDir: '/data',
  allowedHosts: const ['hub.minesync.internal'],
  admins: const ['alice'],
  dlDir: '/dl',
  updates: const [
    UpdateChannel(platform: 'linux-x64', version: '0.1.0', signed: true),
    UpdateChannel(platform: 'windows-x64', version: '0.1.0', signed: true),
    UpdateChannel(platform: 'macos-arm64', version: '0.1.0', signed: true),
  ],
  timeZone: 'Europe/Rome',
  webDir: '/web',
  webBuild: '3f9a1c2b7d4e',
);

/// Avventura ha valori propri per le sessioni.
SpaceDetails avventuraDetails() => SpaceDetails(
  sampleSpaces()[2],
  exclusions: const [],
  ownExclusions: const [],
  overrides: const {
    'sessions': {'autosaveMinutes': 10, 'crashRestarts': 3},
  },
);

const sampleChats = [
  TelegramChat(id: '-1000000000002', type: 'supergroup', title: 'Gruppo di prova'),
];

/// API finta con i dati dell'area Admin e risposte credibili per le
/// azioni (PATCH applicate davvero, anteprime calcolate).
class AdminFakeApi extends FakeHubApi {
  AdminFakeApi({super.hub}) {
    hubSettings = sampleSettings();
    memberList = sampleMembers();
    telegramStatus = sampleTelegram();
    hubUsage = sampleUsage();
    systemInfo = sampleSystem();
    details['avventura'] = avventuraDetails();
  }

  Object? patchError;
  Object? roleError;
  Object? telegramTestError;
  Object? gcError;

  /// Corpi delle PATCH ricevute: (sezione, campi).
  final patches = <(String, Map<String, Object?>)>[];
  final telegramPatches = <Map<String, Object?>>[];

  Never _fail(Object e) => throw e;

  @override
  Future<HubSettings> patchSettings(String section, Map<String, Object?> fields) async {
    calls.add('patchSettings $section $fields');
    patches.add((section, fields));
    if (patchError != null) _fail(patchError!);
    final j = hubSettings!.toJson();
    final secs = j['sections']! as Map<String, Object?>;
    secs[section] = {...secs[section]! as Map<String, Object?>, ...fields};
    hubSettings = HubSettings(
      sections: SettingsSections.fromJson(secs),
      changed: SettingsChange(by: 'alice', byId: alice.id, at: at(18, 0), section: section),
    );
    return hubSettings!;
  }

  @override
  Future<TelegramStatus> patchTelegram(TelegramPatch patch) async {
    calls.add('patchTelegram');
    telegramPatches.add(patch.toJson());
    if (patchError != null) _fail(patchError!);
    final t = telegramStatus!.settings;
    final removed = patch.removeToken;
    telegramStatus = TelegramStatus(
      settings: TelegramSettings(
        enabled: patch.enabled ?? t.enabled,
        tokenSet: !removed && (t.tokenSet || (patch.token?.isNotEmpty ?? false)),
        tokenHint: removed
            ? null
            : (patch.token?.isNotEmpty ?? false)
            ? patch.token!.substring(patch.token!.length - 4)
            : t.tokenHint,
        chat: patch.chat ?? t.chat,
        language: patch.language ?? t.language,
        notify: patch.notify ?? t.notify,
        coalesceMinutes: patch.coalesceMinutes ?? t.coalesceMinutes,
        pushWarnMinutes: patch.pushWarnMinutes ?? t.pushWarnMinutes,
        topics: patch.topics == null
            ? t.topics
            : {for (final e in patch.topics!.entries) e.key: int.parse(e.value)},
      ),
      state: (patch.enabled ?? t.enabled) ? telegramStatus!.state : TelegramState.disabled,
      chatTitle: telegramStatus!.chatTitle,
      lastSentAt: telegramStatus!.lastSentAt,
      lastSent: telegramStatus!.lastSent,
    );
    return telegramStatus!;
  }

  @override
  Future<GcPreview> gcPreview({String? space, int? keep, HistorySettings? history}) async {
    calls.add(
      'gcPreview keep=$keep history=${history == null ? null : '${history.keepLast}/${history.keepHours}/${history.keepDays}'}',
    );
    final rows = [
      for (final sp in spaceList)
        if (sp.head != null)
          () {
            final now = sp.head!.n;
            final own = keep == null && sp.id == 'avventura';
            final limit = keep ?? (history!.keepLast + history.keepDays);
            final after = own ? now : (now < limit ? now : limit);
            return GcPreviewRow(
              id: sp.id,
              name: sp.name,
              now: now,
              after: after,
              bytes: (now - after) * (48 << 20),
              ownRules: own,
            );
          }(),
    ];
    return GcPreview(
      keep: keep,
      spaces: rows,
      now: rows.fold(0, (n, r) => n + r.now),
      after: rows.fold(0, (n, r) => n + r.after),
      bytes: rows.fold(0, (n, r) => n + r.bytes),
    );
  }

  @override
  Future<GcReport> gc({String? space, int? keep}) async {
    calls.add('gc $space $keep');
    if (gcError != null) _fail(gcError!);
    return const GcReport(generations: 118, blobs: 900, bytes: 5 << 30);
  }

  @override
  Future<MemberInfo> setRole(String memberId, MemberRole role) async {
    calls.add('setRole $memberId ${role.name}');
    if (roleError != null) _fail(roleError!);
    final l = memberList!;
    final m = l.members.firstWhere((m) => m.id == memberId);
    final n = MemberInfo(
      id: m.id,
      name: m.name,
      role: role,
      ip: m.ip,
      lastSeen: m.lastSeen,
      fromConfig: m.fromConfig,
      authorized: m.authorized,
    );
    memberList = MemberList(
      members: [for (final x in l.members) x.id == memberId ? n : x],
      ztnet: l.ztnet,
    );
    return n;
  }

  @override
  Future<ExclusionTest> testExclusion({
    required String path,
    Profile? profile,
    String? spaceId,
    List<String>? patterns,
  }) async {
    calls.add('testExclusion $path ${patterns?.length}');
    final ex = Exclusions(patterns ?? minecraftExclusions);
    final p = ex.firstMatch(path);
    return ExclusionTest(
      path: path,
      excluded: p != null,
      pattern: p,
      source: p == null
          ? null
          : systemExclusions.contains(p)
          ? ExclusionSource.system
          : ExclusionSource.draft,
    );
  }

  @override
  Future<TelegramTestResult> testTelegram({
    String? token,
    String? chat,
    String? language,
    String? spaceId,
    String? topic,
  }) async {
    calls.add('testTelegram space=$spaceId topic=$topic chat=$chat');
    if (telegramTestError != null) _fail(telegramTestError!);
    return TelegramTestResult(sentAt: at(17, 58), chat: chat ?? '-1000000000001');
  }

  @override
  Future<List<TelegramChat>> findTelegramChats({String? token}) async {
    calls.add('findTelegramChats');
    return sampleChats;
  }
}

/// Un'altra admin ha cambiato le impostazioni (evento `settings`).
HubEvent settingsEvent(int seq, String section) => HubEvent(
  seq: seq,
  ts: at(18, 0),
  type: EventType.settings,
  actor: 'carol',
  data: {
    'section': section,
    'fields': ['name'],
  },
);

/// Errore di Telegram come lo restituisce l'hub.
ApiError upstreamError(String text) =>
    ApiError(ErrorCode.upstream, 'telegram', details: {'error': text});

/// Errore di un campo come lo restituisce l'hub.
ApiError fieldError(String field) =>
    ApiError(ErrorCode.badRequest, 'invalid', details: {'field': field});

/// Hub che non risponde.
const offline = HubOffline('test');
