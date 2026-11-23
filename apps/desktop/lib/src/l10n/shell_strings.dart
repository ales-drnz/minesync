// Testi della cornice dell'app: barra del titolo, barra laterale, stato
// della connessione, notifiche generali.
import 'package:ms_l10n/ms_l10n.dart';

abstract final class ShellStrings {
  static ShellStrings of(Lang l) => switch (l) {
    Lang.it => const _It(),
    Lang.en => const _En(),
  };

  String get appName;
  String get minimize;
  String get maximize;
  String get close;
  String get home;
  String get servers;
  String get newServer;
  String get settings;
  String get background;
  String prefetching(String server, int percent);
  String get lockFree;
  String lockPlaying(String who);
  String get lockStale;
  String connected(String hub, int latencyMs);
  String get offline;
  String get connecting;
  String restartFor(String version);
  String get trayOpen;
  String get trayQuit;
}

final class _It implements ShellStrings {
  const _It();
  @override
  String get appName => 'MineSync';
  @override
  String get minimize => 'Riduci a icona';
  @override
  String get maximize => 'Ingrandisci';
  @override
  String get close => 'Chiudi';
  @override
  String get home => 'Home';
  @override
  String get servers => 'Server';
  @override
  String get newServer => 'Nuovo server';
  @override
  String get settings => 'Impostazioni';
  @override
  String get background => 'In background';
  @override
  String prefetching(String server, int percent) => 'Download anticipato $server $percent%';
  @override
  String get lockFree => 'libero';
  @override
  String lockPlaying(String who) => who;
  @override
  String get lockStale => 'non risponde';
  @override
  String connected(String hub, int latencyMs) => '$hub ($latencyMs ms)';
  @override
  String get offline => 'Hub offline';
  @override
  String get connecting => 'Connessione…';
  @override
  String restartFor(String version) => 'Riavvia per $version';
  @override
  String get trayOpen => 'Apri MineSync';
  @override
  String get trayQuit => 'Esci';
}

final class _En implements ShellStrings {
  const _En();
  @override
  String get appName => 'MineSync';
  @override
  String get minimize => 'Minimise';
  @override
  String get maximize => 'Maximise';
  @override
  String get close => 'Close';
  @override
  String get home => 'Home';
  @override
  String get servers => 'Servers';
  @override
  String get newServer => 'New server';
  @override
  String get settings => 'Settings';
  @override
  String get background => 'In the background';
  @override
  String prefetching(String server, int percent) => 'Pre-downloading $server $percent%';
  @override
  String get lockFree => 'free';
  @override
  String lockPlaying(String who) => who;
  @override
  String get lockStale => 'not responding';
  @override
  String connected(String hub, int latencyMs) => '$hub ($latencyMs ms)';
  @override
  String get offline => 'Hub offline';
  @override
  String get connecting => 'Connecting…';
  @override
  String restartFor(String version) => 'Restart for $version';
  @override
  String get trayOpen => 'Open MineSync';
  @override
  String get trayQuit => 'Quit';
}
