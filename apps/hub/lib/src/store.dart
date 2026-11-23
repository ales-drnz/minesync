// Cuore dell'hub: spazi, generazioni, lock, sessioni di push, guardie,
// retention e GC, impostazioni. Tutto ciò che è durevole passa da
// writeAtomic; lo stato in memoria è la verità finché l'hub gira e si
// ricostruisce da /data all'avvio.
//
// Concorrenza: un solo isolate. Le operazioni che spostano la testa di uno
// spazio girano sotto il suo mutex; lock e heartbeat cambiano lo stato in
// modo sincrono e non aspettano il mutex (un commit o una GC lunghi non li
// bloccano). Tutto ciò che cancella generazioni o blob (retention, pulizia
// manuale, eliminazione di una generazione) gira sotto un unico mutex.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ms_core/ms_core.dart';
import 'package:ms_protocol/ms_protocol.dart';

import 'blobs.dart';
import 'clock.dart';
import 'disk.dart';
import 'events.dart';
import 'jsonfile.dart';
import 'members.dart';
import 'mutex.dart';
import 'settings.dart';
import 'state.dart';
import 'system.dart';
import 'zip.dart';

/// Parametri del comportamento dello store (i test li accorciano).
final class StoreOptions {
  const StoreOptions({
    this.lockTtl = const Duration(seconds: 90),
    this.heartbeat = const Duration(seconds: 20),
    this.pushIdle = const Duration(hours: 1),
    this.committedKeep = const Duration(hours: 3),
    this.maxPushesPerMember = 4,
    this.maintenanceDelay = const Duration(seconds: 2),
    this.minFreeOverride,
    this.usageEvery = const Duration(minutes: 10),
  });

  final Duration lockTtl;
  final Duration heartbeat;

  /// Inattività dopo cui una sessione di push scade.
  final Duration pushIdle;

  /// Per quanto un push committato resta ripetibile (commit idempotente).
  final Duration committedKeep;
  final int maxPushesPerMember;

  /// Attesa tra un commit e retention + GC (raggruppa i commit vicini).
  final Duration maintenanceDelay;

  /// Soglia di spazio libero da MINESYNC_MIN_FREE: se c'è vince su
  /// Admin › Disco.
  final int? minFreeOverride;

  /// Ogni quanto al più si ricalcola l'uso del disco per spazio.
  final Duration usageEvery;
}

/// Esito di una manutenzione (retention + GC).
final class MaintenanceReport {
  MaintenanceReport({this.error});
  int generationsDeleted = 0;
  int blobsDeleted = 0;
  int bytesFreed = 0;

  /// Se valorizzato la GC si è fermata senza cancellare niente.
  final String? error;

  GcReport toReport() =>
      GcReport(generations: generationsDeleted, blobs: blobsDeleted, bytes: bytesFreed);
}

/// Che cosa è successo a un lock (per chi registra le sessioni di gioco).
enum LockChangeKind {
  /// Preso (anche al posto di uno stale: [LockChange.previous]).
  acquired,

  /// Heartbeat.
  renewed,

  /// Rilasciato da chi lo teneva.
  released,

  /// Tolto a forza (rilascio forzato o presa di un lock vivo):
  /// [LockChange.holder] è il lock tolto.
  forced,

  /// Ha appena superato il TTL senza heartbeat (una volta per silenzio).
  stale,
}

/// Un cambiamento del lock di uno spazio. [holder] è la vista pubblica del
/// lock interessato (senza token né indirizzo LAN).
final class LockChange {
  const LockChange(this.space, this.kind, this.holder, {this.previous, this.lan});
  final String space;
  final LockChangeKind kind;
  final LockHolder holder;

  /// Con [LockChangeKind.acquired]: il lock sostituito, se c'era.
  final LockHolder? previous;

  /// Indirizzo LAN dichiarato da chi ospita (solo per il DNS, mai da
  /// esporre).
  final String? lan;
}

/// Piano di una pulizia: che cosa resta e che cosa si cancellerebbe.
final class _GcPlan {
  /// Per spazio: generazioni su disco e quelle da cancellare.
  final rows = <SpaceState, ({List<int> ns, List<int> del})>{};

  /// Blob usati da qualcosa che resta (generazioni, push aperti, export).
  final referenced = <String>{};

  /// Per spazio: blob delle generazioni da cancellare, con la dimensione.
  final doomed = <SpaceState, Map<String, int>>{};

  String? error;

  /// Byte liberati per [st] (blob che nient'altro usa).
  int bytesOf(SpaceState st) {
    var n = 0;
    for (final e in (doomed[st] ?? const {}).entries) {
      if (!referenced.contains(e.key)) n += e.value;
    }
    return n;
  }

  /// Byte liberati in tutto (un blob conta una volta).
  int get bytes {
    final seen = <String>{};
    var n = 0;
    for (final d in doomed.values) {
      for (final e in d.entries) {
        if (!referenced.contains(e.key) && seen.add(e.key)) n += e.value;
      }
    }
    return n;
  }
}

/// Generazioni da conservare di uno spazio, dati i numeri presenti.
typedef _KeepFn = Set<int> Function(SpaceState st, List<int> ns);

final class HubStore {
  HubStore({
    required this.root,
    required this.clock,
    required this.events,
    required this.blobs,
    required this.disk,
    this.options = const StoreOptions(),
    DnsRuntime? dns,
    HubExtras? extras,
    void Function(String)? log,
  }) : dns = dns ?? DnsRuntime(),
       extras = extras ?? HubExtras(),
       _log = log ?? ((m) => stderr.writeln(m));

  final String root;
  final Clock clock;
  final EventLog events;
  final BlobStore blobs;
  final DiskProbe disk;
  final StoreOptions options;

  /// Stato del DNS integrato (per `dnsName`).
  final DnsRuntime dns;

  /// Dati di /dl e della build web.
  final HubExtras extras;
  final void Function(String) _log;

  Settings settings = Settings.defaults();

  /// Ultima modifica delle impostazioni.
  SettingsChange? settingsChanged;

  /// Chip del mondo e ultima sessione nei riassunti degli spazi (WorldExtras).
  WorldChip? Function(String id, String digest)? worldChipOf;
  SessionRecord? Function(String id)? lastSessionOf;
  final _settingsIo = Mutex();

  /// Chiamate dopo ogni modifica delle impostazioni (anche all'avvio, da chi
  /// si registra), per applicarle a caldo.
  final settingsListeners = <void Function(Settings)>[];

  /// Chiamate a ogni cambiamento di un lock, in modo sincrono.
  final lockListeners = <void Function(LockChange)>[];

  /// Arricchiscono il riassunto di uno spazio (es. `world`, `lastSession`).
  final summaryDecorators = <SpaceSummary Function(SpaceSummary)>[];

  /// Arricchisce la vista di un lock (es. `portCheck`) ovunque venga
  /// restituita.
  LockHolder Function(String space, LockHolder holder)? lockDecorator;

  final _spaces = <String, SpaceState>{};
  final _gone = <String>{};
  final _pushes = <String, PushSession>{};
  final _expired = <String>{};
  final _rng = Random.secure();

  // GC: mentre gira, ogni operazione che fa riferimento a blob li "appunta"
  // qui in modo sincrono; la GC non cancella un blob appuntato.
  bool _gcRunning = false;
  final _pinned = <String>{};

  // blob in lettura da un export ZIP: nessuna GC li tocca
  final _leases = <Set<String>>[];
  final _maint = Mutex();
  Timer? _maintTimer;
  Future<MaintenanceReport>? _maintRunning;
  Timer? _sweepTimer;
  Timer? _staleTimer;
  int _lastDiskFull = -1 << 62;
  int _lastDiskWarn = -1 << 62;

  HubUsage? _usage;
  Future<HubUsage>? _usageRunning;
  int _usageAt = -1 << 62;

  String get spacesDir => '$root/spaces';
  String get pushesDir => '$root/pushes';
  String get settingsPath => '$root/settings.json';

  // ---------------------------------------------------------------- apertura

  Future<void> open() async {
    await Directory(spacesDir).create(recursive: true);
    await Directory(pushesDir).create(recursive: true);
    await sweepPartFiles(root);
    await sweepPartFiles(pushesDir);
    final s = await tryReadJsonFile(settingsPath);
    if (s is Map<String, Object?>) {
      settings = Settings.fromJson(s['sections'] ?? s);
      try {
        if (s['changed'] != null) settingsChanged = SettingsChange.fromJson(s['changed']);
      } on FormatException {
        // solo informativo
      }
    }
    await for (final e in Directory(spacesDir).list()) {
      if (e is! Directory) continue;
      final name = e.uri.pathSegments.where((p) => p.isNotEmpty).last;
      if (name.startsWith('.deleted-')) {
        // cancellazione interrotta: si completa
        await e.delete(recursive: true);
        continue;
      }
      final st = await _loadSpace(e.path);
      if (st != null) _spaces[st.id] = st;
    }
    await _loadPushes();
    _sweepTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      expirePushes();
      diskTick();
    });
    _staleTimer = Timer.periodic(const Duration(seconds: 5), (_) => checkStaleLocks());
  }

  Future<SpaceState?> _loadSpace(String dir) async {
    final SpaceMeta meta;
    try {
      meta = SpaceMeta.fromJson(await readJsonFile('$dir/space.json'));
    } catch (e) {
      // cartella senza descrittore valido: non è uno spazio
      _log('hub: salto $dir: $e');
      return null;
    }
    final st = SpaceState(meta, dir);
    await Directory(st.generationsDir).create(recursive: true);
    await sweepPartFiles(dir);
    await sweepPartFiles(st.generationsDir);
    await _loadHead(st);
    final lock = await tryReadJsonFile('$dir/lock.json');
    if (lock != null) {
      try {
        st.lock = LockState.fromJson(lock, clock);
      } on FormatException catch (e) {
        _log('hub: ${meta.id}: lock.json illeggibile ($e), ignorato');
      }
    }
    return st;
  }

  /// Numeri delle generazioni presenti su disco, in ordine.
  Future<List<int>> _genNumbers(SpaceState st) async {
    final out = <int>[];
    try {
      await for (final f in Directory(st.generationsDir).list()) {
        final name = f.uri.pathSegments.last;
        if (f is! File || !name.endsWith('.json')) continue;
        final n = int.tryParse(name.substring(0, name.length - 5));
        if (n != null && n > 0 && '$n.json' == name) out.add(n);
      }
    } on FileSystemException {
      if (!st.deleted) rethrow;
    }
    out.sort();
    return out;
  }

  /// Legge e verifica la generazione [n]: numero coerente e digest uguale a
  /// quello del manifest. Lancia [FormatException] o [FileSystemException].
  Future<StoredGeneration> _readGen(SpaceState st, int n) async {
    final j = await readJsonFile(st.genPath(n));
    final gen = Generation.fromJson(j);
    if (gen.n != n) throw FormatException('generazione $n: il file dice ${gen.n}');
    if (gen.manifest.digest() != gen.digest) {
      throw FormatException('generazione $n: digest diverso dal manifest');
    }
    final pid = (j! as Map<String, Object?>)['pushId'];
    return (gen: gen, pushId: pid is String ? pid : null);
  }

  /// Testa da head.json; se illeggibile o incoerente si ricostruisce dalla
  /// generazione valida più alta. Le generazioni oltre la testa (commit
  /// interrotto prima di spostarla, o file illeggibili) si mettono da parte
  /// come `<n>.json.orphan`.
  Future<void> _loadHead(SpaceState st) async {
    final ns = await _genNumbers(st);
    int? n;
    String? digest;
    final h = await tryReadJsonFile('${st.dir}/head.json');
    if (h is Map<String, Object?> && h['n'] is int && h['digest'] is String) {
      n = h['n']! as int;
      digest = h['digest']! as String;
    }
    StoredGeneration? head;
    var valid = false;
    if (n == 0 && digest == emptyDigest) {
      valid = true;
    } else if (n != null && n > 0) {
      try {
        head = await _readGen(st, n);
        valid = head.gen.digest == digest;
      } catch (_) {
        valid = false;
      }
    }
    if (!valid) {
      head = null;
      for (final k in ns.reversed) {
        try {
          head = await _readGen(st, k);
          break;
        } catch (e) {
          _log('hub: ${st.id}: generazione $k illeggibile ($e)');
        }
      }
      n = head?.gen.n ?? 0;
      _log('hub: ${st.id}: head.json non valido, testa ricostruita dalla generazione $n');
    }
    final headN = n!;
    for (final k in ns.where((k) => k > headN)) {
      await File(st.genPath(k)).rename('${st.genPath(k)}.orphan');
    }
    if (head != null) {
      st
        ..headN = head.gen.n
        ..headDigest = head.gen.digest
        ..headManifest = head.gen.manifest
        ..headSummary = head.gen.summary
        ..headPushId = head.pushId;
    }
    if (!valid) await _writeHead(st);
    // riassunti per la cronologia (i file illeggibili restano fuori: la GC
    // se ne accorge e si ferma)
    for (final k in ns.where((k) => k <= headN)) {
      if (k == headN && head != null) {
        st.summaries[k] = head.gen.summary;
        continue;
      }
      try {
        st.summaries[k] = (await _readGen(st, k)).gen.summary;
      } catch (e) {
        _log('hub: ${st.id}: generazione $k illeggibile ($e)');
      }
    }
  }

  Future<void> _writeHead(SpaceState st) =>
      writeJsonAtomic('${st.dir}/head.json', {'n': st.headN, 'digest': st.headDigest});

  Future<void> _loadPushes() async {
    await for (final f in Directory(pushesDir).list()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      try {
        final p = PushSession.fromJson(await readJsonFile(f.path), clock);
        if (!_spaces.containsKey(p.space)) {
          await f.delete();
          continue;
        }
        _pushes[p.id] = p;
      } catch (e) {
        _log('hub: sessione di push illeggibile ${f.path}: $e');
        await f.delete();
      }
    }
  }

  Future<void> close() async {
    _sweepTimer?.cancel();
    _staleTimer?.cancel();
    _maintTimer?.cancel();
    await _maintRunning;
    await _usageRunning?.catchError((Object _) => _emptyUsage());
    await _maint.run(() {});
  }

  // ---------------------------------------------------------------- utilità

  String _randomId(int bytes) {
    final sb = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      sb.write(_rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  SpaceState _space(String id) {
    final st = _spaces[id];
    if (st != null && !st.deleted) return st;
    if (_gone.contains(id)) throw ApiError(ErrorCode.spaceGone, 'space $id was deleted');
    throw ApiError(ErrorCode.notFound, 'space $id: not found');
  }

  void _pin(Iterable<String> hashes) {
    if (_gcRunning) _pinned.addAll(hashes);
  }

  bool _leased(String h) => _leases.any((s) => s.contains(h));

  /// Protegge [hashes] da ogni GC finché non si chiama la funzione
  /// restituita (export ZIP in corso).
  void Function() leaseBlobs(Set<String> hashes) {
    _leases.add(hashes);
    var done = false;
    return () {
      if (done) return;
      done = true;
      _leases.remove(hashes);
    };
  }

  Settings effectiveSettings(SpaceState st) => settings.withOverrides(st.meta.overrides);

  /// Impostazioni effettive dello spazio [id]; quelle globali se non esiste.
  Settings effectiveSettingsOf(String id) {
    final st = _spaces[id];
    return st == null ? settings : effectiveSettings(st);
  }

  /// Generazione [n] dello spazio, dalla memoria se è la testa.
  Future<StoredGeneration> _gen(SpaceState st, int n) async {
    if (n == st.headN && st.headSummary != null) {
      return (gen: Generation(st.headSummary!, st.headManifest), pushId: st.headPushId);
    }
    return _readGen(st, n);
  }

  ApiError _genNotFound(int n) =>
      ApiError(ErrorCode.notFound, 'generation $n: not found', details: {'generation': n});

  LockHolder _holder(SpaceState st, LockState l) {
    final h = l.holder(clock, options.lockTtl);
    final d = lockDecorator;
    return d == null ? h : d(st.id, h);
  }

  void _lockChanged(LockChange c) {
    for (final f in lockListeners.toList()) {
      try {
        f(c);
      } catch (e, s) {
        _log('hub: ascoltatore del lock: $e\n$s');
      }
    }
  }

  // ---------------------------------------------------------------- disco

  DiskInfo diskInfo() {
    final u = disk(root);
    if (u == null) return const DiskInfo(free: -1, total: -1, minFree: 0);
    return DiskInfo(free: u.free, total: u.total, minFree: minFreeFor(u.total));
  }

  /// Soglia effettiva: MINESYNC_MIN_FREE se c'è, altrimenti Admin › Disco.
  int minFreeFor(int total) => options.minFreeOverride ?? settings.disk.thresholdFor(total);

  /// Lancia `disk_full` se lo spazio libero è sotto la soglia. Al più un
  /// evento `disk` `full` all'ora; sotto il doppio della soglia un `warn` al
  /// più ogni 6 ore.
  void checkDisk() {
    final u = disk(root);
    if (u == null) return;
    final min = minFreeFor(u.total);
    if (u.free >= min) {
      _warnDisk(u, min);
      return;
    }
    final now = clock.monoMs();
    if (now - _lastDiskFull >= const Duration(hours: 1).inMilliseconds) {
      _lastDiskFull = now;
      events.publish(
        EventType.disk,
        data: {'free': u.free, 'total': u.total, 'minFree': min, 'level': 'full'},
      );
    }
    throw ApiError(
      ErrorCode.diskFull,
      'hub storage is full: ${u.free} bytes free, at least $min required',
      details: {'free': u.free, 'minFree': min},
    );
  }

  void _warnDisk(DiskUsage u, int min) {
    if (u.free >= 2 * min) return;
    final now = clock.monoMs();
    if (now - _lastDiskWarn < const Duration(hours: 6).inMilliseconds) return;
    _lastDiskWarn = now;
    events.publish(
      EventType.disk,
      data: {'free': u.free, 'total': u.total, 'minFree': min, 'level': 'warn'},
    );
  }

  /// Controllo periodico dello spazio (solo l'avviso, niente rifiuti).
  void diskTick() {
    final u = disk(root);
    if (u == null) return;
    final min = minFreeFor(u.total);
    if (u.free >= min) _warnDisk(u, min);
  }

  // ---------------------------------------------------------------- impostazioni

  /// `GET /settings`.
  HubSettings hubSettings() => HubSettings(
    sections: settings.sections,
    defaults: const SettingsSections(),
    changed: settingsChanged,
  );

  Future<void> _saveSettings(Settings s, SettingsChange? c) => writeJsonAtomic(settingsPath, {
    'sections': s.toJson(),
    if (c != null) 'changed': c.toJson(),
  }, mode: 0x180);

  void _notifySettings() {
    for (final f in settingsListeners.toList()) {
      try {
        f(settings);
      } catch (e, s) {
        _log('hub: applicazione delle impostazioni: $e\n$s');
      }
    }
  }

  /// `PATCH /settings/{section}`: valida tutto, salva, applica e pubblica.
  Future<HubSettings> patchSettings(Identity who, String section, Object? body) => _settingsIo.run(
    () async {
      if (!isSettingsSection(section)) {
        throw ApiError(ErrorCode.notFound, 'no such settings section: $section');
      }
      final values = validateSection(section, body);
      final next = settings.withValues(section, values);
      final c = _change(who, section);
      await _saveSettings(next, c);
      settings = next;
      settingsChanged = c;
      events.publish(EventType.settings, actor: who.name, data: settingsEventData(section, values));
      _notifySettings();
      return hubSettings();
    },
  );

  SettingsChange _change(Identity who, String section) =>
      SettingsChange(by: who.name, byId: who.id, at: clock.wallMs(), section: section);

  /// Registra una modifica fatta altrove (Telegram) come «Ultima modifica».
  /// Non pubblica eventi: li pubblica chi ha fatto la modifica.
  Future<void> noteSettingsChange(Identity who, String section) => _settingsIo.run(() async {
    final c = _change(who, section);
    await _saveSettings(settings, c);
    settingsChanged = c;
  });

  // ---------------------------------------------------------------- spazi

  SpaceSummary _summary(SpaceState st) {
    var s = SpaceSummary(
      id: st.id,
      name: st.meta.name,
      profile: st.meta.profile,
      createdAt: st.meta.createdAt,
      head: st.headSummary,
      lock: st.lock == null ? null : _holder(st, st.lock!),
      dnsName: dns.nameOf(st.id),
      world: worldChipOf?.call(st.id, st.headDigest),
      lastSession: lastSessionOf?.call(st.id),
    );
    for (final d in summaryDecorators.toList()) {
      try {
        s = d(s);
      } catch (e, stack) {
        _log('hub: ${st.id}: riassunto: $e\n$stack');
      }
    }
    return s;
  }

  SpaceDetails _details(SpaceState st) {
    final prof = settings.exclusionsOf(st.meta.profile);
    return SpaceDetails(
      _summary(st),
      exclusions: [...prof, ...st.meta.exclusions],
      ownExclusions: st.meta.exclusions,
      profileExclusions: prof,
      settings: effectiveSettings(st).spaceSettings,
      inherited: settings.spaceSettings,
      overrides: st.meta.overrides,
      usage: _usage?.spaces[st.id],
    );
  }

  List<SpaceSummary> listSpaces() {
    final out = [for (final s in _spaces.values) _summary(s)];
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  Map<String, Object?> details(String id) => _details(_space(id)).toJson();

  /// Riassunto di uno spazio (per chi aggiunge endpoint).
  SpaceSummary summary(String id) => _summary(_space(id));

  /// Id degli spazi presenti.
  Iterable<String> get spaceIds => _spaces.keys;

  /// Id di uno spazio dal nome: minuscole, cifre e trattini; univoco.
  String slugFor(String name) {
    var s = name.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-');
    s = s.replaceAll(RegExp(r'^-+|-+$'), '');
    if (s.length > 48) s = s.substring(0, 48).replaceAll(RegExp(r'-+$'), '');
    if (s.isEmpty) s = 'space';
    // un nome di dispositivo di Windows (con, aux, ...) non è una cartella valida
    if (checkPath(s) != null) s = 'space-$s';
    var id = s;
    for (var i = 2; _spaces.containsKey(id) || _gone.contains(id); i++) {
      id = '$s-$i';
    }
    return id;
  }

  Future<Map<String, Object?>> createSpace(
    Identity who, {
    required String name,
    required Profile profile,
    List<String> exclusions = const [],
  }) async {
    final n = validateSpaceName(name);
    final ex = validateExclusions(exclusions);
    final id = slugFor(n);
    final dir = '$spacesDir/$id';
    final meta = SpaceMeta(
      id: id,
      name: n,
      profile: profile,
      createdAt: clock.wallMs(),
      exclusions: ex,
    );
    final st = SpaceState(meta, dir);
    _spaces[id] = st; // riserva l'id subito
    try {
      await Directory(st.generationsDir).create(recursive: true);
      await writeJsonAtomic('$dir/space.json', meta.toJson());
      await _writeHead(st);
      await fsyncDir(spacesDir);
    } catch (_) {
      _spaces.remove(id);
      rethrow;
    }
    events.publish(EventType.spaceCreate, space: id, actor: who.name, data: {'name': n});
    return _details(st).toJson();
  }

  /// Nome, esclusioni proprie e sovrascritture di uno spazio. Le
  /// sovrascritture aggiornano anche «Ultima modifica» (sezione `spaces`).
  Future<Map<String, Object?>> patchSpace(Identity who, String id, Map<String, Object?> body) {
    final st = _space(id);
    return st.mutex.run(() async {
      _space(id);
      String? name;
      List<String>? ex;
      Map<String, Object?>? ov;
      for (final k in body.keys) {
        if (k != 'name' && k != 'exclusions' && k != 'overrides') {
          throw ApiError(ErrorCode.badRequest, 'unknown field $k', details: {'field': k});
        }
      }
      if (body.containsKey('name')) {
        final v = body['name'];
        if (v is! String) {
          throw const ApiError(
            ErrorCode.badRequest,
            'name: expected a string',
            details: {'field': 'name'},
          );
        }
        name = validateSpaceName(v);
      }
      if (body.containsKey('exclusions')) {
        final v = body['exclusions'];
        if (v is! List<Object?> || v.any((e) => e is! String)) {
          throw const ApiError(
            ErrorCode.badRequest,
            'exclusions: expected a list of strings',
            details: {'field': 'exclusions'},
          );
        }
        ex = validateExclusions(v.cast<String>());
      }
      if (body.containsKey('overrides')) ov = mergeOverrides(st.meta.overrides, body['overrides']);
      final meta = st.meta.copyWith(name: name, exclusions: ex, overrides: ov);
      await writeJsonAtomic('${st.dir}/space.json', meta.toJson());
      st.meta = meta;
      events.publish(
        EventType.spaceUpdate,
        space: id,
        actor: who.name,
        data: {'fields': body.keys.toList()},
      );
      if (ov != null) {
        await _settingsIo.run(() async {
          final c = _change(who, 'spaces');
          await _saveSettings(settings, c);
          settingsChanged = c;
        });
      }
      return _details(st).toJson();
    });
  }

  Future<void> deleteSpace(Identity who, String id) {
    final st = _space(id);
    return st.mutex.run(() async {
      _space(id);
      final l = st.lock;
      if (l != null && !l.isStale(clock, options.lockTtl)) throw _lockedBy(st, l);
      final trash = '$spacesDir/.deleted-$id-${_randomId(4)}';
      await Directory(st.dir).rename(trash);
      await fsyncDir(spacesDir);
      st
        ..deleted = true
        ..lock = null;
      _spaces.remove(id);
      _gone.add(id);
      for (final p in _pushes.values.where((p) => p.space == id).toList()) {
        await _dropPush(p, expired: false);
      }
      await Directory(trash).delete(recursive: true);
      events.publish(EventType.spaceDelete, space: id, actor: who.name);
      scheduleMaintenance();
    });
  }

  /// `POST /exclusions/test`: [path] contro le esclusioni di uno spazio, di
  /// un profilo o di una lista non salvata ([patterns]).
  ExclusionTest testExclusions({
    required String path,
    String? spaceId,
    Profile? profile,
    List<String>? patterns,
  }) {
    if (utf8.encode(path).length > maxPathBytes) {
      throw const ApiError(
        ErrorCode.badRequest,
        'path: at most 1024 bytes',
        details: {'field': 'path'},
      );
    }
    List<String> prof = const [];
    List<String> own = const [];
    if (patterns != null) {
      own = patterns;
    } else if (spaceId != null) {
      final st = _space(spaceId);
      prof = settings.exclusionsOf(st.meta.profile);
      own = st.meta.exclusions;
    } else {
      prof = settings.exclusionsOf(profile ?? Profile.minecraft);
    }
    final hit = Exclusions([...prof, ...own]).firstMatch(path);
    if (hit == null) return ExclusionTest(path: path, excluded: false);
    final ExclusionSource src;
    if (systemExclusions.contains(hit)) {
      src = ExclusionSource.system;
    } else if (patterns != null) {
      src = ExclusionSource.draft;
    } else if (prof.any((p) => p.trim() == hit)) {
      src = ExclusionSource.profile;
    } else {
      src = ExclusionSource.space;
    }
    return ExclusionTest(path: path, excluded: true, pattern: hit, source: src);
  }

  // ---------------------------------------------------------------- generazioni

  GenerationSummary _genZero(SpaceState st) => GenerationSummary(
    n: 0,
    parent: 0,
    digest: emptyDigest,
    authorId: '',
    author: '',
    message: '',
    ts: st.meta.createdAt,
    kind: GenerationKind.push,
    stats: const GenerationStats(files: 0, size: 0),
  );

  /// Cronologia, dalla più recente: generazioni con n < [before].
  Map<String, Object?> history(String id, {int? before, int limit = 50}) {
    final st = _space(id);
    final out = <GenerationSummary>[];
    for (final n in st.summaries.keys.toList().reversed) {
      if (before != null && n >= before) continue;
      out.add(st.summaries[n]!);
      if (out.length >= limit) break;
    }
    final more = out.isNotEmpty && st.summaries.firstKey()! < out.last.n;
    return {
      'generations': [for (final g in out) g.toJson()],
      'next': more ? out.last.n : null,
    };
  }

  /// Una generazione completa; [n] null = la testa.
  Future<Generation> generation(String id, int? n) async {
    final st = _space(id);
    final k = n ?? st.headN;
    if (k == 0) return Generation(_genZero(st), Manifest.empty);
    if (!st.summaries.containsKey(k)) throw _genNotFound(k);
    try {
      return (await _gen(st, k)).gen;
    } on FileSystemException {
      throw _genNotFound(k);
    }
  }

  GenerationStats _stats(Manifest parent, Manifest m) {
    final d = ManifestDiff(parent, m);
    return GenerationStats(
      files: m.length,
      size: m.totalSize,
      added: d.added.length,
      changed: d.changed.length,
      removed: d.removed.length,
    );
  }

  /// Scrive la generazione e poi sposta la testa. Va chiamata sotto il mutex.
  Future<GenerationSummary> _commitGeneration(
    SpaceState st, {
    required Identity who,
    required Manifest manifest,
    required String message,
    required GenerationKind kind,
    int? restoredFrom,
    String? restoredPath,
    List<DamagedFile> damaged = const [],
    String? pushId,
  }) async {
    final n = st.headN + 1;
    final summary = GenerationSummary(
      n: n,
      parent: st.headN,
      digest: manifest.digest(),
      authorId: who.id,
      author: who.name,
      message: message,
      ts: clock.wallMs(),
      kind: kind,
      stats: _stats(st.headManifest, manifest),
      restoredFrom: restoredFrom,
      restoredPath: restoredPath,
      damaged: damaged,
    );
    final gen = Generation(summary, manifest);
    await writeJsonAtomic(st.genPath(n), {...gen.toJson(), 'pushId': ?pushId});
    await writeJsonAtomic('${st.dir}/head.json', {'n': n, 'digest': summary.digest});
    st
      ..headN = n
      ..headDigest = summary.digest
      ..headManifest = manifest
      ..headSummary = summary
      ..headPushId = pushId;
    st.summaries[n] = summary;
    return summary;
  }

  List<String> _missingBlobs(Manifest m) => [
    for (final b in m.blobs)
      if (!blobs.has(b)) b,
  ];

  Future<GenerationSummary> restore(Identity who, String id, int n, {String message = ''}) {
    final st = _space(id);
    return st.mutex.run(() async {
      _space(id);
      final l = st.lock;
      if (l != null && l.memberId != who.id && !l.isStale(clock, options.lockTtl)) {
        throw _lockedBy(st, l);
      }
      checkDisk();
      if (n < 0 || n > st.headN || (n > 0 && !st.summaries.containsKey(n))) {
        throw _genNotFound(n);
      }
      final Manifest m;
      try {
        m = n == 0 ? Manifest.empty : (await _gen(st, n)).gen.manifest;
      } on FileSystemException {
        throw _genNotFound(n);
      }
      _pin(m.blobs);
      final missing = _missingBlobs(m);
      if (missing.isNotEmpty) {
        throw ApiError(
          ErrorCode.pushIncomplete,
          'generation $n: ${missing.length} blobs are missing',
          details: {'missing': missing.take(1000).toList()},
        );
      }
      final s = await _commitGeneration(
        st,
        who: who,
        manifest: m,
        message: message.isEmpty ? 'restore of generation $n' : message,
        kind: GenerationKind.restore,
        restoredFrom: n,
      );
      events.publish(
        EventType.restore,
        space: id,
        actor: who.name,
        data: {'n': s.n, 'restoredFrom': n},
      );
      scheduleMaintenance();
      return s;
    });
  }

  /// La generazione più recente prima di [below] in cui [path] c'è e non è
  /// segnato danneggiato, con la sua voce; null se nessuna. Le generazioni
  /// illeggibili si saltano.
  Future<(int, FileEntry)?> _lastIntact(SpaceState st, String path, int below) async {
    for (final k in st.summaries.keys.toList().reversed) {
      if (k >= below) continue;
      final s = st.summaries[k]!;
      if (s.damaged.any((d) => d.path == path)) continue;
      try {
        final e = (await _gen(st, k)).gen.manifest[path];
        if (e != null) return (k, e);
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// Ripristina un solo file (B-GEN-12, B-GEN-14): nuova generazione uguale
  /// alla testa con [req.path] preso da [req.from] (0 = la più recente
  /// integra prima della testa). Rifiutato con qualunque lock vivo.
  Future<GenerationSummary> restoreFile(Identity who, String id, RestoreFileRequest req) {
    final st = _space(id);
    final problem = checkPath(req.path);
    if (problem != null) {
      throw ApiError(
        ErrorCode.badPath,
        'invalid path "${req.path}" (${problem.name})',
        details: {'path': req.path, 'reason': problem.name},
      );
    }
    if (req.from < 0) {
      throw const ApiError(ErrorCode.badRequest, 'from: invalid', details: {'field': 'from'});
    }
    return st.mutex.run(() async {
      _space(id);
      final l = st.lock;
      if (l != null && !l.isStale(clock, options.lockTtl)) throw _lockedBy(st, l);
      checkDisk();
      final int from;
      final FileEntry entry;
      if (req.from == 0) {
        final hit = await _lastIntact(st, req.path, st.headN);
        if (hit == null) {
          throw ApiError(
            ErrorCode.notFound,
            '${req.path}: no earlier intact version',
            details: {'path': req.path},
          );
        }
        (from, entry) = hit;
      } else {
        if (req.from > st.headN || !st.summaries.containsKey(req.from)) {
          throw _genNotFound(req.from);
        }
        final Manifest m;
        try {
          m = (await _gen(st, req.from)).gen.manifest;
        } on FileSystemException {
          throw _genNotFound(req.from);
        }
        final e = m[req.path];
        if (e == null) {
          throw ApiError(
            ErrorCode.notFound,
            '${req.path}: not in generation ${req.from}',
            details: {'path': req.path, 'generation': req.from},
          );
        }
        from = req.from;
        entry = e;
      }
      _pin(entry.blobs);
      final missing = [
        for (final b in entry.blobs)
          if (!blobs.has(b)) b,
      ];
      if (missing.isNotEmpty) {
        throw ApiError(
          ErrorCode.blobsMissing,
          '${req.path}: ${missing.length} blobs are missing',
          details: {'missing': missing},
        );
      }
      final files = Map.of(st.headManifest.files)..[req.path] = entry;
      final m = Manifest(files);
      final s = await _commitGeneration(
        st,
        who: who,
        manifest: m,
        message: req.message.isEmpty ? 'restore of ${req.path} from generation $from' : req.message,
        kind: GenerationKind.restore,
        restoredFrom: from,
        restoredPath: req.path,
        damaged: [
          for (final d in st.headSummary?.damaged ?? const <DamagedFile>[])
            if (d.path != req.path) d,
        ],
      );
      events.publish(
        EventType.restoreFile,
        space: id,
        actor: who.name,
        data: {'n': s.n, 'restoredFrom': from, 'path': req.path},
      );
      scheduleMaintenance();
      return s;
    });
  }

  /// Differenze della generazione [n] con la precedente conservata.
  Future<GenerationChanges> diff(String id, int n, {int limit = diffDefaultLimit}) async {
    final st = _space(id);
    if (n == 0) {
      return const GenerationChanges(
        n: 0,
        parent: 0,
        added: DiffSection.empty,
        changed: DiffSection.empty,
        removed: DiffSection.empty,
      );
    }
    final s = st.summaries[n];
    if (s == null) throw _genNotFound(n);
    final Generation g;
    try {
      g = (await _gen(st, n)).gen;
    } on FileSystemException {
      throw _genNotFound(n);
    }
    var parent = s.parent;
    if (parent != 0 && !st.summaries.containsKey(parent)) {
      parent = st.summaries.lastKeyBefore(n) ?? 0;
    }
    var pm = Manifest.empty;
    if (parent != 0) {
      try {
        pm = (await _gen(st, parent)).gen.manifest;
      } catch (e) {
        throw ApiError(ErrorCode.internal, 'generation $parent unreadable ($e)');
      }
    }
    final d = ManifestDiff(pm, g.manifest);
    DiffSection section(List<String> paths, DiffEntry Function(String) f) {
      final sorted = [...paths]..sort();
      return DiffSection(total: sorted.length, items: [for (final p in sorted.take(limit)) f(p)]);
    }

    final damaged = <DamagedReport>[];
    for (final f in s.damaged) {
      final hit = await _lastIntact(st, f.path, n);
      damaged.add(DamagedReport(file: f, lastIntact: hit?.$1));
    }
    return GenerationChanges(
      n: n,
      parent: parent,
      added: section(d.added, (p) => DiffEntry(path: p, size: g.manifest[p]!.size)),
      changed: section(
        d.changed,
        (p) => DiffEntry(path: p, size: g.manifest[p]!.size, prevSize: pm[p]!.size),
      ),
      removed: section(d.removed, (p) => DiffEntry(path: p, size: pm[p]!.size)),
      damaged: damaged,
    );
  }

  /// Prepara l'export ZIP della generazione [n] (null = la testa): controlla
  /// che ci siano tutti i blob (`blobs_missing` altrimenti, B-SPACE-03) e li
  /// protegge dalla GC finché non si chiama `release`.
  Future<({ZipPlan plan, String fileName, void Function() release})> exportZip(
    String id,
    int? n, {
    bool force64 = false,
  }) async {
    final st = _space(id);
    final g = await generation(id, n);
    final m = g.manifest;
    final release = leaseBlobs(m.blobs);
    try {
      final missing = _missingBlobs(m);
      if (missing.isNotEmpty) {
        throw ApiError(
          ErrorCode.blobsMissing,
          'generation ${g.n}: ${missing.length} blobs are missing',
          details: {'missing': missing.take(1000).toList()},
        );
      }
      final paths = m.files.keys.toList()..sort();
      final items = [
        for (final p in paths)
          ZipItem(name: p, size: m[p]!.size, blobs: m[p]!.blobs.toList(), exec: m[p]!.x),
      ];
      final plan = ZipPlan(
        items,
        time: DateTime.fromMillisecondsSinceEpoch(g.summary.ts),
        force64: force64,
      );
      return (plan: plan, fileName: '${st.id}-${g.n}.zip', release: release);
    } catch (_) {
      release();
      rethrow;
    }
  }

  // ---------------------------------------------------------------- lock

  ApiError _lockedBy(SpaceState st, LockState l) => ApiError(
    ErrorCode.locked,
    'space ${st.id} is locked by ${l.name}',
    details: {'lock': _holder(st, l).toJson()},
  );

  Future<void> _persistLock(SpaceState st) => st.lockIo.run(() async {
    if (st.deleted) return;
    final l = st.lock;
    final path = '${st.dir}/lock.json';
    if (l != null) {
      await writeJsonAtomic(path, l.toJson(), mode: 0x180);
    } else {
      try {
        await File(path).delete();
        await fsyncDir(st.dir);
      } on FileSystemException {
        // già assente
      }
    }
  });

  int _duration(LockState l) => max(0, clock.wallMs() - l.since);

  /// Prende il lock. Lancia `locked` se un altro lo tiene vivo (o lo stesso
  /// membro senza force), `forbidden` se si forza il lock vivo di un altro
  /// senza essere admin, `disk_full` col disco pieno.
  Future<(LockGrant, LockHolder)> acquire(
    Identity who, {
    required bool admin,
    required String id,
    required LockInfo info,
    bool force = false,
    String? ip,
  }) async {
    final st = _space(id);
    checkDisk();
    final prev = st.lock;
    final live = prev != null && !prev.isStale(clock, options.lockTtl);
    if (live) {
      if (!force) throw _lockedBy(st, prev);
      if (prev.memberId != who.id && !admin) {
        throw const ApiError(ErrorCode.forbidden, 'only an admin can take over a live lock');
      }
    }
    final l = LockState(
      token: _randomId(32),
      memberId: who.id,
      name: who.name,
      since: clock.wallMs(),
      lastBeat: clock.wallMs(),
      lastBeatMono: clock.monoMs(),
      info: info,
      ip: ip,
    );
    final prevHolder = prev == null ? null : _holder(st, prev);
    st.lock = l;
    await _persistLock(st);
    if (live) {
      events.publish(
        EventType.force,
        space: id,
        actor: who.name,
        data: {'from': prev.name, if (prev.isPlay) 'durationMs': _duration(prev)},
      );
      _lockChanged(LockChange(id, LockChangeKind.forced, prevHolder!));
    } else {
      events.publish(
        EventType.lock,
        space: id,
        actor: who.name,
        data: {if (info.action != null) 'action': info.action, 'tookOver': ?prev?.name},
      );
    }
    final h = _holder(st, l);
    _lockChanged(LockChange(id, LockChangeKind.acquired, h, previous: prevHolder, lan: info.lan));
    return (
      LockGrant(
        token: l.token,
        ttlMs: options.lockTtl.inMilliseconds,
        heartbeatMs: options.heartbeat.inMilliseconds,
      ),
      h,
    );
  }

  /// Rinnova il lock e aggiorna `info`. `space_gone` se lo spazio è stato
  /// cancellato, `lock_lost` se il token non è più quello del lock.
  Future<LockHolder> heartbeat(
    Identity who,
    String id,
    String token,
    LockInfo? info, {
    String? ip,
  }) async {
    final st = _space(id);
    final l = st.lock;
    if (l == null || l.token != token) {
      throw const ApiError(ErrorCode.lockLost, 'the lock is no longer held by this session');
    }
    l
      ..beat(clock)
      ..name = who.name;
    var changed = info != null && jsonEncode(info.toJson()) != jsonEncode(l.info.toJson());
    if (info != null) l.info = info;
    // chi ospita può cambiare indirizzo (rete ZeroTier riconnessa)
    if (ip != null && ip != l.ip) {
      l.ip = ip;
      changed = true;
    }
    if (changed) await _persistLock(st);
    final h = _holder(st, l);
    _lockChanged(LockChange(id, LockChangeKind.renewed, h, lan: l.info.lan));
    return h;
  }

  /// Rilascia il lock con il proprio token, oppure con [force]: un lock
  /// scaduto lo può togliere chiunque, uno vivo solo un admin.
  Future<void> release(
    Identity who, {
    required bool admin,
    required String id,
    String? token,
    bool force = false,
  }) async {
    final st = _space(id);
    final l = st.lock;
    if (l == null) return;
    var forced = false;
    if (token == null || token != l.token) {
      if (!force) {
        throw const ApiError(ErrorCode.lockLost, 'the lock is no longer held by this session');
      }
      if (!l.isStale(clock, options.lockTtl) && !admin) {
        throw const ApiError(ErrorCode.forbidden, 'only an admin can release a live lock');
      }
      forced = true;
    }
    final h = _holder(st, l);
    st.lock = null;
    await _persistLock(st);
    events.publish(
      forced ? EventType.force : EventType.unlock,
      space: id,
      actor: who.name,
      data: {
        if (forced) 'from': l.name,
        if (forced) 'released': true,
        if (l.isPlay) 'durationMs': _duration(l),
      },
    );
    _lockChanged(LockChange(id, forced ? LockChangeKind.forced : LockChangeKind.released, h));
  }

  LockHolder? lockSnapshot(String id) {
    final st = _spaces[id];
    final l = st?.lock;
    return st == null || l == null ? null : _holder(st, l);
  }

  /// Indirizzo LAN dichiarato da chi ospita (solo per il DNS a orizzonte
  /// diviso: non va mai restituito).
  String? lockLan(String id) => _spaces[id]?.lock?.info.lan;

  /// Pubblica `stale` una volta per ogni lock che ha appena superato il TTL
  /// (gira ogni 5 secondi; un heartbeat successivo azzera).
  void checkStaleLocks() {
    for (final st in _spaces.values.toList()) {
      final l = st.lock;
      if (l == null || l.staleNotified || !l.isStale(clock, options.lockTtl)) continue;
      l.staleNotified = true;
      events.publish(
        EventType.stale,
        space: st.id,
        data: {'holder': l.name, 'lastBeat': l.lastBeat},
      );
      _lockChanged(LockChange(st.id, LockChangeKind.stale, _holder(st, l)));
    }
  }

  /// I lock in memoria per spazio, per la prova della porta.
  Iterable<(String, LockState)> lockStates() => [
    for (final s in _spaces.values)
      if (!s.deleted && s.lock != null) (s.id, s.lock!),
  ];

  /// Stato in memoria di uno spazio, senza mutex (DNS); null se non esiste.
  SpaceState? peekSpace(String id) => _spaces[id]?.deleted == false ? _spaces[id] : null;

  // ---------------------------------------------------------------- push

  PushSession _push(Identity who, String pushId) {
    final p = _pushes[pushId];
    if (p == null || p.memberId != who.id) {
      if (_expired.contains(pushId)) {
        throw ApiError(ErrorCode.pushExpired, 'push $pushId expired');
      }
      throw ApiError(ErrorCode.notFound, 'push $pushId: not found');
    }
    if (_isExpired(p)) {
      unawaited(_dropPush(p, expired: true));
      throw ApiError(ErrorCode.pushExpired, 'push $pushId expired');
    }
    return p;
  }

  bool _isExpired(PushSession p) {
    final idle = clock.monoMs() - p.lastActivity;
    return switch (p.status) {
      PushStatus.open => idle > options.pushIdle.inMilliseconds,
      PushStatus.committed => idle > options.committedKeep.inMilliseconds,
    };
  }

  Future<void> _dropPush(PushSession p, {required bool expired}) async {
    if (_pushes.remove(p.id) == null) return;
    if (expired && p.status == PushStatus.open) {
      _expired.add(p.id);
      if (_expired.length > 1000) _expired.remove(_expired.first);
    }
    try {
      await File('$pushesDir/${p.id}.json').delete();
    } on FileSystemException {
      // già assente
    }
  }

  /// Toglie le sessioni scadute (gira ogni minuto).
  Future<void> expirePushes() async {
    for (final p in _pushes.values.where(_isExpired).toList()) {
      await _dropPush(p, expired: true);
    }
  }

  /// Sessioni aperte (test e diagnostica).
  int get openPushes => _pushes.values.where((p) => p.status == PushStatus.open).length;

  /// Inizia un push. Controlli in ordine: lo spazio esiste, percorsi validi
  /// (già fatti dal decoder del manifest, e i file danneggiati devono essere
  /// nel manifest), il token è del lock, parent e parentDigest sono la testa,
  /// guardia della cancellazione di massa, spazio su disco.
  Future<PushStarted> begin(
    Identity who, {
    required bool admin,
    required String id,
    required PushBegin b,
  }) {
    final st = _space(id);
    if (b.kind == GenerationKind.restore) {
      throw const ApiError(
        ErrorCode.badRequest,
        'kind restore is reserved to the restore endpoint',
      );
    }
    for (final d in b.damaged) {
      if (b.manifest[d.path] == null) {
        throw ApiError(
          ErrorCode.badPath,
          'damaged file "${d.path}" is not in the manifest',
          details: {'path': d.path, 'reason': 'notInManifest'},
        );
      }
    }
    if (b.confirmMassDelete && !admin) {
      throw const ApiError(ErrorCode.forbidden, 'only an admin can confirm a mass delete');
    }
    return st.mutex.run(() async {
      _space(id);
      final l = st.lock;
      if (l == null || l.token != b.lockToken) {
        if (l != null && !l.isStale(clock, options.lockTtl)) throw _lockedBy(st, l);
        throw ApiError(ErrorCode.locked, 'space $id: pushing needs the lock');
      }
      if (b.parent != st.headN || b.parentDigest != st.headDigest) {
        throw ApiError(
          ErrorCode.staleBase,
          'generation ${b.parent} is not the head of $id (head is ${st.headN})',
          details: {'head': st.headN, 'digest': st.headDigest},
        );
      }
      final eff = effectiveSettings(st);
      final total = st.headManifest.length;
      var removed = 0;
      for (final p in st.headManifest.files.keys) {
        if (b.manifest[p] == null) removed++;
      }
      if (total >= eff.massDeleteMinFiles &&
          removed > total * eff.massDeleteRatio &&
          !b.confirmMassDelete) {
        throw ApiError(
          ErrorCode.massDelete,
          'the push removes $removed of $total files',
          details: {'removed': removed, 'total': total},
        );
      }
      checkDisk();
      // al più N sessioni aperte per membro: si chiude la più vecchia
      final mine =
          _pushes.values.where((p) => p.memberId == who.id && p.status == PushStatus.open).toList()
            ..sort((a, c) => a.lastActivity.compareTo(c.lastActivity));
      for (var i = 0; i <= mine.length - options.maxPushesPerMember; i++) {
        await _dropPush(mine[i], expired: true);
      }
      final p = PushSession(
        id: _randomId(16),
        space: id,
        memberId: who.id,
        author: who.name,
        lockToken: b.lockToken,
        parent: b.parent,
        parentDigest: b.parentDigest,
        message: b.message,
        kind: b.kind,
        createdAt: clock.wallMs(),
        lastActivity: clock.monoMs(),
        manifest: b.manifest,
        damaged: b.damaged,
      );
      // prima si registra (la GC la vede), poi si guarda cosa manca
      _pushes[p.id] = p;
      _pin(p.sizes.keys);
      final missing = [
        for (final h in p.sizes.keys)
          if (!blobs.has(h)) h,
      ];
      try {
        await writeJsonAtomic('$pushesDir/${p.id}.json', p.toJson());
      } catch (_) {
        _pushes.remove(p.id);
        rethrow;
      }
      l.name = who.name;
      return PushStarted(pushId: p.id, missing: missing);
    });
  }

  /// Riceve un blob di un push. Vero se è stato scritto, falso se c'era già.
  Future<bool> upload(
    Identity who,
    String pushId,
    String hash,
    Stream<List<int>> body, {
    int contentLength = -1,
  }) async {
    final p = _push(who, pushId);
    final size = p.sizes[hash];
    if (size == null) {
      throw ApiError(ErrorCode.badRequest, 'blob $hash is not part of push $pushId');
    }
    if (p.status == PushStatus.committed) {
      // già nella generazione: niente da fare
      await _drain(body, size);
      return false;
    }
    if (contentLength > size) {
      throw ApiError(
        ErrorCode.tooLarge,
        'blob $hash: $contentLength bytes, the manifest declares $size',
        details: {'size': size},
      );
    }
    checkDisk();
    p.touch(clock);
    if (blobs.has(hash)) {
      await _drain(body, size);
      return false;
    }
    await blobs.uploads.acquire();
    try {
      p.touch(clock);
      if (blobs.has(hash)) {
        await _drain(body, size);
        return false;
      }
      await blobs.put(
        hash,
        size,
        body.map((c) {
          p.touch(clock);
          return c;
        }),
      );
    } finally {
      blobs.uploads.release();
    }
    p.touch(clock);
    return true;
  }

  Future<void> _drain(Stream<List<int>> body, int max) async {
    var n = 0;
    await for (final c in body) {
      n += c.length;
      if (n > max) {
        throw ApiError(ErrorCode.tooLarge, 'body larger than the declared $max bytes');
      }
    }
  }

  /// Commit atomico; idempotente: lo stesso push restituisce la stessa
  /// generazione (con `replay` vero) senza crearne un'altra.
  Future<(GenerationSummary, bool)> commit(Identity who, String pushId) {
    final p = _push(who, pushId);
    final st = _spaces[p.space];
    if (st == null || st.deleted) {
      throw ApiError(ErrorCode.spaceGone, 'space ${p.space} was deleted');
    }
    return st.mutex.run(() async {
      if (st.deleted) throw ApiError(ErrorCode.spaceGone, 'space ${p.space} was deleted');
      p.touch(clock);
      if (p.status == PushStatus.committed) return (p.result!, true);
      if (st.headPushId == p.id && st.headSummary != null) {
        // la testa è già questo push: risposta persa dopo un crash
        await _markCommitted(p, st.headSummary!);
        return (st.headSummary!, true);
      }
      final l = st.lock;
      if (l == null || l.token != p.lockToken) {
        throw const ApiError(ErrorCode.lockLost, 'the lock was lost before the commit');
      }
      if (p.parent != st.headN || p.parentDigest != st.headDigest) {
        throw ApiError(
          ErrorCode.staleBase,
          'generation ${p.parent} is no longer the head of ${st.id} (head is ${st.headN})',
          details: {'head': st.headN, 'digest': st.headDigest},
        );
      }
      final m = p.manifest!;
      _pin(p.sizes.keys);
      final missing = [
        for (final h in p.sizes.keys)
          if (!blobs.has(h)) h,
      ];
      if (missing.isNotEmpty) {
        throw ApiError(
          ErrorCode.pushIncomplete,
          '${missing.length} blobs are still missing',
          details: {'missing': missing.take(1000).toList()},
        );
      }
      final s = await _commitGeneration(
        st,
        who: who,
        manifest: m,
        message: p.message,
        kind: p.kind,
        damaged: p.damaged,
        pushId: p.id,
      );
      await _markCommitted(p, s);
      l.name = who.name;
      events.publish(
        EventType.push,
        space: st.id,
        actor: who.name,
        data: {'n': s.n, 'kind': s.kind.name, 'stats': s.stats.toJson()},
      );
      scheduleMaintenance();
      return (s, false);
    });
  }

  Future<void> _markCommitted(PushSession p, GenerationSummary s) async {
    p
      ..status = PushStatus.committed
      ..result = s
      ..manifest = null;
    await writeJsonAtomic('$pushesDir/${p.id}.json', p.toJson());
  }

  Future<void> abort(Identity who, String pushId) async {
    final p = _push(who, pushId);
    if (p.status == PushStatus.committed) return;
    await _dropPush(p, expired: false);
  }

  // ---------------------------------------------------------------- manutenzione

  /// Programma retention + GC dopo [StoreOptions.maintenanceDelay].
  void scheduleMaintenance() {
    _maintTimer?.cancel();
    _maintTimer = Timer(options.maintenanceDelay, () {
      _maintTimer = null;
      final f = maintenance();
      _maintRunning = f;
      f.whenComplete(() => _maintRunning = null).ignore();
    });
  }

  /// Generazioni da conservare (retention): la testa, le ultime keepLast,
  /// tutte quelle più giovani di keepHours e la più recente di ciascuno
  /// degli ultimi keepDays giorni di calendario (ora locale).
  static Set<int> retained(
    Map<int, int> tsByN, {
    required int head,
    required Settings s,
    required DateTime now,
  }) {
    final ns = tsByN.keys.toList()..sort();
    final keep = <int>{head, ...ns.where((n) => n > head)};
    keep.addAll(ns.skip(max(0, ns.length - s.keepLast)));
    final young = now.millisecondsSinceEpoch - s.keepHours * 3600 * 1000;
    final day0 = DateTime(now.year, now.month, now.day);
    final daily = <int, int>{};
    for (final n in ns) {
      final ts = tsByN[n]!;
      if (ts > young) keep.add(n);
      final t = DateTime.fromMillisecondsSinceEpoch(ts);
      final d = DateTime(t.year, t.month, t.day);
      // giorni di calendario indietro da oggi (DST: arrotondato)
      final back = (day0.difference(d).inHours / 24).round();
      if (back >= 0 && back < s.keepDays) {
        final prev = daily[back];
        if (prev == null || tsByN[prev]! <= ts) daily[back] = n;
      }
    }
    keep.addAll(daily.values);
    return keep;
  }

  /// Regole di retention di [st] secondo le impostazioni [s] (già con le
  /// sovrascritture dello spazio).
  Set<int> _retainedBy(SpaceState st, List<int> ns, Settings s) {
    final ts = {for (final n in ns) n: st.summaries[n]?.ts ?? clock.wallMs()};
    return retained(ts, head: st.headN, s: s, now: clock.now());
  }

  Set<int> _retention(SpaceState st, List<int> ns) => _retainedBy(st, ns, effectiveSettings(st));

  /// Pulizia manuale: la testa e le ultime [keep].
  Set<int> Function(SpaceState, List<int>) _keepNewest(int keep) =>
      (st, ns) => {
        st.headN,
        ...ns.where((n) => n > st.headN),
        ...ns.skip(max(0, ns.length - keep)),
      };

  /// Calcola che cosa resterebbe: legge ogni generazione di ogni spazio (una
  /// illeggibile ferma tutto, B-GC-05). Le generazioni da cui parte un push
  /// aperto restano sempre; i blob dei push aperti e degli export contano
  /// come usati. [only] limita le cancellazioni a quegli spazi.
  Future<_GcPlan> _plan(_KeepFn keepFor, {Set<SpaceState>? only}) async {
    final plan = _GcPlan();
    for (final st in _spaces.values.toList()) {
      final ns = await _genNumbers(st);
      final inUse = {
        for (final p in _pushes.values)
          if (p.space == st.id && p.status == PushStatus.open) p.parent,
      };
      final keep = only == null || only.contains(st) ? {...keepFor(st, ns), ...inUse} : ns.toSet();
      final del = <int>[];
      for (final n in ns) {
        final StoredGeneration g;
        try {
          g = await _gen(st, n);
        } catch (e) {
          if (st.deleted) break;
          final msg = 'space ${st.id}: generation $n unreadable ($e)';
          _log('hub: GC sospesa: $msg');
          events.publish(EventType.gcError, space: st.id, data: {'generation': n});
          return plan..error = msg;
        }
        if (keep.contains(n) || n >= st.headN) {
          plan.referenced.addAll(g.gen.manifest.blobs);
        } else {
          del.add(n);
          final d = plan.doomed.putIfAbsent(st, () => {});
          for (final e in g.gen.manifest.files.values) {
            final chunks = e.chunks;
            if (chunks == null) {
              d[e.h] = e.size;
            } else {
              for (final c in chunks) {
                d[c.h] = c.size;
              }
            }
          }
        }
      }
      if (!st.deleted) plan.rows[st] = (ns: ns, del: del);
    }
    for (final p in _pushes.values) {
      if (p.status == PushStatus.open) plan.referenced.addAll(p.sizes.keys);
    }
    for (final l in _leases) {
      plan.referenced.addAll(l);
    }
    return plan;
  }

  /// Cancella le generazioni del piano e poi i blob che niente usa più:
  /// tutti quelli su disco ([sweepAll]) o solo quelli delle generazioni
  /// cancellate.
  Future<MaintenanceReport> _apply(_GcPlan plan, {required bool sweepAll}) async {
    final report = MaintenanceReport();
    for (final e in plan.rows.entries) {
      if (e.value.del.isEmpty) continue;
      final st = e.key;
      await st.mutex.run(() async {
        if (st.deleted) return;
        for (final n in e.value.del) {
          if (n >= st.headN) continue;
          await File(st.genPath(n)).delete();
          st.summaries.remove(n);
          report.generationsDeleted++;
        }
        await fsyncDir(st.generationsDir);
      });
    }
    final candidates = sweepAll
        ? await blobs.list()
        : {for (final d in plan.doomed.values) ...d.keys};
    for (final l in _leases) {
      plan.referenced.addAll(l);
    }
    var i = 0;
    for (final h in candidates) {
      if (plan.referenced.contains(h)) continue;
      // controllo e cancellazione nello stesso turno dell'event loop: un
      // begin non può infilarsi tra i due
      if (_pinned.contains(h) || _leased(h)) continue;
      final f = File(blobs.pathOf(h));
      final int len;
      try {
        len = f.lengthSync();
      } on FileSystemException {
        continue;
      }
      if (blobs.deleteSync(h)) {
        report
          ..blobsDeleted += 1
          ..bytesFreed += len;
      }
      if (++i % 200 == 0) await Future<void>.delayed(Duration.zero);
    }
    return report;
  }

  /// Esegue [body] come GC: appunta i blob usati nel frattempo.
  Future<T> _asGc<T>(Future<T> Function() body) => _maint.run(() async {
    _gcRunning = true;
    _pinned.clear();
    try {
      return await body();
    } finally {
      _gcRunning = false;
      _pinned.clear();
    }
  });

  /// Retention di tutti gli spazi e poi GC dei blob non referenziati. Se una
  /// generazione qualsiasi è illeggibile non cancella niente.
  Future<MaintenanceReport> maintenance() async {
    final report = await _asGc(() async {
      final plan = await _plan(_retention);
      if (plan.error != null) return MaintenanceReport(error: plan.error);
      final r = await _apply(plan, sweepAll: true);
      if (r.generationsDeleted > 0 || r.blobsDeleted > 0) {
        events.publish(
          EventType.gc,
          data: {
            'generations': r.generationsDeleted,
            'blobs': r.blobsDeleted,
            'bytes': r.bytesFreed,
          },
        );
      }
      return r;
    });
    _refreshUsageSoon();
    return report;
  }

  _KeepFn _keepFor({int? keep, Map<String, Object>? history, SpaceState? target}) {
    if (keep != null) return _keepNewest(keep);
    if (history == null) return _retention;
    return (st, ns) {
      // regole in bozza: sulle sovrascritture dello spazio indicato, o al
      // posto di quelle globali per chi non ha regole proprie
      if (target != null) {
        final ov = Map.of(st.meta.overrides);
        final own = st.meta.overrides['history'];
        ov['history'] = {if (own is Map<String, Object?>) ...own, ...history};
        return _retainedBy(st, ns, settings.withOverrides(ov));
      }
      // chi ha regole di storia proprie tiene quelle attuali per intero
      if (st.meta.overrides['history'] is Map) return _retention(st, ns);
      return _retainedBy(
        st,
        ns,
        settings.withValues('history', history).withOverrides(st.meta.overrides),
      );
    };
  }

  /// Anteprima di una pulizia (niente viene cancellato): [keep] = ultime N,
  /// [history] = regole di retention in bozza, nessuno dei due = le regole
  /// attuali. [spaceId] limita a uno spazio.
  Future<GcPreview> gcPreview({int? keep, Map<String, Object>? history, String? spaceId}) async {
    final target = spaceId == null ? null : _space(spaceId);
    return _maint.run(() async {
      final plan = await _plan(
        _keepFor(keep: keep, history: history, target: target),
        only: target == null ? null : {target},
      );
      if (plan.error != null) throw ApiError(ErrorCode.internal, plan.error!);
      final rows = <GcPreviewRow>[];
      for (final e in plan.rows.entries) {
        final st = e.key;
        if (target != null && st != target) continue;
        rows.add(
          GcPreviewRow(
            id: st.id,
            name: st.meta.name,
            now: e.value.ns.length,
            after: e.value.ns.length - e.value.del.length,
            bytes: plan.bytesOf(st),
            ownRules: keep == null && st.meta.overrides['history'] is Map,
          ),
        );
      }
      rows.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return GcPreview(
        keep: keep,
        spaces: rows,
        now: rows.fold(0, (a, r) => a + r.now),
        after: rows.fold(0, (a, r) => a + r.after),
        bytes: plan.bytes,
      );
    });
  }

  /// Pulizia adesso (admin): [keep] = ultime N di ogni spazio, altrimenti le
  /// regole di retention. Pubblica sempre `gc` con chi l'ha chiesta.
  Future<GcReport> gc(Identity who, {int? keep, String? spaceId}) async {
    final target = spaceId == null ? null : _space(spaceId);
    final r = await _asGc(() async {
      final plan = await _plan(_keepFor(keep: keep), only: target == null ? null : {target});
      if (plan.error != null) throw ApiError(ErrorCode.internal, plan.error!);
      return _apply(plan, sweepAll: true);
    });
    events.publish(
      EventType.gc,
      space: target?.id,
      actor: who.name,
      data: {
        'generations': r.generationsDeleted,
        'blobs': r.blobsDeleted,
        'bytes': r.bytesFreed,
        'keep': ?keep,
      },
    );
    _refreshUsageSoon(force: true);
    return r.toReport();
  }

  void _checkDeletable(SpaceState st, int n) {
    if (n == st.headN) {
      throw ApiError(ErrorCode.isHead, 'generation $n is the head', details: {'generation': n});
    }
    if (n <= 0 || !st.summaries.containsKey(n)) throw _genNotFound(n);
  }

  _KeepFn _allBut(SpaceState target, int n) =>
      (st, ns) => st == target ? (ns.toSet()..remove(n)) : ns.toSet();

  /// Byte che si libererebbero eliminando la generazione [n].
  Future<int> freedBy(String id, int n) async {
    final st = _space(id);
    _checkDeletable(st, n);
    return _maint.run(() async {
      final plan = await _plan(_allBut(st, n), only: {st});
      if (plan.error != null) throw ApiError(ErrorCode.internal, plan.error!);
      return plan.bytesOf(st);
    });
  }

  /// Elimina una generazione che non è la testa (B-GEN-15) e i blob che solo
  /// lei usava. Irreversibile.
  Future<({int deleted, int bytes})> deleteGeneration(Identity who, String id, int n) async {
    final st = _space(id);
    _checkDeletable(st, n);
    final r = await _asGc(() async {
      _checkDeletable(st, n);
      final plan = await _plan(_allBut(st, n), only: {st});
      if (plan.error != null) throw ApiError(ErrorCode.internal, plan.error!);
      if (plan.rows[st]?.del.contains(n) != true) {
        // un push aperto parte da lì: non si tocca
        throw ApiError(
          ErrorCode.locked,
          'generation $n is in use by an open push',
          details: {'generation': n},
        );
      }
      return _apply(plan, sweepAll: false);
    });
    events.publish(
      EventType.generationDelete,
      space: id,
      actor: who.name,
      data: {'n': n, 'bytes': r.bytesFreed},
    );
    _refreshUsageSoon(force: true);
    return (deleted: n, bytes: r.bytesFreed);
  }

  // ---------------------------------------------------------------- uso del disco

  HubUsage _emptyUsage() =>
      HubUsage(disk: diskInfo(), blobs: 0, dl: 0, spaces: const {}, computedAt: 0);

  void _refreshUsageSoon({bool force = false}) {
    if (!force && clock.monoMs() - _usageAt < options.usageEvery.inMilliseconds) return;
    unawaited(_computeUsage().then((_) {}, onError: (Object e) => _log('hub: uso del disco: $e')));
  }

  /// `GET /usage`: l'ultimo calcolo (con il disco aggiornato); se non c'è
  /// ancora lo calcola adesso.
  Future<HubUsage> usage() async {
    final u = _usage ?? await _computeUsage();
    return HubUsage(
      disk: diskInfo(),
      blobs: u.blobs,
      dl: u.dl,
      spaces: u.spaces,
      computedAt: u.computedAt,
    );
  }

  Future<HubUsage> _computeUsage() {
    final running = _usageRunning;
    if (running != null) return running;
    final f = _doComputeUsage();
    _usageRunning = f;
    return f.whenComplete(() => _usageRunning = null);
  }

  Future<HubUsage> _doComputeUsage() async {
    _usageAt = clock.monoMs();
    final sizes = <String, Map<String, int>>{};
    final info = <String, ({int gens, int? oldest, int logical})>{};
    for (final st in _spaces.values.toList()) {
      final mine = <String, int>{};
      var logical = 0;
      for (final n in st.summaries.keys.toList()) {
        if (st.deleted) break;
        try {
          final m = (await _gen(st, n)).gen.manifest;
          logical += m.totalSize;
          for (final e in m.files.values) {
            final chunks = e.chunks;
            if (chunks == null) {
              mine[e.h] = e.size;
            } else {
              for (final c in chunks) {
                mine[c.h] = c.size;
              }
            }
          }
        } catch (_) {
          // illeggibile: la GC lo segnala, qui si salta
        }
        await Future<void>.delayed(Duration.zero);
      }
      if (st.deleted) continue;
      sizes[st.id] = mine;
      info[st.id] = (
        gens: st.summaries.length,
        oldest: st.summaries.isEmpty ? null : st.summaries.firstKey(),
        logical: logical,
      );
    }
    var onDisk = 0;
    var i = 0;
    for (final h in await blobs.list()) {
      try {
        onDisk += File(blobs.pathOf(h)).lengthSync();
      } on FileSystemException {
        // cancellato nel frattempo
      }
      if (++i % 500 == 0) await Future<void>.delayed(Duration.zero);
    }
    final now = clock.wallMs();
    final spaces = <String, SpaceUsage>{};
    for (final e in sizes.entries) {
      var referenced = 0, exclusive = 0;
      for (final b in e.value.entries) {
        referenced += b.value;
        if (!sizes.entries.any((o) => o.key != e.key && o.value.containsKey(b.key))) {
          exclusive += b.value;
        }
      }
      final inf = info[e.key]!;
      spaces[e.key] = SpaceUsage(
        generations: inf.gens,
        oldest: inf.oldest,
        logical: inf.logical,
        referenced: referenced,
        exclusive: exclusive,
        computedAt: now,
      );
    }
    var dl = 0;
    try {
      dl = await extras.dlBytes();
    } catch (_) {
      // /dl non leggibile: 0
    }
    final u = HubUsage(disk: diskInfo(), blobs: onDisk, dl: dl, spaces: spaces, computedAt: now);
    _usage = u;
    return u;
  }
}

/// Nome di uno spazio: 1–64 caratteri, senza caratteri di controllo.
String validateSpaceName(String name) {
  final n = name.trim();
  if (n.isEmpty || n.length > 64) {
    throw const ApiError(
      ErrorCode.badRequest,
      'name: must be 1 to 64 characters',
      details: {'field': 'name'},
    );
  }
  if (n.codeUnits.any((c) => c < 0x20 || c == 0x7f)) {
    throw const ApiError(
      ErrorCode.badRequest,
      'name: control characters are not allowed',
      details: {'field': 'name'},
    );
  }
  return n;
}

/// Esclusioni proprie: al più 500 righe di al più 256 caratteri.
List<String> validateExclusions(List<String> ex) {
  if (ex.length > 500) {
    throw const ApiError(
      ErrorCode.badRequest,
      'exclusions: at most 500',
      details: {'field': 'exclusions'},
    );
  }
  final out = <String>[];
  for (final e in ex) {
    if (e.length > 256 || e.contains('\n') || e.contains('\r') || e.contains('\x00')) {
      throw ApiError(
        ErrorCode.badRequest,
        'exclusions: invalid pattern',
        details: {'field': 'exclusions', 'pattern': e},
      );
    }
    final t = e.trim();
    if (t.isNotEmpty) out.add(t);
  }
  return out;
}
