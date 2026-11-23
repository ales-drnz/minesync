// Avvio dell'hub: configurazione dall'ambiente, spegnimento pulito su
// SIGTERM e SIGINT. `hub healthcheck` controlla un hub già avviato (per
// l'HEALTHCHECK dell'immagine Docker, che non ha una shell).
import 'dart:async';
import 'dart:io';

import 'package:minesync_hub/minesync_hub.dart';

Future<void> main(List<String> args) async {
  final HubConfig config;
  try {
    config = HubConfig.fromEnv(Platform.environment);
  } on FormatException catch (e) {
    stderr.writeln('hub: configurazione non valida: ${e.message}');
    exit(2);
  }
  if (args.isNotEmpty) {
    if (args.length == 1 && args[0] == 'healthcheck') {
      final problem = await healthCheck(config);
      if (problem != null) stderr.writeln('hub: healthcheck: $problem');
      exit(problem == null ? 0 : 1);
    }
    stderr.writeln('uso: hub [healthcheck]');
    exit(64);
  }
  final hub = await Hub.start(config);
  final extras = await _startExtras(hub);
  final stop = Completer<ProcessSignal>();
  final subs = [
    ProcessSignal.sigint.watch().listen((s) => stop.isCompleted ? null : stop.complete(s)),
    if (!Platform.isWindows)
      ProcessSignal.sigterm.watch().listen((s) => stop.isCompleted ? null : stop.complete(s)),
  ];
  // il messaggio dopo i gestori dei segnali: chi lo legge può già fermarci
  stderr.writeln(
    'hub: MineSync $hubVersion in ascolto su ${config.address.address}:${hub.port}, dati in ${config.dataDir}',
  );
  final sig = await stop.future;
  stderr.writeln('hub: $sig, spegnimento');
  for (final s in subs) {
    await s.cancel();
  }
  await extras.stop();
  await hub.close().timeout(const Duration(seconds: 10), onTimeout: () {});
  exit(0);
}

/// DNS e bot Telegram: partono solo nel processo vero dell'hub, non nei test
/// che avviano [Hub] da soli.
Future<({Future<void> Function() stop})> _startExtras(Hub hub) async {
  final cfg = hub.config, store = hub.store;
  DnsServer? dns;
  final bind = cfg.dnsBind;
  if (cfg.dnsZone != null && bind != null) {
    dns = DnsServer(
      zone: cfg.dnsZone!,
      lookup: lockLookup(store.peekSpace, (l) => l.isStale(store.clock, store.options.lockTtl)),
    );
    if (await dns.start(bind.$1, bind.$2)) {
      stderr.writeln('hub: DNS della zona ${dns.zone} su ${dns.status.addr}');
    }
    // stato per GET /hub (dnsZone), i nomi dei server e Admin › Sistema
    hub.dns
      ..running = dns.running
      ..zone = dns.zone
      ..addr = dns.status.addr
      ..error = dns.status.error;
  }
  final file = TelegramConfigFile('${cfg.dataDir}/telegram.json');
  final bot = TelegramBot(
    transport: HttpTelegramTransport(),
    clock: store.clock,
    spaces: store.listSpaces,
    events: hub.events.live,
    config: await file.load(),
    dnsZone: () => dns != null && dns.running ? dns.zone : null,
    hubLanguage: () => _botLanguage(store.settings.language),
    publish: hub.events.publish,
    log: stderr.writeln,
  )..start();
  final routes = TelegramRoutes(
    bot: bot,
    file: file,
    clock: store.clock,
    spaceNames: () => {for (final s in store.listSpaces()) s.id: s.name},
    publish: hub.events.publish,
    onChanged: (who) => store.noteSettingsChange(who, 'telegram'),
  );
  hub.apiRoutes.add(routes.handle);
  return (
    stop: () async {
      await bot.stop();
      await dns?.stop();
    },
  );
}

/// Lingua dei messaggi del bot: quella di Admin › Generale; «automatica»
/// segue la lingua del sistema dell'hub.
String _botLanguage(String setting) => switch (setting) {
  'it' || 'en' => setting,
  _ => Platform.localeName.toLowerCase().startsWith('it') ? 'it' : 'en',
};
