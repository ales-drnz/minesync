// Area Admin dell'hub: sezioni delle impostazioni (tutte applicate a caldo),
// membri e ruoli, stato di ZTNET, informazioni di sistema, uso del disco e
// pulizia. Le impostazioni di Telegram stanno in telegram.dart perché il
// token non deve mai uscire dall'hub.
import 'exclusions.dart';
import 'json.dart';
import 'models.dart';

/// Sezioni di `GET /settings`, nell'ordine dell'area Admin.
const List<String> settingsSections = [
  'general',
  'members',
  'history',
  'disk',
  'sessions',
  'protection',
  'exclusions',
  'stats',
];

/// Sezioni che uno spazio può sovrascrivere (`PATCH /spaces/{id}` `overrides`).
const List<String> overridableSettingsSections = ['sessions', 'history', 'protection'];

/// Lingua predefinita dei messaggi.
const List<String> hubLanguages = ['auto', 'it', 'en'];

/// Admin › Generale.
final class GeneralSettings {
  const GeneralSettings({this.name = 'MineSync', this.language = 'auto'});

  factory GeneralSettings.fromJson(Object? j) {
    final m = obj(j, 'general');
    return GeneralSettings(name: str(m, 'name'), language: str(m, 'language'));
  }

  /// Nome dell'hub, 1–40 caratteri senza caratteri di controllo.
  final String name;

  /// `auto` (lingua del browser o dell'app), `it`, `en`.
  final String language;

  Map<String, Object?> toJson() => {'name': name, 'language': language};
}

/// Admin › Accesso e membri.
final class MembersSettings {
  const MembersSettings({this.trustHours = 24, this.refreshSeconds = 30});

  factory MembersSettings.fromJson(Object? j) {
    final m = obj(j, 'members');
    return MembersSettings(
      trustHours: integer(m, 'trustHours'),
      refreshSeconds: integer(m, 'refreshSeconds'),
    );
  }

  /// Per quante ore i membri già noti restano riconosciuti con ZTNET
  /// irraggiungibile; 0 = sempre (0–8760).
  final int trustHours;

  /// Ogni quanti secondi si rilegge l'elenco da ZTNET (10–3600).
  final int refreshSeconds;

  Map<String, Object?> toJson() => {'trustHours': trustHours, 'refreshSeconds': refreshSeconds};
}

/// Admin › Storia (retention automatica, B-RET).
final class HistorySettings {
  const HistorySettings({this.keepLast = 30, this.keepHours = 24, this.keepDays = 7});

  factory HistorySettings.fromJson(Object? j) {
    final m = obj(j, 'history');
    return HistorySettings(
      keepLast: integer(m, 'keepLast'),
      keepHours: integer(m, 'keepHours'),
      keepDays: integer(m, 'keepDays'),
    );
  }

  final int keepLast;
  final int keepHours;
  final int keepDays;

  Map<String, Object?> toJson() => {
    'keepLast': keepLast,
    'keepHours': keepHours,
    'keepDays': keepDays,
  };
}

/// Admin › Spazio su disco: la soglia è il più alto dei due valori.
final class DiskSettings {
  const DiskSettings({this.minFreeGiB = 1, this.minFreePercent = 2});

  factory DiskSettings.fromJson(Object? j) {
    final m = obj(j, 'disk');
    return DiskSettings(
      minFreeGiB: integer(m, 'minFreeGiB'),
      minFreePercent: integer(m, 'minFreePercent'),
    );
  }

  /// 0–100000.
  final int minFreeGiB;

  /// 0–50.
  final int minFreePercent;

  /// Soglia in byte per un disco di [total] byte.
  int thresholdFor(int total) {
    final a = minFreeGiB << 30;
    final b = total <= 0 ? 0 : total ~/ 100 * minFreePercent;
    return a > b ? a : b;
  }

  Map<String, Object?> toJson() => {'minFreeGiB': minFreeGiB, 'minFreePercent': minFreePercent};
}

/// Admin › Sessioni di gioco (default per tutti i server; sovrascrivibile).
final class SessionSettings {
  const SessionSettings({
    this.autosaveMinutes = 5,
    this.autostop = true,
    this.autostopMinutes = 30,
    this.crashRestarts = 2,
    this.portTest = true,
  });

  factory SessionSettings.fromJson(Object? j) {
    final m = obj(j, 'sessions');
    return SessionSettings(
      autosaveMinutes: integer(m, 'autosaveMinutes'),
      autostop: boolean(m, 'autostop'),
      autostopMinutes: integer(m, 'autostopMinutes'),
      crashRestarts: integer(m, 'crashRestarts'),
      portTest: boolean(m, 'portTest'),
    );
  }

  /// 1–1440.
  final int autosaveMinutes;
  final bool autostop;

  /// Minuti senza giocatori prima dello spegnimento, 1–1440.
  final int autostopMinutes;

  /// 0–10.
  final int crashRestarts;

  /// L'hub prova la porta di gioco di chi ospita.
  final bool portTest;

  Map<String, Object?> toJson() => {
    'autosaveMinutes': autosaveMinutes,
    'autostop': autostop,
    'autostopMinutes': autostopMinutes,
    'crashRestarts': crashRestarts,
    'portTest': portTest,
  };
}

/// Admin › Protezioni (B-GUARD): la stessa soglia vale per l'hub e per la
/// conferma nel client.
final class ProtectionSettings {
  const ProtectionSettings({this.massDeleteRatio = 0.5, this.massDeleteMinFiles = 20});

  factory ProtectionSettings.fromJson(Object? j) {
    final m = obj(j, 'protection');
    return ProtectionSettings(
      massDeleteRatio: number(m, 'massDeleteRatio'),
      massDeleteMinFiles: integer(m, 'massDeleteMinFiles'),
    );
  }

  /// Quota di file tolti oltre la quale il push è rifiutato, in (0, 1].
  final double massDeleteRatio;
  final int massDeleteMinFiles;

  Map<String, Object?> toJson() => {
    'massDeleteRatio': massDeleteRatio,
    'massDeleteMinFiles': massDeleteMinFiles,
  };
}

/// Admin › Esclusioni predefinite per profilo. Gli spazi le ereditano dal
/// vivo; i pattern di sistema ([systemExclusions]) non ne fanno parte.
final class ExclusionSettings {
  const ExclusionSettings({required this.minecraft, required this.generic});

  factory ExclusionSettings.fromJson(Object? j) {
    final m = obj(j, 'exclusions');
    return ExclusionSettings(minecraft: strings(m, 'minecraft'), generic: strings(m, 'generic'));
  }

  /// I valori di fabbrica.
  static const ExclusionSettings defaults = ExclusionSettings(
    minecraft: minecraftExclusions,
    generic: genericExclusions,
  );

  final List<String> minecraft;
  final List<String> generic;

  List<String> of(Profile p) => switch (p) {
    Profile.minecraft => minecraft,
    Profile.generic => generic,
  };

  Map<String, Object?> toJson() => {'minecraft': minecraft, 'generic': generic};
}

/// Admin › Statistiche.
final class StatsSettings {
  const StatsSettings({this.sessionsKept = 40});

  factory StatsSettings.fromJson(Object? j) {
    final m = obj(j, 'stats');
    return StatsSettings(sessionsKept: integer(m, 'sessionsKept'));
  }

  /// Sessioni conservate per server, 1–1000.
  final int sessionsKept;

  Map<String, Object?> toJson() => {'sessionsKept': sessionsKept};
}

/// Tutte le sezioni.
final class SettingsSections {
  const SettingsSections({
    this.general = const GeneralSettings(),
    this.members = const MembersSettings(),
    this.history = const HistorySettings(),
    this.disk = const DiskSettings(),
    this.sessions = const SessionSettings(),
    this.protection = const ProtectionSettings(),
    this.exclusions = ExclusionSettings.defaults,
    this.stats = const StatsSettings(),
  });

  factory SettingsSections.fromJson(Object? j) {
    final m = obj(j, 'sections');
    return SettingsSections(
      general: GeneralSettings.fromJson(m['general']),
      members: MembersSettings.fromJson(m['members']),
      history: HistorySettings.fromJson(m['history']),
      disk: DiskSettings.fromJson(m['disk']),
      sessions: SessionSettings.fromJson(m['sessions']),
      protection: ProtectionSettings.fromJson(m['protection']),
      exclusions: ExclusionSettings.fromJson(m['exclusions']),
      stats: StatsSettings.fromJson(m['stats']),
    );
  }

  final GeneralSettings general;
  final MembersSettings members;
  final HistorySettings history;
  final DiskSettings disk;
  final SessionSettings sessions;
  final ProtectionSettings protection;
  final ExclusionSettings exclusions;
  final StatsSettings stats;

  Map<String, Object?> toJson() => {
    'general': general.toJson(),
    'members': members.toJson(),
    'history': history.toJson(),
    'disk': disk.toJson(),
    'sessions': sessions.toJson(),
    'protection': protection.toJson(),
    'exclusions': exclusions.toJson(),
    'stats': stats.toJson(),
  };
}

/// Chi ha cambiato per ultimo le impostazioni («Ultima modifica»).
final class SettingsChange {
  const SettingsChange({
    required this.by,
    required this.byId,
    required this.at,
    required this.section,
  });

  factory SettingsChange.fromJson(Object? j) {
    final m = obj(j, 'changed');
    return SettingsChange(
      by: str(m, 'by'),
      byId: str(m, 'byId'),
      at: integer(m, 'at'),
      section: str(m, 'section'),
    );
  }

  final String by;
  final String byId;
  final int at;

  /// Sezione cambiata (`telegram` compresa).
  final String section;

  Map<String, Object?> toJson() => {'by': by, 'byId': byId, 'at': at, 'section': section};
}

/// `GET /settings` e risposta di `PATCH /settings/{section}`.
final class HubSettings {
  const HubSettings({
    required this.sections,
    this.defaults = const SettingsSections(),
    this.changed,
  });

  factory HubSettings.fromJson(Object? j) {
    final m = obj(j, 'settings');
    return HubSettings(
      sections: SettingsSections.fromJson(m['sections']),
      defaults: SettingsSections.fromJson(m['defaults']),
      changed: m['changed'] == null ? null : SettingsChange.fromJson(m['changed']),
    );
  }

  /// Valori in uso.
  final SettingsSections sections;

  /// Valori di fabbrica («Predefinito: …», «Ripristina»).
  final SettingsSections defaults;
  final SettingsChange? changed;

  Map<String, Object?> toJson() => {
    'sections': sections.toJson(),
    'defaults': defaults.toJson(),
    if (changed != null) 'changed': changed!.toJson(),
  };
}

/// Valori delle sezioni sovrascrivibili per uno spazio (effettivi o
/// ereditati, vedi [SpaceDetails]).
final class SpaceSettings {
  const SpaceSettings({
    this.sessions = const SessionSettings(),
    this.history = const HistorySettings(),
    this.protection = const ProtectionSettings(),
  });

  factory SpaceSettings.fromJson(Object? j) {
    final m = obj(j, 'settings');
    // una sezione assente vale i default di fabbrica (hub che non la
    // conosce ancora); i campi di una sezione presente restano obbligatori
    return SpaceSettings(
      sessions: m['sessions'] == null
          ? const SessionSettings()
          : SessionSettings.fromJson(m['sessions']),
      history: m['history'] == null
          ? const HistorySettings()
          : HistorySettings.fromJson(m['history']),
      protection: m['protection'] == null
          ? const ProtectionSettings()
          : ProtectionSettings.fromJson(m['protection']),
    );
  }

  final SessionSettings sessions;
  final HistorySettings history;
  final ProtectionSettings protection;

  Map<String, Object?> toJson() => {
    'sessions': sessions.toJson(),
    'history': history.toJson(),
    'protection': protection.toJson(),
  };
}

// ---------------------------------------------------------------- membri

enum MemberRole {
  member,
  admin;

  static MemberRole parse(Object? v) => enumOf(values, v, 'ruolo');
}

/// Un membro visto dall'hub o elencato da ZTNET.
final class MemberInfo {
  const MemberInfo({
    required this.id,
    required this.name,
    required this.role,
    this.ip,
    this.lastSeen,
    this.fromConfig = false,
    this.authorized = true,
  });

  factory MemberInfo.fromJson(Object? j) {
    final m = obj(j, 'member');
    return MemberInfo(
      id: str(m, 'id'),
      name: str(m, 'name'),
      role: MemberRole.parse(m['role']),
      ip: optStr(m, 'ip'),
      lastSeen: optInt(m, 'lastSeen'),
      fromConfig: optBool(m, 'fromConfig') ?? false,
      authorized: optBool(m, 'authorized') ?? true,
    );
  }

  /// Node id ZeroTier.
  final String id;

  /// Nome in ZTNET; vuoto se non ne ha.
  final String name;
  final MemberRole role;

  /// Primo indirizzo assegnato sulla rete privata.
  final String? ip;

  /// Ultima richiesta all'hub; null = mai.
  final int? lastSeen;

  /// Admin da MINESYNC_ADMINS: non si può declassare dalla UI.
  final bool fromConfig;

  /// Autorizzato in ZTNET; un membro non autorizzato non entra.
  final bool authorized;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'role': role.name,
    if (ip != null) 'ip': ip,
    if (lastSeen != null) 'lastSeen': lastSeen,
    'fromConfig': fromConfig,
    'authorized': authorized,
  };
}

enum ZtnetState {
  ok,
  error,

  /// ZTNET non configurato (solo MINESYNC_DEV_USER o nessuno).
  off;

  static ZtnetState parse(Object? v) => enumOf(values, v, 'stato di ZTNET');
}

/// Stato della connessione a ZTNET. URL in chiaro, token e rete solo con le
/// ultime 4 cifre.
final class ZtnetStatus {
  const ZtnetStatus({
    required this.state,
    this.members = 0,
    this.lastRefresh,
    this.lastError,
    this.lastErrorAt,
    this.url,
    this.tokenHint,
    this.networkHint,
  });

  factory ZtnetStatus.fromJson(Object? j) {
    final m = obj(j, 'ztnet');
    return ZtnetStatus(
      state: ZtnetState.parse(m['state']),
      members: optInt(m, 'members') ?? 0,
      lastRefresh: optInt(m, 'lastRefresh'),
      lastError: optStr(m, 'lastError'),
      lastErrorAt: optInt(m, 'lastErrorAt'),
      url: optStr(m, 'url'),
      tokenHint: optStr(m, 'tokenHint'),
      networkHint: optStr(m, 'networkHint'),
    );
  }

  final ZtnetState state;

  /// Membri autorizzati nell'ultimo elenco.
  final int members;

  /// Ultimo aggiornamento riuscito.
  final int? lastRefresh;

  /// Ultimo errore (anche se poi è rientrato) e quando.
  final String? lastError;
  final int? lastErrorAt;
  final String? url;
  final String? tokenHint;
  final String? networkHint;

  Map<String, Object?> toJson() => {
    'state': state.name,
    'members': members,
    if (lastRefresh != null) 'lastRefresh': lastRefresh,
    if (lastError != null) 'lastError': lastError,
    if (lastErrorAt != null) 'lastErrorAt': lastErrorAt,
    if (url != null) 'url': url,
    if (tokenHint != null) 'tokenHint': tokenHint,
    if (networkHint != null) 'networkHint': networkHint,
  };
}

/// `GET /members`.
final class MemberList {
  const MemberList({required this.members, required this.ztnet});

  factory MemberList.fromJson(Object? j) {
    final m = obj(j, 'members');
    return MemberList(
      members: listOf(m, 'members', MemberInfo.fromJson),
      ztnet: ZtnetStatus.fromJson(m['ztnet']),
    );
  }

  final List<MemberInfo> members;
  final ZtnetStatus ztnet;

  Map<String, Object?> toJson() => {
    'members': [for (final x in members) x.toJson()],
    'ztnet': ztnet.toJson(),
  };
}

// ---------------------------------------------------------------- sistema

/// DNS integrato (MINESYNC_DNS_ZONE, MINESYNC_DNS_ADDR).
final class DnsStatus {
  const DnsStatus({required this.on, this.zone, this.addr, this.error});

  factory DnsStatus.fromJson(Object? j) {
    final m = obj(j, 'dns');
    return DnsStatus(
      on: boolean(m, 'on'),
      zone: optStr(m, 'zone'),
      addr: optStr(m, 'addr'),
      error: optStr(m, 'error'),
    );
  }

  /// Il server DNS risponde.
  final bool on;
  final String? zone;
  final String? addr;

  /// Perché non è partito (es. porta occupata).
  final String? error;

  Map<String, Object?> toJson() => {
    'on': on,
    if (zone != null) 'zone': zone,
    if (addr != null) 'addr': addr,
    if (error != null) 'error': error,
  };
}

/// Una piattaforma con l'aggiornamento automatico pubblicato su /dl.
final class UpdateChannel {
  const UpdateChannel({required this.platform, required this.version, required this.signed});

  factory UpdateChannel.fromJson(Object? j) {
    final m = obj(j, 'update');
    return UpdateChannel(
      platform: str(m, 'platform'),
      version: str(m, 'version'),
      signed: boolean(m, 'signed'),
    );
  }

  /// Es. `linux-x64`, `windows-x64`, `macos-arm64`.
  final String platform;
  final String version;

  /// C'è `manifest.json.sig` accanto al manifest.
  final bool signed;

  Map<String, Object?> toJson() => {'platform': platform, 'version': version, 'signed': signed};
}

/// `GET /system` (admin): valori di sola lettura, quasi tutti dalle
/// variabili d'ambiente («impostato all'avvio»).
final class SystemInfo {
  const SystemInfo({
    required this.version,
    required this.startedAt,
    required this.time,
    required this.disk,
    required this.http,
    required this.dns,
    required this.dataDir,
    this.build,
    this.allowedHosts = const [],
    this.admins = const [],
    this.minFreeEnv,
    this.dlDir,
    this.updates = const [],
    this.timeZone,
    this.webDir,
    this.webBuild,
  });

  factory SystemInfo.fromJson(Object? j) {
    final m = obj(j, 'system');
    return SystemInfo(
      version: str(m, 'version'),
      build: optStr(m, 'build'),
      startedAt: integer(m, 'startedAt'),
      time: integer(m, 'time'),
      disk: DiskInfo.fromJson(m['disk']),
      http: str(m, 'http'),
      dns: DnsStatus.fromJson(m['dns']),
      dataDir: str(m, 'dataDir'),
      allowedHosts: strings(m, 'allowedHosts'),
      admins: strings(m, 'admins'),
      minFreeEnv: optInt(m, 'minFreeEnv'),
      dlDir: optStr(m, 'dlDir'),
      updates: optListOf(m, 'updates', UpdateChannel.fromJson),
      timeZone: optStr(m, 'timeZone'),
      webDir: optStr(m, 'webDir'),
      webBuild: optStr(m, 'webBuild'),
    );
  }

  final String version;

  /// Data della build, se nota.
  final String? build;
  final int startedAt;

  /// Ora dell'hub: uptime = time − startedAt.
  final int time;
  final DiskInfo disk;

  /// MINESYNC_ADDR come configurato (es. `:8084`).
  final String http;
  final DnsStatus dns;
  final String dataDir;

  /// MINESYNC_HOSTS (oltre a IP letterali, localhost e la zona DNS).
  final List<String> allowedHosts;

  /// MINESYNC_ADMINS.
  final List<String> admins;

  /// MINESYNC_MIN_FREE in byte: se c'è vince su Admin › Disco.
  final int? minFreeEnv;

  /// MINESYNC_DL; null = niente download.
  final String? dlDir;
  final List<UpdateChannel> updates;

  /// TZ.
  final String? timeZone;

  /// MINESYNC_WEB e id della build servita.
  final String? webDir;
  final String? webBuild;

  Map<String, Object?> toJson() => {
    'version': version,
    if (build != null) 'build': build,
    'startedAt': startedAt,
    'time': time,
    'disk': disk.toJson(),
    'http': http,
    'dns': dns.toJson(),
    'dataDir': dataDir,
    'allowedHosts': allowedHosts,
    'admins': admins,
    if (minFreeEnv != null) 'minFreeEnv': minFreeEnv,
    if (dlDir != null) 'dlDir': dlDir,
    if (updates.isNotEmpty) 'updates': [for (final u in updates) u.toJson()],
    if (timeZone != null) 'timeZone': timeZone,
    if (webDir != null) 'webDir': webDir,
    if (webBuild != null) 'webBuild': webBuild,
  };
}

// ---------------------------------------------------------------- disco e pulizia

/// Spazio occupato da uno spazio, in byte.
final class SpaceUsage {
  const SpaceUsage({
    required this.generations,
    required this.logical,
    required this.referenced,
    required this.exclusive,
    required this.computedAt,
    this.oldest,
  });

  factory SpaceUsage.fromJson(Object? j) {
    final m = obj(j, 'usage');
    return SpaceUsage(
      generations: integer(m, 'generations'),
      oldest: optInt(m, 'oldest'),
      logical: integer(m, 'logical'),
      referenced: integer(m, 'referenced'),
      exclusive: integer(m, 'exclusive'),
      computedAt: integer(m, 'computedAt'),
    );
  }

  /// Generazioni conservate e la più vecchia.
  final int generations;
  final int? oldest;

  /// Somma delle dimensioni delle generazioni come se non ci fosse
  /// deduplicazione.
  final int logical;

  /// Blob distinti usati da almeno una generazione dello spazio.
  final int referenced;

  /// La parte di [referenced] che nessun altro spazio usa: quanto si libera
  /// eliminando lo spazio.
  final int exclusive;
  final int computedAt;

  Map<String, Object?> toJson() => {
    'generations': generations,
    if (oldest != null) 'oldest': oldest,
    'logical': logical,
    'referenced': referenced,
    'exclusive': exclusive,
    'computedAt': computedAt,
  };
}

/// `GET /usage`.
final class HubUsage {
  const HubUsage({
    required this.disk,
    required this.blobs,
    required this.dl,
    required this.spaces,
    required this.computedAt,
  });

  factory HubUsage.fromJson(Object? j) {
    final m = obj(j, 'usage');
    final sp = obj(m['spaces'], 'spaces');
    return HubUsage(
      disk: DiskInfo.fromJson(m['disk']),
      blobs: integer(m, 'blobs'),
      dl: integer(m, 'dl'),
      spaces: {for (final e in sp.entries) e.key: SpaceUsage.fromJson(e.value)},
      computedAt: integer(m, 'computedAt'),
    );
  }

  final DiskInfo disk;

  /// Byte in blobs/ (tutto ciò che l'hub occupa per i mondi).
  final int blobs;

  /// Byte in MINESYNC_DL.
  final int dl;

  /// Per id di spazio.
  final Map<String, SpaceUsage> spaces;
  final int computedAt;

  Map<String, Object?> toJson() => {
    'disk': disk.toJson(),
    'blobs': blobs,
    'dl': dl,
    'spaces': {for (final e in spaces.entries) e.key: e.value.toJson()},
    'computedAt': computedAt,
  };
}

/// Una riga dell'anteprima di pulizia.
final class GcPreviewRow {
  const GcPreviewRow({
    required this.id,
    required this.name,
    required this.now,
    required this.after,
    required this.bytes,
    this.ownRules = false,
  });

  factory GcPreviewRow.fromJson(Object? j) {
    final m = obj(j, 'row');
    return GcPreviewRow(
      id: str(m, 'id'),
      name: str(m, 'name'),
      now: integer(m, 'now'),
      after: integer(m, 'after'),
      bytes: integer(m, 'bytes'),
      ownRules: optBool(m, 'ownRules') ?? false,
    );
  }

  final String id;
  final String name;

  /// Generazioni ora e dopo la pulizia.
  final int now;
  final int after;

  /// Byte che si libererebbero (blob che nessuna generazione superstite, di
  /// nessuno spazio, usa più).
  final int bytes;

  /// Lo spazio ha regole di storia proprie: l'anteprima globale le usa.
  final bool ownRules;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'now': now,
    'after': after,
    'bytes': bytes,
    if (ownRules) 'ownRules': true,
  };
}

/// Risposta di `POST /gc/preview` e `POST /spaces/{id}/gc/preview`.
final class GcPreview {
  const GcPreview({
    required this.spaces,
    required this.now,
    required this.after,
    required this.bytes,
    this.keep,
  });

  factory GcPreview.fromJson(Object? j) {
    final m = obj(j, 'preview');
    return GcPreview(
      keep: optInt(m, 'keep'),
      spaces: listOf(m, 'spaces', GcPreviewRow.fromJson),
      now: integer(m, 'now'),
      after: integer(m, 'after'),
      bytes: integer(m, 'bytes'),
    );
  }

  /// Pulizia manuale «mantieni le ultime N»; null = regole di retention.
  final int? keep;
  final List<GcPreviewRow> spaces;
  final int now;
  final int after;
  final int bytes;

  Map<String, Object?> toJson() => {
    if (keep != null) 'keep': keep,
    'spaces': [for (final r in spaces) r.toJson()],
    'now': now,
    'after': after,
    'bytes': bytes,
  };
}

/// Risultato di una pulizia (`POST /gc`, `POST /spaces/{id}/gc`).
final class GcReport {
  const GcReport({required this.generations, required this.blobs, required this.bytes});

  factory GcReport.fromJson(Object? j) {
    final m = obj(j, 'gc');
    return GcReport(
      generations: integer(m, 'generations'),
      blobs: integer(m, 'blobs'),
      bytes: integer(m, 'bytes'),
    );
  }

  final int generations;
  final int blobs;
  final int bytes;

  Map<String, Object?> toJson() => {'generations': generations, 'blobs': blobs, 'bytes': bytes};
}

/// Da dove viene il pattern che esclude un percorso.
enum ExclusionSource {
  system,
  profile,
  space,

  /// Dalla lista non ancora salvata mandata con la richiesta.
  draft;

  static ExclusionSource parse(Object? v) => enumOf(values, v, 'origine del pattern');
}

/// Risposta di `POST /exclusions/test`.
final class ExclusionTest {
  const ExclusionTest({required this.path, required this.excluded, this.pattern, this.source});

  factory ExclusionTest.fromJson(Object? j) {
    final m = obj(j, 'test');
    return ExclusionTest(
      path: str(m, 'path'),
      excluded: boolean(m, 'excluded'),
      pattern: optStr(m, 'pattern'),
      source: m['source'] == null ? null : ExclusionSource.parse(m['source']),
    );
  }

  final String path;
  final bool excluded;

  /// Il primo pattern che lo esclude (come scritto), se escluso.
  final String? pattern;
  final ExclusionSource? source;

  Map<String, Object?> toJson() => {
    'path': path,
    'excluded': excluded,
    if (pattern != null) 'pattern': pattern,
    if (source != null) 'source': source!.name,
  };
}
