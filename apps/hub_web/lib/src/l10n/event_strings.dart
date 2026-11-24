// Testi degli eventi dell'hub (feed Attività della Panoramica, poi Storia e
// Admin): etichetta del badge, frase con i nomi in grassetto, riga sotto.
// Un tipo sconosciuto si mostra così com'è.
import 'package:ms_l10n/ms_l10n.dart';
import 'package:ms_protocol/ms_protocol.dart';

import 'format_strings.dart';

abstract final class EventStrings {
  static EventStrings of(Lang l) => switch (l) {
    Lang.it => const _It(),
    Lang.en => const _En(),
  };

  /// Etichetta breve del badge (`EventType`).
  String badge(String type);

  /// La frase: [space] è il nome del server (o l'id se non c'è più).
  Rich text(HubEvent e, String? space, FormatStrings f);

  /// Riga sotto la frase: server e dettaglio, o "Hub" / "Admin".
  List<String> meta(HubEvent e, String? space, {String? dnsName});

  /// Nome di una sezione delle impostazioni (`settings.section`).
  String section(String s);
}

int _int(Object? v) => v is int ? v : 0;

/// Un campo dei dati per le frasi; "?" se l'hub non l'ha mandato.
String _v(Map<String, Object?> d, String k) => '${d[k] ?? '?'}';
String _str(Object? v, [String fallback = '?']) => v is String && v.isNotEmpty ? v : fallback;

final class _It implements EventStrings {
  const _It();

  @override
  String badge(String type) => switch (type) {
    EventType.push => 'Salva',
    EventType.lock => 'Avvio',
    EventType.unlock => 'Stop',
    EventType.stale => 'Stale',
    EventType.force => 'Force',
    EventType.port => 'Porta',
    EventType.restore || EventType.restoreFile => 'Ripristino',
    EventType.generationDelete => 'Elimina',
    EventType.spaceCreate || EventType.spaceUpdate || EventType.spaceDelete => 'Server',
    EventType.gc || EventType.gcError => 'Pulizia',
    EventType.disk => 'Disco',
    EventType.settings => 'Impost.',
    EventType.memberRole => 'Ruolo',
    EventType.ztnet => 'ZTNET',
    EventType.telegramError => 'Telegram',
    _ => type,
  };

  @override
  String section(String s) => switch (s) {
    'general' => 'Generale',
    'members' => 'Accesso e membri',
    'history' => 'Storia',
    'disk' => 'Disco',
    'sessions' => 'Sessioni di gioco',
    'protection' => 'Protezioni',
    'exclusions' => 'Esclusioni',
    'stats' => 'Statistiche',
    'telegram' => 'Telegram',
    _ => s,
  };

  @override
  Rich text(HubEvent e, String? space, FormatStrings f) {
    final a = _str(e.actor);
    final sp = space ?? _str(e.space);
    final d = e.data;
    return switch (e.type) {
      EventType.push => [('$a ha salvato sull\'hub', true)],
      EventType.lock => switch (d['tookOver']) {
        final String was when was == a => [('$a ha ripreso il server', true)],
        final String was => [('$a ha aperto il server', true), (' (era di $was)', false)],
        _ =>
          d['action'] == 'push'
              ? [(a, true), (' sta salvando dall\'app', false)]
              : [('$a ha aperto il server', true)],
      },
      EventType.unlock =>
        d['durationMs'] is int
            ? [
                (
                  '$a ha chiuso il server dopo ${f.duration(Duration(milliseconds: _int(d['durationMs'])))}',
                  true,
                ),
              ]
            : [('$a ha chiuso il server', true)],
      EventType.stale => [('Il PC di ', false), ('${_str(d['holder'], a)} non risponde', true)],
      EventType.force => [
        (a, true),
        (' ha liberato il server, prima in uso da ', false),
        (_str(d['from']), true),
      ],
      EventType.port =>
        d['state'] == 'reachable'
            ? [('Porta ${d['port'] ?? 25565} raggiungibile dall\'esterno', false)]
            : [
                (
                  'Porta ${d['port'] ?? 25565} chiusa: server non raggiungibile dall\'esterno',
                  false,
                ),
              ],
      EventType.restore => [('$a ha ripristinato la versione ${_v(d, 'restoredFrom')}', true)],
      EventType.restoreFile => [
        (a, true),
        (' ha ripristinato ${_str(d['path'])} dalla versione ${_v(d, 'restoredFrom')}', false),
      ],
      EventType.generationDelete => [
        (a, true),
        (' ha eliminato la versione ${_v(d, 'n')} (${f.size(_int(d['bytes']))} liberati)', false),
      ],
      EventType.spaceCreate => [
        (a, true),
        (' ha creato il server ', false),
        (_str(d['name'], sp), true),
      ],
      EventType.spaceUpdate => [(a, true), (' ha modificato il server ', false), (sp, true)],
      EventType.spaceDelete => [(a, true), (' ha eliminato il server ', false), (sp, true)],
      EventType.gc => [
        if (e.actor != null) ('Pulizia di $a: ', false) else ('Pulizia: ', false),
        ('${d['generations'] ?? 0} versioni rimosse, ${f.size(_int(d['bytes']))} liberati', false),
      ],
      EventType.gcError => [
        ('Pulizia non riuscita: versione ${_v(d, 'generation')} illeggibile', false),
      ],
      EventType.disk =>
        d['level'] == 'full'
            ? [
                (
                  'Disco pieno, salvataggi rifiutati. Liberi ${f.size(_int(d['free']))} su '
                      '${f.size(_int(d['total']))}',
                  true,
                ),
              ]
            : [
                (
                  'Disco quasi pieno: liberi ${f.size(_int(d['free']))} su ${f.size(_int(d['total']))}',
                  false,
                ),
              ],
      EventType.settings => [
        (a, true),
        (' ha cambiato le impostazioni: ${section(_str(d['section']))}', false),
      ],
      EventType.memberRole => [
        (a, true),
        (d['role'] == 'admin' ? ' ha reso admin ' : ' ha tolto i diritti di admin a ', false),
        (_str(d['member']), true),
      ],
      EventType.ztnet =>
        d['state'] == 'ok'
            ? [('ZTNET di nuovo raggiungibile', false)]
            : [('ZTNET non risponde. I dispositivi già noti restano riconosciuti', false)],
      EventType.telegramError => [
        ('Invio del bot Telegram non riuscito: ${_str(d['error'])}', false),
      ],
      _ => [(e.type, false)],
    };
  }

  @override
  List<String> meta(HubEvent e, String? space, {String? dnsName}) {
    final sp = space ?? e.space;
    if (sp == null) {
      return switch (e.type) {
        EventType.settings || EventType.memberRole => ['Admin'],
        _ => ['Hub'],
      };
    }
    return switch (e.type) {
      EventType.push => [sp, _kind(e.data['kind'])],
      EventType.lock when dnsName != null => [sp, dnsName],
      _ => [sp],
    };
  }

  static String _kind(Object? k) => switch (k) {
    'autosave' => 'autosave',
    'restore' => 'ripristino',
    _ => 'salvataggio',
  };
}

final class _En implements EventStrings {
  const _En();

  @override
  String badge(String type) => switch (type) {
    EventType.push => 'Save',
    EventType.lock => 'Start',
    EventType.unlock => 'Stop',
    EventType.stale => 'Stale',
    EventType.force => 'Force',
    EventType.port => 'Port',
    EventType.restore || EventType.restoreFile => 'Restore',
    EventType.generationDelete => 'Delete',
    EventType.spaceCreate || EventType.spaceUpdate || EventType.spaceDelete => 'Server',
    EventType.gc || EventType.gcError => 'Cleanup',
    EventType.disk => 'Disk',
    EventType.settings => 'Settings',
    EventType.memberRole => 'Role',
    EventType.ztnet => 'ZTNET',
    EventType.telegramError => 'Telegram',
    _ => type,
  };

  @override
  String section(String s) => switch (s) {
    'general' => 'General',
    'members' => 'Access and members',
    'history' => 'History',
    'disk' => 'Disk',
    'sessions' => 'Game sessions',
    'protection' => 'Protection',
    'exclusions' => 'Exclusions',
    'stats' => 'Statistics',
    'telegram' => 'Telegram',
    _ => s,
  };

  @override
  Rich text(HubEvent e, String? space, FormatStrings f) {
    final a = _str(e.actor);
    final sp = space ?? _str(e.space);
    final d = e.data;
    return switch (e.type) {
      EventType.push => [('$a saved to the hub', true)],
      EventType.lock => switch (d['tookOver']) {
        final String was when was == a => [('$a resumed the server', true)],
        final String was => [('$a opened the server', true), (" (was $was's)", false)],
        _ =>
          d['action'] == 'push'
              ? [(a, true), (' is saving from the app', false)]
              : [('$a opened the server', true)],
      },
      EventType.unlock =>
        d['durationMs'] is int
            ? [
                (
                  '$a closed the server after ${f.duration(Duration(milliseconds: _int(d['durationMs'])))}',
                  true,
                ),
              ]
            : [('$a closed the server', true)],
      EventType.stale => [("${_str(d['holder'], a)}'s PC", true), (' is not responding', false)],
      EventType.force => [
        (a, true),
        (' freed the server, previously held by ', false),
        (_str(d['from']), true),
      ],
      EventType.port =>
        d['state'] == 'reachable'
            ? [('Port ${d['port'] ?? 25565} reachable from outside', false)]
            : [('Port ${d['port'] ?? 25565} closed: server not reachable from outside', false)],
      EventType.restore => [('$a restored version ${_v(d, 'restoredFrom')}', true)],
      EventType.restoreFile => [
        (a, true),
        (' restored ${_str(d['path'])} from version ${_v(d, 'restoredFrom')}', false),
      ],
      EventType.generationDelete => [
        (a, true),
        (' deleted version ${_v(d, 'n')} (${f.size(_int(d['bytes']))} freed)', false),
      ],
      EventType.spaceCreate => [
        (a, true),
        (' created the server ', false),
        (_str(d['name'], sp), true),
      ],
      EventType.spaceUpdate => [(a, true), (' changed the server ', false), (sp, true)],
      EventType.spaceDelete => [(a, true), (' deleted the server ', false), (sp, true)],
      EventType.gc => [
        if (e.actor != null) ('Cleanup by $a: ', false) else ('Cleanup: ', false),
        ('${d['generations'] ?? 0} versions removed, ${f.size(_int(d['bytes']))} freed', false),
      ],
      EventType.gcError => [('Cleanup failed: version ${_v(d, 'generation')} unreadable', false)],
      EventType.disk =>
        d['level'] == 'full'
            ? [
                (
                  'Disk full, saves refused. ${f.size(_int(d['free']))} free of '
                      '${f.size(_int(d['total']))}',
                  true,
                ),
              ]
            : [
                (
                  'Disk nearly full: ${f.size(_int(d['free']))} free of ${f.size(_int(d['total']))}',
                  false,
                ),
              ],
      EventType.settings => [
        (a, true),
        (' changed the settings: ${section(_str(d['section']))}', false),
      ],
      EventType.memberRole => [
        (a, true),
        (d['role'] == 'admin' ? ' made ' : ' removed admin rights from ', false),
        (_str(d['member']), true),
        if (d['role'] == 'admin') (' an admin', false),
      ],
      EventType.ztnet =>
        d['state'] == 'ok'
            ? [('ZTNET reachable again', false)]
            : [('ZTNET not responding. Known devices stay recognised', false)],
      EventType.telegramError => [('Telegram bot failed to send: ${_str(d['error'])}', false)],
      _ => [(e.type, false)],
    };
  }

  @override
  List<String> meta(HubEvent e, String? space, {String? dnsName}) {
    final sp = space ?? e.space;
    if (sp == null) {
      return switch (e.type) {
        EventType.settings || EventType.memberRole => ['Admin'],
        _ => ['Hub'],
      };
    }
    return switch (e.type) {
      EventType.push => [sp, _kind(e.data['kind'])],
      EventType.lock when dnsName != null => [sp, dnsName],
      _ => [sp],
    };
  }

  static String _kind(Object? k) => switch (k) {
    'autosave' => 'autosave',
    'restore' => 'restore',
    _ => 'save',
  };
}
