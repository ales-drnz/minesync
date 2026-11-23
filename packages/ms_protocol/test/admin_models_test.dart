// Modelli di hub web, Admin ed extra: andata e ritorno in JSON e
// decodifica stretta.
import 'dart:convert';

import 'package:ms_protocol/ms_protocol.dart';
import 'package:test/test.dart';

String h(int i) => i.toRadixString(16).padLeft(64, '0');

/// toJson → testo JSON → fromJson → toJson: deve tornare identico.
void roundTrip<T>(Map<String, Object?> Function(T) enc, T Function(Object?) dec, T v) {
  final a = enc(v);
  final b = enc(dec(jsonDecode(jsonEncode(a))));
  expect(b, a);
}

const lock = LockHolder(
  memberId: 'n-alice',
  name: 'alice',
  since: 1000,
  lastBeat: 2000,
  stale: false,
  info: LockInfo(client: '0.1.0', action: 'play', players: ['alice', 'bob'], port: 25565),
  ip: '192.0.2.31',
  portCheck: PortCheck(state: PortState.reachable, port: 25565, checkedAt: 2100),
);

const session = SessionRecord(
  memberId: 'n-bob',
  name: 'bob',
  start: 10,
  end: 7200010,
  ended: SessionEnd.released,
  players: {'bob': 7200000, 'carol': 3600000},
);

void main() {
  group('modelli esistenti con i campi nuovi', () {
    test('HubInfo con lingua e zona DNS; senza, i default', () {
      const me = Me(id: 'n-alice', name: 'alice', admin: true);
      const disk = DiskInfo(free: 1, total: 2, minFree: 0);
      const hub = HubInfo(
        name: 'MineSync',
        version: '0.1.0',
        api: 1,
        time: 5,
        disk: disk,
        me: me,
        language: 'en',
        dnsZone: 'internal',
      );
      roundTrip((HubInfo x) => x.toJson(), HubInfo.fromJson, hub);
      final j = hub.toJson()
        ..remove('language')
        ..remove('dnsZone');
      final d = HubInfo.fromJson(jsonDecode(jsonEncode(j)));
      expect((d.language, d.dnsZone), ('auto', null));
    });

    test('LockHolder con ip e prova della porta; LockInfo.public toglie la LAN', () {
      roundTrip((LockHolder x) => x.toJson(), LockHolder.fromJson, lock);
      const info = LockInfo(address: '192.0.2.31', lan: '192.0.2.107', port: 25566);
      expect(info.toJson()['lan'], '192.0.2.107');
      expect(info.public().toJson().containsKey('lan'), isFalse);
      expect(info.public().address, '192.0.2.31');
      expect(
        () => PortCheck.fromJson({'state': 'open'}),
        throwsFormatException,
        reason: 'stato sconosciuto',
      );
      expect(() => PortCheck.fromJson({'state': 'reachable', 'port': '1'}), throwsFormatException);
    });

    test('SpaceDetails con dns, mondo, ultima sessione, impostazioni e uso', () {
      final d = SpaceDetails(
        SpaceSummary(
          id: 'survival',
          name: 'Survival',
          profile: Profile.minecraft,
          createdAt: 1,
          head: GenerationSummary(
            n: 3,
            parent: 2,
            digest: h(1),
            authorId: 'n-alice',
            author: 'alice',
            message: '',
            ts: 9,
            kind: GenerationKind.restore,
            stats: const GenerationStats(files: 10, size: 100, changed: 2),
            restoredFrom: 1,
            restoredPath: 'world/region/r.0.0.mca',
            damaged: const [DamagedFile(path: 'world/region/r.0.0.mca', bad: 3, total: 1024)],
          ),
          lock: lock,
          dnsName: 'zerotier.survival.internal',
          world: const WorldChip(
            mcVersion: '1.21.1',
            loader: Loader.fabric,
            loaderVersion: '0.16.5',
            mods: 42,
          ),
          lastSession: session,
        ),
        exclusions: const ['logs/**', 'bluemap/**'],
        ownExclusions: const ['bluemap/**'],
        profileExclusions: const ['logs/**'],
        settings: const SpaceSettings(sessions: SessionSettings(autosaveMinutes: 10)),
        inherited: const SpaceSettings(),
        overrides: const {
          'sessions': {'autosaveMinutes': 10},
        },
        usage: const SpaceUsage(
          generations: 3,
          oldest: 1,
          logical: 300,
          referenced: 150,
          exclusive: 120,
          computedAt: 9,
        ),
      );
      roundTrip((SpaceDetails x) => x.toJson(), SpaceDetails.fromJson, d);
      final back = SpaceDetails.fromJson(jsonDecode(jsonEncode(d.toJson())));
      expect(back.settings!.sessions.autosaveMinutes, 10);
      expect(back.summary.head!.damaged.single.bad, 3);
      expect(back.summary.lastSession!.players['carol'], 3600000);
    });

    test('SpaceDetails di prima (senza campi nuovi) si legge ancora', () {
      final d = SpaceDetails.fromJson({
        'id': 's',
        'name': 'S',
        'profile': 'generic',
        'createdAt': 1,
        'head': null,
        'lock': null,
        'exclusions': <Object?>[],
        'ownExclusions': <Object?>[],
        'overrides': <String, Object?>{},
        'settings': {
          'sessions': const SessionSettings().toJson(),
          'history': const HistorySettings().toJson(),
          'protection': const ProtectionSettings().toJson(),
        },
      });
      expect(d.summary.dnsName, isNull);
      expect(d.settings!.protection.massDeleteRatio, 0.5);
      expect(d.usage, isNull);
    });

    test('PushBegin con file danneggiati', () {
      final b = PushBegin(
        parent: 0,
        parentDigest: emptyDigest,
        lockToken: 't',
        manifest: Manifest.empty,
        damaged: const [DamagedFile(path: 'world/region/r.0.0.mca')],
      );
      roundTrip((PushBegin x) => x.toJson(), PushBegin.fromJson, b);
      expect(PushBegin.fromJson(b.toJson()).damaged.single.bad, isNull);
      expect(
        () => PushBegin.fromJson({
          ...b.toJson(),
          'damaged': [
            {'bad': 1},
          ],
        }),
        throwsFormatException,
      );
    });
  });

  group('Admin', () {
    test('default delle sezioni', () {
      const s = SettingsSections();
      expect(s.toJson().keys, settingsSections);
      expect(s.general.toJson(), {'name': 'MineSync', 'language': 'auto'});
      expect(s.members.toJson(), {'trustHours': 24, 'refreshSeconds': 30});
      expect(s.history.toJson(), {'keepLast': 30, 'keepHours': 24, 'keepDays': 7});
      expect(s.disk.toJson(), {'minFreeGiB': 1, 'minFreePercent': 2});
      expect(s.sessions.toJson(), {
        'autosaveMinutes': 5,
        'autostop': true,
        'autostopMinutes': 30,
        'crashRestarts': 2,
        'portTest': true,
      });
      expect(s.protection.toJson(), {'massDeleteRatio': 0.5, 'massDeleteMinFiles': 20});
      expect(s.exclusions.minecraft, minecraftExclusions);
      expect(s.exclusions.of(Profile.generic), genericExclusions);
      expect(s.stats.sessionsKept, 40);
      expect(overridableSettingsSections.every(settingsSections.contains), isTrue);
    });

    test('HubSettings andata e ritorno; sezione mancante o campo del tipo sbagliato', () {
      const v = HubSettings(
        sections: SettingsSections(
          general: GeneralSettings(name: 'Hub di casa', language: 'it'),
          exclusions: ExclusionSettings(minecraft: ['logs/**'], generic: []),
        ),
        changed: SettingsChange(by: 'bob', byId: 'n-bob', at: 5, section: 'sessions'),
      );
      roundTrip((HubSettings x) => x.toJson(), HubSettings.fromJson, v);
      final j = jsonDecode(jsonEncode(v.toJson())) as Map<String, Object?>;
      (j['sections']! as Map).remove('stats');
      expect(() => HubSettings.fromJson(j), throwsFormatException);
      final k = jsonDecode(jsonEncode(v.toJson())) as Map<String, Object?>;
      ((k['sections']! as Map)['sessions'] as Map)['autostop'] = 'sì';
      expect(() => HubSettings.fromJson(k), throwsFormatException);
    });

    test('la soglia del disco è il più alto tra GiB e percentuale', () {
      const d = DiskSettings();
      expect(d.thresholdFor(2000 << 30), (2000 << 30) ~/ 100 * 2);
      expect(d.thresholdFor(10 << 30), 1 << 30);
      expect(const DiskSettings(minFreeGiB: 0, minFreePercent: 0).thresholdFor(1 << 40), 0);
    });

    test('membri e ZTNET', () {
      const l = MemberList(
        members: [
          MemberInfo(
            id: 'n-alice',
            name: 'alice',
            role: MemberRole.admin,
            ip: '192.0.2.31',
            lastSeen: 3,
            fromConfig: true,
          ),
          MemberInfo(id: 'n-x', name: '', role: MemberRole.member, authorized: false),
        ],
        ztnet: ZtnetStatus(
          state: ZtnetState.ok,
          members: 5,
          lastRefresh: 9,
          lastError: 'timeout',
          lastErrorAt: 4,
          url: 'http://ztnet.example',
          tokenHint: '7f2a',
          networkHint: '3c91',
        ),
      );
      roundTrip((MemberList x) => x.toJson(), MemberList.fromJson, l);
      expect(
        () => MemberInfo.fromJson({'id': 'a', 'name': 'a', 'role': 'owner'}),
        throwsFormatException,
      );
    });

    test('sistema, uso, pulizia, prova esclusioni', () {
      const disk = DiskInfo(free: 180, total: 2000, minFree: 40);
      roundTrip(
        (SystemInfo x) => x.toJson(),
        SystemInfo.fromJson,
        const SystemInfo(
          version: '0.1.0',
          build: '2026-11-14',
          startedAt: 1,
          time: 100,
          disk: disk,
          http: ':8084',
          dns: DnsStatus(on: true, zone: 'internal', addr: ':53'),
          dataDir: '/data',
          allowedHosts: ['hub.example'],
          admins: ['alice'],
          minFreeEnv: 1 << 30,
          dlDir: '/dl',
          updates: [UpdateChannel(platform: 'linux-x64', version: '0.1.0', signed: true)],
          timeZone: 'UTC',
          webDir: '/web',
          webBuild: 'abcdef012345',
        ),
      );
      const u = SpaceUsage(generations: 2, logical: 10, referenced: 8, exclusive: 6, computedAt: 1);
      roundTrip(
        (HubUsage x) => x.toJson(),
        HubUsage.fromJson,
        const HubUsage(disk: disk, blobs: 50, dl: 3, spaces: {'survival': u}, computedAt: 2),
      );
      roundTrip(
        (GcPreview x) => x.toJson(),
        GcPreview.fromJson,
        const GcPreview(
          keep: 20,
          spaces: [
            GcPreviewRow(id: 'survival', name: 'Survival', now: 128, after: 38, bytes: 59),
            GcPreviewRow(
              id: 'creativo',
              name: 'Creativo',
              now: 9,
              after: 9,
              bytes: 0,
              ownRules: true,
            ),
          ],
          now: 137,
          after: 47,
          bytes: 59,
        ),
      );
      roundTrip(
        (GcReport x) => x.toJson(),
        GcReport.fromJson,
        const GcReport(generations: 6, blobs: 20, bytes: 1400),
      );
      roundTrip(
        (ExclusionTest x) => x.toJson(),
        ExclusionTest.fromJson,
        const ExclusionTest(
          path: 'logs/latest.log',
          excluded: true,
          pattern: 'logs/**',
          source: ExclusionSource.profile,
        ),
      );
    });
  });

  group('mondo', () {
    test('mondo, mod, giocatori, statistiche', () {
      const chip = WorldChip(mcVersion: '1.21.1', loader: Loader.neoforge, mods: 2);
      roundTrip(
        (WorldInfo x) => x.toJson(),
        WorldInfo.fromJson,
        const WorldInfo(
          n: 41,
          chip: chip,
          level: LevelInfo(
            name: 'Survival',
            version: '1.21.1',
            dataVersion: 3955,
            difficulty: Difficulty.normal,
            hardcore: false,
            gameMode: GameMode.survival,
            day: 412,
            timeTicks: 4392000,
            spawn: BlockPos(128, 72, -340),
            seed: '-4172144997902289642',
          ),
          properties: ServerProperties(
            motd: 'Benvenuti',
            maxPlayers: 10,
            pvp: true,
            whitelist: true,
            whitelistCount: 6,
            viewDistance: 12,
            simulationDistance: 10,
            port: 25565,
            onlineMode: true,
          ),
          modsBytes: 318,
          players: 6,
          icon: true,
        ),
      );
      // senza level.dat né server.properties
      final bare = WorldInfo.fromJson({
        'n': 1,
        'chip': {'mods': 0},
      });
      expect((bare.level, bare.properties, bare.icon), (null, null, false));
      // il seed è una stringa: un numero non passa
      expect(() => LevelInfo.fromJson({'seed': 1}), throwsFormatException);

      roundTrip(
        (ModList x) => x.toJson(),
        ModList.fromJson,
        ModList(
          n: 41,
          chip: chip,
          bytes: 1200,
          mods: [
            ModInfo(
              file: 'turbo-render-0.6.0.jar',
              size: 1100,
              h: h(2),
              id: 'turbo',
              name: 'Turbo Render',
              version: '0.6.0',
              loader: Loader.fabric,
              mcVersion: '1.21.1',
              authors: const ['studio-pixel', 'ninfea'],
              description: 'Due\nrighe',
              homepage: 'https://example.org/turbo',
              license: 'LGPL-3.0',
              icon: true,
              since: 12,
              updated: 33,
              changed: true,
            ),
            ModInfo(file: 'local.jar', size: 84, h: h(3)),
          ],
        ),
      );
      expect(ModInfo(file: 'local.jar', size: 1, h: h(3)).bare, isTrue);

      roundTrip(
        (PlayerList x) => x.toJson(),
        PlayerList.fromJson,
        const PlayerList(
          n: 41,
          ts: 9,
          players: [
            PlayerInfo(
              uuid: '00000000-0000-4000-8000-000000000001',
              name: 'alice',
              op: true,
              opLevel: 4,
              whitelisted: true,
              online: true,
              lastSeen: 7,
              playTicks: 72000,
              deaths: 23,
              mobKills: 1842,
              distanceCm: 41200000,
            ),
            PlayerInfo(uuid: '00000000-0000-4000-8000-000000000002'),
          ],
        ),
      );

      roundTrip(
        (SpaceStats x) => x.toJson(),
        SpaceStats.fromJson,
        const SpaceStats(
          kept: 40,
          sessions: [
            SessionRecord(memberId: 'n-alice', name: 'alice', start: 100),
            session,
          ],
          play: [RankEntry(name: 'bob', ms: 7200000)],
          hosting: [RankEntry(name: 'bob', ms: 7200000, memberId: 'n-bob')],
        ),
      );
      expect(
        () => SessionRecord.fromJson({...session.toJson(), 'ended': 'crashed'}),
        throwsFormatException,
      );
    });
  });

  group('storia', () {
    test('differenze e ripristino di un file', () {
      roundTrip(
        (GenerationChanges x) => x.toJson(),
        GenerationChanges.fromJson,
        const GenerationChanges(
          n: 40,
          parent: 39,
          added: DiffSection.empty,
          changed: DiffSection(
            total: 48,
            items: [DiffEntry(path: 'world/level.dat', size: 6000, prevSize: 5900)],
          ),
          removed: DiffSection(total: 1, items: [DiffEntry(path: 'logs/latest.log', size: 220)]),
          damaged: [
            DamagedReport(
              file: DamagedFile(path: 'world/region/r.-1.2.mca', bad: 3, total: 1024),
              lastIntact: 39,
            ),
          ],
        ),
      );
      final d = GenerationChanges.fromJson(
        const GenerationChanges(
          n: 1,
          parent: 0,
          added: DiffSection(total: 2, items: [DiffEntry(path: 'a', size: 1)]),
          changed: DiffSection.empty,
          removed: DiffSection.empty,
        ).toJson(),
      );
      expect(d.added.truncated, isTrue);
      expect(d.damaged, isEmpty);

      roundTrip(
        (RestoreFileRequest x) => x.toJson(),
        RestoreFileRequest.fromJson,
        const RestoreFileRequest(path: 'world/region/r.0.0.mca', from: 39, message: 'integro'),
      );
      expect(const RestoreFileRequest(path: 'a').toJson(), {'path': 'a'});
      expect(RestoreFileRequest.fromJson({'path': 'a'}).from, 0);
    });
  });

  group('Telegram', () {
    test('lo stato non ha mai il token', () {
      const s = TelegramStatus(
        settings: TelegramSettings(
          enabled: true,
          tokenSet: true,
          tokenHint: '1234',
          chat: '-1001234567890',
          language: 'en',
          topics: {'survival': 12},
        ),
        state: TelegramState.active,
        chatTitle: 'amici',
        botUsername: 'minesync_bot',
        lastSentAt: 5,
        lastSent: 'Survival è aperto',
        missingTopics: ['creativo'],
      );
      roundTrip((TelegramStatus x) => x.toJson(), TelegramStatus.fromJson, s);
      expect(jsonEncode(s.toJson()).contains('"token"'), isFalse);
      expect(const TelegramSettings().toJson(), {
        'enabled': false,
        'tokenSet': false,
        'language': 'hub',
        'notify': {'open': true, 'close': true, 'alerts': true, 'status': true},
        'coalesceMinutes': 1,
        'pushWarnMinutes': 30,
        'topics': <String, int>{},
      });
      expect(
        () => TelegramSettings.fromJson({
          ...s.settings.toJson(),
          'topics': {'survival': '12'},
        }),
        throwsFormatException,
      );
    });

    test('patch: solo i campi presenti, token vuoto = invariato', () {
      expect(const TelegramPatch().toJson(), isEmpty);
      expect(const TelegramPatch(token: '', chat: '@canale').toJson(), {'chat': '@canale'});
      expect(const TelegramPatch(enabled: false, removeToken: true).toJson(), {
        'enabled': false,
        'removeToken': true,
      });
      expect(const TelegramPatch(topics: {'survival': 'https://t.me/c/123/45'}).toJson(), {
        'topics': {'survival': 'https://t.me/c/123/45'},
      });
    });

    test('prova e chat trovate', () {
      roundTrip(
        (TelegramTestResult x) => x.toJson(),
        TelegramTestResult.fromJson,
        const TelegramTestResult(sentAt: 1, chat: '-1001', thread: 7),
      );
      roundTrip(
        (TelegramChat x) => x.toJson(),
        TelegramChat.fromJson,
        const TelegramChat(id: '-1001', type: 'supergroup', title: 'amici', thread: 7),
      );
    });
  });

  group('download ed eventi', () {
    test('elenco /dl', () {
      roundTrip(
        (DlListing x) => x.toJson(),
        DlListing.fromJson,
        DlListing(
          files: [
            DlFile(
              name: 'MineSync-0.1.0-x86_64.AppImage',
              os: DlOs.linux,
              size: 58,
              arch: 'x64',
              version: '0.1.0',
              sha256: h(4),
            ),
            const DlFile(name: 'MineSync-0.1.0.dmg', os: DlOs.macos, size: 61, arch: 'universal'),
          ],
          updates: const [UpdateChannel(platform: 'windows-x64', version: '0.1.0', signed: false)],
          signedSums: true,
        ),
      );
      expect(() => DlFile.fromJson({'name': 'x', 'os': 'beos', 'size': 1}), throwsFormatException);
    });

    test('tipi di evento unici', () {
      expect(EventType.all.toSet().length, EventType.all.length);
      expect(EventType.all, containsAll(['push', 'lock', 'unlock', 'settings', 'gc.error']));
    });

    test('codici di errore unici sul filo', () {
      final wires = [for (final c in ErrorCode.values) c.wire];
      expect(wires.toSet().length, wires.length);
      expect(ErrorCode.fromWire('rate_limited')!.status, 429);
      expect(ErrorCode.fromWire('upstream')!.status, 502);
      expect(ErrorCode.fromWire('is_head')!.status, 409);
    });
  });

  group('esclusioni', () {
    test('firstMatch dice quale pattern esclude', () {
      final ex = Exclusions(['logs/**', '*.log', 'world/session.lock']);
      expect(ex.firstMatch('logs/latest.log'), 'logs/**');
      expect(ex.firstMatch('crash/x.log'), '*.log');
      expect(ex.firstMatch('.minesync/base.json'), '.minesync*/**');
      expect(ex.firstMatch('.minesync-old'), '.minesync*');
      expect(ex.firstMatch('a.minesyncpart'), '*.minesyncpart');
      expect(ex.firstMatch('world/region/r.0.0.mca'), isNull);
      expect(ex.excludes('world/region/r.0.0.mca'), isFalse);
      expect(ex.excludes('WORLD/session.lock'), isTrue);
    });
  });
}
