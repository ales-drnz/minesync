// HubApi sopra un HubTransport: JSON, `X-MineSync: 1` sulle richieste che
// cambiano stato, errori decodificati in ApiError, SSE con riconnessione.
// Puro Dart: nel browser il trasporto è fetch, nei test un finto.
import 'dart:convert';

import 'package:ms_protocol/ms_protocol.dart';

import 'hub_api.dart';
import 'live_events.dart';
import 'transport.dart';

final class HttpHubApi implements HubApi {
  /// [origin] è l'indirizzo dell'hub (nel browser: quello della pagina).
  HttpHubApi(this.transport, Uri origin)
    : _api = origin.replace(path: '/api/v1/', query: null, fragment: null),
      _origin = origin.replace(path: '/', query: null, fragment: null);

  final HubTransport transport;
  final Uri _api;
  final Uri _origin;

  static String _seg(String s) => Uri.encodeComponent(s);

  Uri _u(String path, [Map<String, String?> query = const {}]) {
    final q = {
      for (final e in query.entries)
        if (e.value != null) e.key: e.value!,
    };
    final u = _api.resolve(path);
    return q.isEmpty ? u : u.replace(queryParameters: q);
  }

  /// Chiamata JSON: restituisce il corpo decodificato (null se vuoto).
  Future<Object?> _json(
    String method,
    String path, {
    Map<String, String?> query = const {},
    Object? body,
  }) async {
    final mutating = method != 'GET' && method != 'HEAD';
    final headers = {
      'Accept': 'application/json',
      if (mutating) csrfHeader: '1',
      if (body != null) 'Content-Type': 'application/json',
    };
    final TransportResponse res;
    try {
      res = await transport.send(
        method,
        _u(path, query),
        headers: headers,
        body: body == null ? null : jsonEncode(body),
      );
    } on TransportFailure catch (e) {
      throw HubOffline(e.reason);
    }
    Object? decoded;
    if (res.body.isNotEmpty) {
      try {
        decoded = jsonDecode(res.body);
      } on FormatException {
        decoded = null;
      }
    }
    if (res.status >= 400) {
      if (decoded == null) {
        // un proxy o un hub fermo a metà: niente corpo JSON
        throw ApiError(_codeForStatus(res.status), 'HTTP ${res.status}', status: res.status);
      }
      throw ApiError.fromJson(decoded, status: res.status);
    }
    if (decoded == null && res.body.isNotEmpty) {
      throw ApiError(ErrorCode.internal, 'invalid JSON response', status: res.status);
    }
    return decoded;
  }

  static ErrorCode _codeForStatus(int s) => switch (s) {
    401 => ErrorCode.unauthenticated,
    403 => ErrorCode.forbidden,
    404 => ErrorCode.notFound,
    413 => ErrorCode.tooLarge,
    429 => ErrorCode.rateLimited,
    502 || 503 || 504 => ErrorCode.upstream,
    507 => ErrorCode.diskFull,
    _ => ErrorCode.internal,
  };

  Map<String, Object?> _obj(Object? j) =>
      j is Map<String, Object?> ? j : throw const FormatException('atteso un oggetto');

  List<Object?> _list(Object? j, String key) {
    final v = _obj(j)[key];
    return v is List<Object?> ? v : throw FormatException('$key: attesa una lista');
  }

  // --- hub e spazi ----------------------------------------------------------

  @override
  Future<HubInfo> hub() async => HubInfo.fromJson(await _json('GET', 'hub'));

  @override
  Future<List<SpaceSummary>> spaces() async => [
    for (final s in _list(await _json('GET', 'spaces'), 'spaces')) SpaceSummary.fromJson(s),
  ];

  @override
  Future<SpaceDetails> createSpace(String name, Profile profile) async => SpaceDetails.fromJson(
    await _json('POST', 'spaces', body: {'name': name, 'profile': profile.name}),
  );

  @override
  Future<SpaceDetails> space(String id) async =>
      SpaceDetails.fromJson(await _json('GET', 'spaces/${_seg(id)}'));

  @override
  Future<SpaceDetails> updateSpace(String id, SpacePatch patch) async =>
      SpaceDetails.fromJson(await _json('PATCH', 'spaces/${_seg(id)}', body: patch.toJson()));

  @override
  Future<void> deleteSpace(String id) => _json('DELETE', 'spaces/${_seg(id)}');

  // --- metadati -------------------------------------------------------------

  @override
  Future<WorldInfo> world(String id) async =>
      WorldInfo.fromJson(await _json('GET', 'spaces/${_seg(id)}/world'));

  @override
  Uri iconUrl(String id) => _u('spaces/${_seg(id)}/icon');

  @override
  Future<PlayerList> players(String id) async =>
      PlayerList.fromJson(await _json('GET', 'spaces/${_seg(id)}/players'));

  @override
  Future<ModList> mods(String id) async =>
      ModList.fromJson(await _json('GET', 'spaces/${_seg(id)}/mods'));

  @override
  Uri modIconUrl(String id, String file) => _u('spaces/${_seg(id)}/mods/${_seg(file)}/icon');

  @override
  Future<ClientPack> pack(String id) async =>
      ClientPack.fromJson(await _json('GET', 'spaces/${_seg(id)}/pack'));

  @override
  Uri packUrl(String id) => _u('spaces/${_seg(id)}/pack.mrpack');

  @override
  Uri packModsUrl(String id) => _u('spaces/${_seg(id)}/pack-mods.zip');

  @override
  Future<PackFile?> packFile(String id) async {
    final g = await generation(id);
    final e = g.manifest.files[packFileName];
    if (e == null) return null;
    try {
      return PackFile.fromJson(await _json('GET', 'blobs/${_seg(e.h)}'));
    } on ApiError {
      return null;
    }
  }

  @override
  Future<SpaceStats> stats(String id) async =>
      SpaceStats.fromJson(await _json('GET', 'spaces/${_seg(id)}/stats'));

  // --- storia ---------------------------------------------------------------

  @override
  Future<List<GenerationSummary>> generations(String id, {int? before, int? limit}) async => [
    for (final g in _list(
      await _json(
        'GET',
        'spaces/${_seg(id)}/generations',
        query: {'before': before?.toString(), 'limit': limit?.toString()},
      ),
      'generations',
    ))
      GenerationSummary.fromJson(g),
  ];

  @override
  Future<Generation> generation(String id, {int? n}) async =>
      Generation.fromJson(await _json('GET', 'spaces/${_seg(id)}/generations/${n ?? 'head'}'));

  @override
  Future<GenerationChanges> diff(String id, int n, {int? limit}) async =>
      GenerationChanges.fromJson(
        await _json(
          'GET',
          'spaces/${_seg(id)}/generations/$n/diff',
          query: {'limit': limit?.toString()},
        ),
      );

  @override
  Uri zipUrl(String id, {int? n}) => _u('spaces/${_seg(id)}/generations/${n ?? 'head'}/zip');

  @override
  Future<int> freed(String id, int n) async {
    final b = _obj(await _json('GET', 'spaces/${_seg(id)}/generations/$n/freed'))['bytes'];
    return b is int ? b : throw const FormatException('bytes: atteso un intero');
  }

  @override
  Future<GenerationDeleted> deleteGeneration(String id, int n) async {
    final m = _obj(await _json('DELETE', 'spaces/${_seg(id)}/generations/$n'));
    final d = m['deleted'];
    final b = m['bytes'];
    return (deleted: d is int ? d : n, bytes: b is int ? b : 0);
  }

  @override
  Future<GenerationSummary> restore(String id, int n, {String message = ''}) async =>
      GenerationSummary.fromJson(
        await _json(
          'POST',
          'spaces/${_seg(id)}/restore',
          body: {'generation': n, if (message.isNotEmpty) 'message': message},
        ),
      );

  @override
  Future<GenerationSummary> restoreFile(String id, RestoreFileRequest request) async =>
      GenerationSummary.fromJson(
        await _json('POST', 'spaces/${_seg(id)}/restore-file', body: request.toJson()),
      );

  // --- lock -----------------------------------------------------------------

  @override
  Future<void> forceReleaseLock(String id) =>
      _json('DELETE', 'spaces/${_seg(id)}/lock', body: {'force': true});

  @override
  Future<PortCheck> portCheck(String id) async =>
      PortCheck.fromJson(await _json('POST', 'spaces/${_seg(id)}/lock/port-check'));

  // --- pulizia e spazio -----------------------------------------------------

  String _gcBase(String? space) => space == null ? 'gc' : 'spaces/${_seg(space)}/gc';

  @override
  Future<GcPreview> gcPreview({String? space, int? keep, HistorySettings? history}) async =>
      GcPreview.fromJson(
        await _json(
          'POST',
          '${_gcBase(space)}/preview',
          body: {'keep': ?keep, if (history != null) 'history': history.toJson()},
        ),
      );

  @override
  Future<GcReport> gc({String? space, int? keep}) async =>
      GcReport.fromJson(await _json('POST', _gcBase(space), body: {'keep': ?keep}));

  @override
  Future<HubUsage> usage() async => HubUsage.fromJson(await _json('GET', 'usage'));

  @override
  Future<ExclusionTest> testExclusion({
    required String path,
    Profile? profile,
    String? spaceId,
    List<String>? patterns,
  }) async => ExclusionTest.fromJson(
    await _json(
      'POST',
      'exclusions/test',
      body: {'path': path, 'profile': ?profile?.name, 'spaceId': ?spaceId, 'patterns': ?patterns},
    ),
  );

  // --- membri, sistema, impostazioni ----------------------------------------

  @override
  Future<MemberList> members() async => MemberList.fromJson(await _json('GET', 'members'));

  @override
  Future<MemberInfo> setRole(String memberId, MemberRole role) async => MemberInfo.fromJson(
    await _json('PUT', 'members/${_seg(memberId)}/role', body: {'role': role.name}),
  );

  @override
  Future<ZtnetStatus> refreshMembers() async =>
      ZtnetStatus.fromJson(await _json('POST', 'members/refresh'));

  @override
  Future<SystemInfo> system() async => SystemInfo.fromJson(await _json('GET', 'system'));

  @override
  Future<HubSettings> settings() async => HubSettings.fromJson(await _json('GET', 'settings'));

  @override
  Future<HubSettings> patchSettings(String section, Map<String, Object?> fields) async =>
      HubSettings.fromJson(await _json('PATCH', 'settings/${_seg(section)}', body: fields));

  // --- Telegram -------------------------------------------------------------

  @override
  Future<TelegramStatus> telegram() async =>
      TelegramStatus.fromJson(await _json('GET', 'telegram'));

  @override
  Future<TelegramStatus> patchTelegram(TelegramPatch patch) async =>
      TelegramStatus.fromJson(await _json('PATCH', 'telegram', body: patch.toJson()));

  @override
  Future<TelegramTestResult> testTelegram({
    String? token,
    String? chat,
    String? language,
    String? spaceId,
    String? topic,
  }) async => TelegramTestResult.fromJson(
    await _json(
      'POST',
      'telegram/test',
      body: {
        'token': ?token,
        'chat': ?chat,
        'language': ?language,
        'spaceId': ?spaceId,
        'topic': ?topic,
      },
    ),
  );

  @override
  Future<List<TelegramChat>> findTelegramChats({String? token}) async => [
    for (final c in _list(
      await _json('POST', 'telegram/find-chat', body: {'token': ?token}),
      'chats',
    ))
      TelegramChat.fromJson(c),
  ];

  // --- download -------------------------------------------------------------

  @override
  Future<DlListing> downloads() async => DlListing.fromJson(await _json('GET', 'dl'));

  @override
  Uri downloadUrl(String file) => _origin.resolve('dl/${_seg(file)}');

  // --- eventi ---------------------------------------------------------------

  @override
  Future<EventPage> events({
    int? after,
    int? before,
    int? limit,
    String? space,
    List<String>? types,
  }) async => EventPage.fromJson(
    await _json(
      'GET',
      'events',
      query: {
        'after': after?.toString(),
        'before': before?.toString(),
        'limit': limit?.toString(),
        'space': space,
        'types': types?.join(','),
      },
    ),
  );

  @override
  Stream<HubEvent> eventStream({int? after}) =>
      liveEvents(transport, _u('events/stream'), after: after);
}
