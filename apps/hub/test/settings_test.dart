// Impostazioni dell'area Admin: sezioni, validazione, applicazione
// a caldo, «Ultima modifica», eventi e sovrascritture per spazio.
import 'dart:io';

import 'package:minesync_hub/minesync_hub.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late TestHub t;
  setUp(() async => t = await TestHub.start());
  tearDown(() => t.close());

  Future<Res> patch(String section, Object body, {String as = 'carol'}) =>
      t.req('PATCH', '/settings/$section', as: as, body: body);

  group('sezioni', () {
    test('GET /settings: sections, defaults di fabbrica, nessuna modifica', () async {
      final hs = HubSettings.fromJson((await t.get('/settings', as: 'carol')).json);
      expect(hs.sections.toJson(), const SettingsSections().toJson());
      expect(hs.defaults.toJson(), const SettingsSections().toJson());
      expect(hs.sections.exclusions.minecraft, minecraftExclusions);
      expect(hs.changed, isNull);
      expect((await t.get('/settings')).code, 'forbidden');
    });

    test('ogni sezione accetta un aggiornamento parziale e risponde con tutto', () async {
      final ok = <String, Map<String, Object>>{
        'general': {'name': 'Casa', 'language': 'en'},
        'members': {'trustHours': 0, 'refreshSeconds': 60},
        'history': {'keepLast': 5},
        'disk': {'minFreeGiB': 0, 'minFreePercent': 50},
        'sessions': {
          'autosaveMinutes': 10,
          'autostop': false,
          'autostopMinutes': 1440,
          'crashRestarts': 0,
          'portTest': false,
        },
        'protection': {'massDeleteRatio': 1, 'massDeleteMinFiles': 0},
        'exclusions': {
          'minecraft': ['logs/**'],
          'generic': <String>[],
        },
        'stats': {'sessionsKept': 1000},
      };
      for (final e in ok.entries) {
        final r = await patch(e.key, e.value);
        expect(r.status, 200, reason: '${e.key}: $r');
        final sec = (HubSettings.fromJson(r.json).sections.toJson()[e.key]! as Map);
        for (final f in e.value.entries) {
          expect(
            sec[f.key],
            f.value is int && e.key == 'protection' && f.key == 'massDeleteRatio' ? 1.0 : f.value,
            reason: '${e.key}.${f.key}',
          );
        }
      }
      final hs = HubSettings.fromJson((await t.get('/settings', as: 'carol')).json);
      expect(hs.sections.history.keepLast, 5);
      expect(hs.sections.history.keepDays, 7, reason: 'i campi non mandati restano');
      expect(hs.defaults.history.keepLast, 30);
    });

    test('valori non validi: 400 con details.field e niente salvato', () async {
      final bad = <String, Map<String, Object?>>{
        'general.name': {'name': 'x' * 41},
        'general.language': {'language': 'fr'},
        'members.trustHours': {'trustHours': 8761},
        'members.refreshSeconds': {'refreshSeconds': 9},
        'history.keepLast': {'keepLast': 0},
        'disk.minFreeGiB': {'minFreeGiB': 100001},
        'disk.minFreePercent': {'minFreePercent': 51},
        'sessions.autosaveMinutes': {'autosaveMinutes': 0},
        'sessions.autostop': {'autostop': 'yes'},
        'sessions.crashRestarts': {'crashRestarts': 11},
        'protection.massDeleteRatio': {'massDeleteRatio': 0},
        'exclusions.minecraft': {
          'minecraft': ['x' * 257],
        },
        'exclusions.generic': {
          'generic': [for (var i = 0; i < 501; i++) 'p$i'],
        },
        'stats.sessionsKept': {'sessionsKept': 0},
        'history.nope': {'nope': 1},
      };
      for (final e in bad.entries) {
        final section = e.key.split('.').first;
        final r = await patch(section, e.value);
        expect(r.status, 400, reason: e.key);
        expect(r.code, 'bad_request');
        expect(r.details['field'], e.key);
      }
      // un campo valido e uno no: niente salvato
      final mixed = await patch('history', {'keepLast': 3, 'keepDays': -1});
      expect(mixed.details['field'], 'history.keepDays');
      final hs = HubSettings.fromJson((await t.get('/settings', as: 'carol')).json);
      expect(hs.sections.toJson(), const SettingsSections().toJson());
    });

    test('sezione ignota e telegram: 404 (telegram ha i suoi endpoint)', () async {
      expect((await patch('telegram', {'enabled': true})).status, 404);
      expect((await patch('nope', {})).status, 404);
      expect((await patch('history', {'keepLast': 3}, as: 'alice')).status, 403);
    });

    test('nome dell\'hub al più 40 caratteri, lingua in GET /hub', () async {
      expect((await patch('general', {'name': 'x' * 40})).status, 200);
      expect((await patch('general', {'name': 'a\u0007b'})).status, 400);
      await patch('general', {'language': 'it'});
      final h = HubInfo.fromJson((await t.get('/hub')).json);
      expect(h.name, 'x' * 40);
      expect(h.language, 'it');
      expect(h.dnsZone, isNull, reason: 'DNS integrato spento');
    });
  });

  group('modifiche', () {
    test('«Ultima modifica» e evento settings con campi e valori, salvati al riavvio', () async {
      t.clock.advance(const Duration(minutes: 3));
      await patch('history', {'keepLast': 9, 'keepHours': 1});
      final hs = HubSettings.fromJson((await t.get('/settings', as: 'carol')).json);
      expect(hs.changed!.by, 'carol');
      expect(hs.changed!.byId, carol.id);
      expect(hs.changed!.at, t.clock.wallMs());
      expect(hs.changed!.section, 'history');
      final e = t.hub.events.after(0).lastWhere((e) => e.type == EventType.settings);
      expect(e.actor, 'carol');
      expect(e.data['section'], 'history');
      expect(e.data['fields'], ['keepLast', 'keepHours']);
      expect(e.data['values'], {'keepLast': 9, 'keepHours': 1});
      expect(File('${t.data}/settings.json').statSync().mode & 0x3f, 0);
      await t.restart();
      final after = HubSettings.fromJson((await t.get('/settings', as: 'carol')).json);
      expect(after.sections.history.keepLast, 9);
      expect(after.changed!.section, 'history');
    });

    test('l\'evento settings delle esclusioni ha solo i nomi dei campi', () async {
      await patch('exclusions', {
        'minecraft': ['logs/**', 'bluemap/**'],
      });
      final e = t.hub.events.after(0).lastWhere((e) => e.type == EventType.settings);
      expect(e.data['fields'], ['minecraft']);
      expect(e.data.containsKey('values'), isFalse);
    });
  });

  group('esclusioni', () {
    test('i pattern di sistema non fanno parte della lista e valgono sempre', () async {
      final r = await patch('exclusions', {
        'minecraft': ['.minesync*', ' logs/** ', '', 'bluemap/**'],
      });
      expect(HubSettings.fromJson(r.json).sections.exclusions.minecraft, ['logs/**', 'bluemap/**']);
      final space = await t.createSpace('Survival');
      final d = SpaceDetails.fromJson((await t.get('/spaces/$space')).json);
      expect(Exclusions(d.exclusions).excludes('.minesync/base.json'), isTrue);
    });

    test('gli spazi ereditano dal vivo la lista del loro profilo', () async {
      final space = await t.createSpace('Survival');
      await t.req(
        'PATCH',
        '/spaces/$space',
        as: 'carol',
        body: {
          'exclusions': ['mods/cache/**'],
        },
      );
      var d = SpaceDetails.fromJson((await t.get('/spaces/$space')).json);
      expect(d.profileExclusions, minecraftExclusions);
      await patch('exclusions', {
        'minecraft': ['bluemap/**'],
      });
      d = SpaceDetails.fromJson((await t.get('/spaces/$space')).json);
      expect(d.profileExclusions, ['bluemap/**']);
      expect(d.exclusions, ['bluemap/**', 'mods/cache/**']);
      expect(d.ownExclusions, ['mods/cache/**']);
    });

    test('usercache.json e usernamecache.json si sincronizzano di default', () {
      final ex = Exclusions(minecraftExclusions);
      expect(ex.excludes('usercache.json'), isFalse);
      expect(ex.excludes('usernamecache.json'), isFalse);
    });
  });

  group('disco', () {
    test('B-GUARD-09 soglia = max(GiB, % del volume), applicata subito', () async {
      Future<int> minFree() async => HubInfo.fromJson((await t.get('/hub')).json).disk.minFree;
      expect(await minFree(), 4 << 30, reason: '2 % di 200 GiB');
      await patch('disk', {'minFreeGiB': 10});
      expect(await minFree(), 10 << 30);
      await patch('disk', {'minFreeGiB': 0, 'minFreePercent': 0});
      expect(await minFree(), 0);
      t.disk.free = 1;
      final space = await t.createSpace('Survival');
      expect((await t.req('POST', '/spaces/$space/lock', body: {})).status, 200);
    });

    test('MINESYNC_MIN_FREE vince sulle impostazioni', () async {
      await t.close();
      t = await TestHub.start(
        options: const StoreOptions(maintenanceDelay: Duration(days: 1), minFreeOverride: 7 << 30),
      );
      await patch('disk', {'minFreeGiB': 50});
      expect(HubInfo.fromJson((await t.get('/hub')).json).disk.minFree, 7 << 30);
    });
  });

  group('sovrascritture per spazio', () {
    late String space;
    setUp(() async => space = await t.createSpace('Survival'));

    Future<SpaceDetails> details() async =>
        SpaceDetails.fromJson((await t.get('/spaces/$space')).json);

    test('sessions, history e protection parziali; {} torna a ereditare', () async {
      final r = await t.req(
        'PATCH',
        '/spaces/$space',
        as: 'carol',
        body: {
          'overrides': {
            'sessions': {'autostopMinutes': 90, 'portTest': false},
            'history': {'keepLast': 3},
          },
        },
      );
      expect(r.status, 200, reason: '$r');
      var d = await details();
      expect(d.settings!.sessions.autostopMinutes, 90);
      expect(d.settings!.sessions.portTest, isFalse);
      expect(d.settings!.sessions.autosaveMinutes, 5, reason: 'campo non sovrascritto');
      expect(d.settings!.history.keepLast, 3);
      expect(d.inherited!.sessions.autostopMinutes, 30);
      expect(d.overrides.keys, unorderedEquals(['sessions', 'history']));
      // il globale cambia: lo spazio eredita i campi non sovrascritti
      await patch('sessions', {'autosaveMinutes': 15, 'autostopMinutes': 45});
      d = await details();
      expect(d.settings!.sessions.autosaveMinutes, 15);
      expect(d.settings!.sessions.autostopMinutes, 90);
      expect(d.inherited!.sessions.autostopMinutes, 45);
      // solo history torna a ereditare; sessions resta
      await t.req(
        'PATCH',
        '/spaces/$space',
        as: 'carol',
        body: {
          'overrides': {'history': <String, Object>{}},
        },
      );
      d = await details();
      expect(d.overrides.keys, ['sessions']);
      expect(d.settings!.history.keepLast, 30);
      final hs = HubSettings.fromJson((await t.get('/settings', as: 'carol')).json);
      expect(hs.changed!.section, 'spaces');
      expect(
        t.hub.events.after(0).lastWhere((e) => e.type == EventType.spaceUpdate).data['fields'],
        ['overrides'],
      );
    });

    test('sezioni non sovrascrivibili o valori non validi: 400 con il campo', () async {
      Future<Res> ov(Object o) =>
          t.req('PATCH', '/spaces/$space', as: 'carol', body: {'overrides': o});
      var r = await ov({
        'disk': {'minFreeGiB': 1},
      });
      expect(r.code, 'bad_request');
      expect(r.details['field'], 'overrides.disk');
      r = await ov({
        'sessions': {'crashRestarts': 99},
      });
      expect(r.details['field'], 'overrides.sessions.crashRestarts');
      expect((await details()).overrides, isEmpty);
    });

    test('B-GUARD-01 la protezione sovrascritta vale subito per i push', () async {
      expect((await t.push(space, manyFiles(30))).status, 200);
      await t.req(
        'PATCH',
        '/spaces/$space',
        as: 'carol',
        body: {
          'overrides': {
            'protection': {'massDeleteRatio': 0.1},
          },
        },
      );
      final r = await t.push(space, manyFiles(20));
      expect(r.code, 'mass_delete');
    });
  });
}
