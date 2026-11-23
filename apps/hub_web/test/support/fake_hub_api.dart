// HubApi finto in memoria per i test delle pagine. Hub, server, eventi e
// download hanno dati di esempio; per gli altri endpoint si assegna il campo
// corrispondente (es. `api.worlds['survival'] = ...`), altrimenti rispondono
// 404 `not_found`. Ogni chiamata finisce in [calls]; [failWith] fa fallire
// tutte le chiamate (hub offline, accesso negato…).
import 'dart:async';

import 'package:minesync_hub_web/src/api/hub_api.dart';
import 'package:ms_protocol/ms_protocol.dart';

import 'fixtures.dart';

// non final: l'area Admin la estende in admin_fixtures.dart
class FakeHubApi implements HubApi {
  FakeHubApi({HubInfo? hub, List<SpaceSummary>? spaces, List<HubEvent>? events, DlListing? dl})
    : hubInfo = hub ?? sampleHub(),
      spaceList = spaces ?? sampleSpaces(),
      eventLog = events ?? sampleEvents(),
      dl = dl ?? sampleDownloads();

  HubInfo hubInfo;
  List<SpaceSummary> spaceList;

  /// Eventi dal più vecchio.
  List<HubEvent> eventLog;
  DlListing dl;

  final details = <String, SpaceDetails>{};
  final worlds = <String, WorldInfo>{};
  final playerLists = <String, PlayerList>{};
  final modLists = <String, ModList>{};
  final packs = <String, ClientPack>{};
  final packFiles = <String, PackFile>{};
  final spaceStats = <String, SpaceStats>{};
  final history = <String, List<GenerationSummary>>{};
  final diffs = <(String, int), GenerationChanges>{};
  MemberList? memberList;
  SystemInfo? systemInfo;
  HubSettings? hubSettings;
  TelegramStatus? telegramStatus;
  HubUsage? hubUsage;

  /// Se non null ogni chiamata lancia questo (es. `HubOffline('x')` o
  /// `ApiError(ErrorCode.unauthenticated, '')`).
  Object? failWith;

  /// Chiamate ricevute: nome del metodo e argomenti principali.
  final calls = <String>[];

  /// Errore per un solo metodo (chiave = nome del metodo, es. `restore`).
  final failOn = <String, Object>{};

  /// Risposte di alcune azioni (pagina Server); senza, i default sotto.
  final freedBytes = <(String, int), int>{};
  GcPreview? gcPreviewResult;
  GcReport? gcResult;
  GenerationSummary Function(String id, int n)? onRestore;
  GenerationSummary Function(String id, RestoreFileRequest r)? onRestoreFile;
  SpaceDetails Function(String id, SpacePatch p)? onUpdateSpace;

  /// Eventi dal vivo: `api.live.add(evento)`.
  final live = StreamController<HubEvent>.broadcast();

  /// `after` dell'ultima apertura dello stream.
  int? streamAfter;

  Future<T> _r<T>(String call, T Function() f) async {
    calls.add(call);
    if (failWith != null) throw failWith!;
    if (failOn[call.split(' ').first] case final e?) throw e;
    return f();
  }

  static Never _missing(String what) => throw ApiError(ErrorCode.notFound, 'no fixture: $what');

  @override
  Future<HubInfo> hub() => _r('hub', () => hubInfo);

  @override
  Future<List<SpaceSummary>> spaces() => _r('spaces', () => spaceList);

  @override
  Future<SpaceDetails> createSpace(String name, Profile profile) => _r('createSpace $name', () {
    if (!hubInfo.me.admin) throw const ApiError(ErrorCode.forbidden, 'admin only');
    final id = name.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-');
    final sp = SpaceSummary(
      id: id,
      name: name,
      profile: profile,
      createdAt: testNow.millisecondsSinceEpoch,
      head: null,
      lock: null,
    );
    spaceList = [...spaceList, sp];
    return SpaceDetails(sp, exclusions: const [], ownExclusions: const []);
  });

  @override
  Future<SpaceDetails> space(String id) => _r(
    'space $id',
    () =>
        details[id] ??
        SpaceDetails(
          spaceList.firstWhere((s) => s.id == id, orElse: () => _missing('space $id')),
          exclusions: const [],
          ownExclusions: const [],
        ),
  );

  @override
  Future<SpaceDetails> updateSpace(String id, SpacePatch patch) => _r(
    'updateSpace $id ${patch.toJson()}',
    () => onUpdateSpace?.call(id, patch) ?? details[id] ?? _missing('details $id'),
  );

  @override
  Future<void> deleteSpace(String id) => _r('deleteSpace $id', () {
    spaceList = spaceList.where((s) => s.id != id).toList();
  });

  @override
  Future<WorldInfo> world(String id) => _r('world $id', () => worlds[id] ?? _missing('world'));

  @override
  Uri iconUrl(String id) => Uri.parse('http://192.0.2.1/api/v1/spaces/$id/icon');

  @override
  Future<PlayerList> players(String id) =>
      _r('players $id', () => playerLists[id] ?? _missing('players'));

  @override
  Future<ModList> mods(String id) => _r('mods $id', () => modLists[id] ?? _missing('mods'));

  @override
  Future<ClientPack> pack(String id) =>
      _r('pack $id', () => packs[id] ?? const ClientPack(n: 0, available: false));

  @override
  Uri packUrl(String id) => Uri.parse('http://192.0.2.1/api/v1/spaces/$id/pack.mrpack');

  @override
  Uri packModsUrl(String id) => Uri.parse('http://192.0.2.1/api/v1/spaces/$id/pack-mods.zip');

  @override
  Future<PackFile?> packFile(String id) => _r('packFile $id', () => packFiles[id]);

  @override
  Uri modIconUrl(String id, String file) =>
      Uri.parse('http://192.0.2.1/api/v1/spaces/$id/mods/$file/icon');

  @override
  Future<SpaceStats> stats(String id) => _r('stats $id', () => spaceStats[id] ?? _missing('stats'));

  @override
  Future<List<GenerationSummary>> generations(String id, {int? before, int? limit}) =>
      _r('generations $id $before', () {
        final all = history[id] ?? const <GenerationSummary>[];
        return all.where((g) => before == null || g.n < before).take(limit ?? 50).toList();
      });

  @override
  Future<Generation> generation(String id, {int? n}) =>
      _r('generation $id $n', () => _missing('generation'));

  @override
  Future<GenerationChanges> diff(String id, int n, {int? limit}) =>
      _r('diff $id $n', () => diffs[(id, n)] ?? _missing('diff'));

  @override
  Uri zipUrl(String id, {int? n}) =>
      Uri.parse('http://192.0.2.1/api/v1/spaces/$id/generations/${n ?? 'head'}/zip');

  @override
  Future<int> freed(String id, int n) => _r('freed $id $n', () => freedBytes[(id, n)] ?? 0);

  @override
  Future<GenerationDeleted> deleteGeneration(String id, int n) =>
      _r('deleteGeneration $id $n', () => (deleted: n, bytes: freedBytes[(id, n)] ?? 0));

  @override
  Future<GenerationSummary> restore(String id, int n, {String message = ''}) =>
      _r('restore $id $n', () => onRestore?.call(id, n) ?? _missing('restore'));

  @override
  Future<GenerationSummary> restoreFile(String id, RestoreFileRequest request) => _r(
    'restoreFile $id ${request.path} ${request.from}',
    () => onRestoreFile?.call(id, request) ?? _missing('restoreFile'),
  );

  @override
  Future<void> forceReleaseLock(String id) => _r('forceReleaseLock $id', () {});

  @override
  Future<PortCheck> portCheck(String id) =>
      _r('portCheck $id', () => const PortCheck(state: PortState.pending, port: 25565));

  @override
  Future<GcPreview> gcPreview({String? space, int? keep, HistorySettings? history}) =>
      _r('gcPreview $space $keep', () => gcPreviewResult ?? _missing('gcPreview'));

  @override
  Future<GcReport> gc({String? space, int? keep}) =>
      _r('gc $space $keep', () => gcResult ?? _missing('gc'));

  @override
  Future<HubUsage> usage() => _r('usage', () => hubUsage ?? _missing('usage'));

  @override
  Future<ExclusionTest> testExclusion({
    required String path,
    Profile? profile,
    String? spaceId,
    List<String>? patterns,
  }) => _r('testExclusion $path', () => _missing('testExclusion'));

  @override
  Future<MemberList> members() => _r('members', () => memberList ?? _missing('members'));

  @override
  Future<MemberInfo> setRole(String memberId, MemberRole role) =>
      _r('setRole $memberId ${role.name}', () => _missing('setRole'));

  @override
  Future<ZtnetStatus> refreshMembers() =>
      _r('refreshMembers', () => memberList?.ztnet ?? _missing('ztnet'));

  @override
  Future<SystemInfo> system() => _r('system', () => systemInfo ?? _missing('system'));

  @override
  Future<HubSettings> settings() => _r('settings', () => hubSettings ?? _missing('settings'));

  @override
  Future<HubSettings> patchSettings(String section, Map<String, Object?> fields) =>
      _r('patchSettings $section $fields', () => hubSettings ?? _missing('settings'));

  @override
  Future<TelegramStatus> telegram() => _r('telegram', () => telegramStatus ?? _missing('telegram'));

  @override
  Future<TelegramStatus> patchTelegram(TelegramPatch patch) =>
      _r('patchTelegram ${patch.toJson()}', () => telegramStatus ?? _missing('telegram'));

  @override
  Future<TelegramTestResult> testTelegram({
    String? token,
    String? chat,
    String? language,
    String? spaceId,
    String? topic,
  }) => _r('testTelegram $spaceId', () => _missing('testTelegram'));

  @override
  Future<List<TelegramChat>> findTelegramChats({String? token}) =>
      _r('findTelegramChats', () => const <TelegramChat>[]);

  @override
  Future<DlListing> downloads() => _r('downloads', () => dl);

  @override
  Uri downloadUrl(String file) => Uri.parse('http://192.0.2.1/dl/$file');

  @override
  Future<EventPage> events({
    int? after,
    int? before,
    int? limit,
    String? space,
    List<String>? types,
  }) => _r('events after=$after before=$before', () {
    final l = limit ?? 100;
    final last = eventLog.isEmpty ? 0 : eventLog.last.seq;
    if (before != null) {
      final older = eventLog.where((e) => e.seq < before).toList().reversed.toList();
      return EventPage(
        events: older.take(l).toList(),
        last: last,
        oldest: eventLog.firstOrNull?.seq,
        more: older.length > l,
      );
    }
    return EventPage(
      events: eventLog.where((e) => e.seq > (after ?? 0)).take(l).toList(),
      last: last,
    );
  });

  @override
  Stream<HubEvent> eventStream({int? after}) {
    calls.add('eventStream $after');
    streamAfter = after;
    return live.stream;
  }
}
