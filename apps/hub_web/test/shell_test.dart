// Cornice e percorsi: schede dell'header (Admin solo per gli admin), URL
// veri con titoli della scheda del browser, indietro, pagine stub del
// server e dell'admin, pagina non trovata, accesso negato, lingua e tema
// dall'header, golden della cornice.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:minesync_hub_web/src/pages/admin/admin_page.dart';
import 'package:minesync_hub_web/src/pages/download/download_page.dart';
import 'package:minesync_hub_web/src/pages/not_found_page.dart';
import 'package:minesync_hub_web/src/pages/overview/overview_page.dart';
import 'package:minesync_hub_web/src/pages/server/server_page.dart';
import 'package:minesync_hub_web/src/router.dart';
import 'package:minesync_hub_web/src/shell/access_denied.dart';
import 'package:minesync_hub_web/src/shell/header.dart';
import 'package:minesync_hub_web/src/state/hub_state.dart';
import 'package:ms_l10n/ms_l10n.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import 'support/harness.dart';

GoRouter routerOf(WidgetTester t) => GoRouter.of(t.element(find.byType(HubHeader)));

void main() {
  setUpAll(loadFonts);

  test('URL delle pagine', () {
    expect(HubRoutes.server('survival'), '/server/survival');
    expect(HubRoutes.server('survival', ServerTab.mods), '/server/survival/mods');
    expect(HubRoutes.adminSection(AdminSection.telegram), '/admin/telegram');
    expect(ServerTab.fromSlug(null), ServerTab.overview);
    expect(ServerTab.fromSlug('history'), ServerTab.history);
    expect(ServerTab.fromSlug('nope'), isNull);
    expect(navFor('/server/x/mods'), HubNav.servers);
    expect(navFor('/dl'), HubNav.download);
    expect(navFor('/admin/system'), HubNav.admin);
  });

  testWidgets('schede dell\'header e titoli delle pagine; indietro', (t) async {
    await pumpHub(t, testState());
    expect(find.byType(OverviewPage), findsOneWidget);
    expect(documentTitle(t), 'Server (Hub di casa)');
    await t.tap(find.bySemanticsLabel('Download'));
    await settle(t);
    expect(find.byType(DownloadPage), findsOneWidget);
    expect(documentTitle(t), 'Download (Hub di casa)');
    await t.tap(find.bySemanticsLabel('Admin').first);
    await settle(t);
    expect(find.byType(AdminPage), findsOneWidget);
    expect(documentTitle(t), 'Amministrazione (Hub di casa)');
    unawaited(routerOf(t).push(HubRoutes.adminSection(AdminSection.telegram)));
    await settle(t);
    expect(documentTitle(t), 'Telegram (Hub di casa)');
    routerOf(t).pop();
    await settle(t);
    expect(documentTitle(t), 'Amministrazione (Hub di casa)');
  });

  testWidgets('membro: niente scheda Admin, /admin dice "riservata agli admin"', (t) async {
    await pumpHub(t, testState(me: bob), location: '/admin/members');
    expect(find.bySemanticsLabel('Admin'), findsNothing);
    expect(find.byType(AdminOnly), findsOneWidget);
    expect(msText('Area riservata agli admin'), findsWidgets);
  });

  testWidgets('pagina server: schede con URL, Amministrazione solo admin', (t) async {
    await pumpHub(t, testState(), location: '/server/survival/history');
    expect(
      find.byWidgetPredicate((w) => w is ServerPage && w.tab == ServerTab.history),
      findsOneWidget,
    );
    expect(documentTitle(t), 'Survival: Storia (Hub di casa)');
    await t.tap(find.bySemanticsLabel(RegExp(r'^Mod\b')).first);
    await settle(t);
    expect(
      find.byWidgetPredicate((w) => w is ServerPage && w.tab == ServerTab.mods),
      findsOneWidget,
    );
    expect(routerOf(t).routerDelegate.currentConfiguration.uri.path, '/server/survival/mods');
  });

  testWidgets('membro: niente scheda Amministrazione del server', (t) async {
    await pumpHub(t, testState(me: bob), location: '/server/survival/admin');
    expect(find.byType(NotFoundPage), findsOneWidget);
  });

  testWidgets('percorso o server sconosciuto: pagina non trovata', (t) async {
    await pumpHub(t, testState(), location: '/nope/really');
    expect(find.byType(NotFoundPage), findsOneWidget);
    await t.tap(msButton('Torna ai server'));
    await settle(t);
    expect(find.byType(OverviewPage), findsOneWidget);
    routerOf(t).go('/server/sconosciuto');
    await settle(t);
    expect(find.byType(NotFoundPage), findsOneWidget);
  });

  testWidgets('accesso negato su ogni percorso, Riprova e link a ZeroTier', (t) async {
    final s = testState(
      setup: (s) => s.debugSet(
        connection: HubConnection.denied,
        lastError: const ApiError(
          ErrorCode.unauthenticated,
          'x',
          details: {'ip': '198.51.100.23', 'network': '192.0.2.0/24'},
        ),
      ),
    );
    await pumpHub(t, s, location: '/dl');
    expect(find.byType(AccessDeniedPage), findsOneWidget);
    expect(find.byType(DownloadPage), findsNothing);
    expect(msText('Dispositivo non riconosciuto'), findsWidgets);
    expect(find.bySemanticsLabel('Download'), findsNothing);
    await t.tap(msButton('Cos\'è ZeroTier?'));
    expect(fakePlatform(s).opened, [zeroTierInfo]);
    fakeApi(s).calls.clear();
    await t.tap(msButton('Riprova'));
    await t.pump();
    expect(fakeApi(s).calls, contains('hub'));
    expect(s.connection, HubConnection.online);
    s.debugStop();
  });

  testWidgets('IT/EN e tema dall\'header', (t) async {
    final s = testState();
    await pumpHub(t, s);
    await t.tap(find.bySemanticsLabel('English'));
    await t.pump();
    expect(s.lang, Lang.en);
    expect(fakePlatform(s).prefs[PrefKeys.lang], 'en');
    expect(find.bySemanticsLabel('Servers'), findsWidgets);
    expect(documentTitle(t), 'Servers (Hub di casa)');
    final light = MsTheme.of(t.element(find.byType(OverviewPage))).brightness == Brightness.light;
    await t.tap(find.bySemanticsLabel(light ? 'Switch to dark theme' : 'Switch to light theme'));
    await t.pump();
    expect(s.themeChoice, light ? ThemeChoice.dark : ThemeChoice.light);
  });

  testWidgets('pillola: dal vivo con latenza, offline, connessione', (t) async {
    final s = testState();
    await pumpHub(t, s);
    expect(find.byWidgetPredicate((w) => w is MsLive && w.label == '18 ms'), findsOneWidget);
    s.debugSet(connection: HubConnection.offline);
    await t.pump();
    expect(
      find.byWidgetPredicate((w) => w is MsLive && w.label == 'Offline' && !w.online),
      findsOneWidget,
    );
    expect(msText('Hub non raggiungibile'), findsOneWidget);
  });

  testWidgets('golden: accesso negato', (t) async {
    final s = testState(
      setup: (s) => s.debugSet(
        connection: HubConnection.denied,
        lastError: const ApiError(ErrorCode.unauthenticated, 'x'),
      ),
    );
    await expectHubGolden(t, 'access_denied', s);
  });

  testWidgets('golden: accesso negato, telefono', (t) async {
    final s = testState(
      setup: (s) => s.debugSet(
        connection: HubConnection.denied,
        lastError: const ApiError(ErrorCode.unauthenticated, 'x'),
      ),
    );
    await expectHubGolden(t, 'access_denied_phone', s, size: const Size(375, 1100));
  });

  testWidgets('golden: cornice con pagina server, tema scuro', (t) async {
    final s = testState(setup: (s) => s.setTheme(ThemeChoice.dark));
    await expectHubGolden(
      t,
      'shell_server',
      s,
      location: '/server/survival',
      size: const Size(1280, 600),
    );
  });

  testWidgets('golden: header a 600 px (due righe)', (t) async {
    await expectHubGolden(
      t,
      'shell_narrow',
      testState(),
      location: '/admin',
      size: const Size(600, 700),
    );
  });
}
