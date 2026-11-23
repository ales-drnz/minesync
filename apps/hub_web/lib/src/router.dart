// Percorsi della web UI con URL veri (l'hub serve index.html per ogni
// percorso senza estensione): il tasto indietro del browser e i link
// diretti funzionano. Per una pagina nuova: una costante o un costruttore in
// [HubRoutes], una GoRoute sotto, la pagina avvolta in PageTitle.
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'pages/admin/admin_page.dart';
import 'pages/download/download_page.dart';
import 'pages/not_found_page.dart';
import 'pages/overview/overview_page.dart';
import 'pages/server/server_page.dart';
import 'shell/shell.dart';

/// Schede della pagina di un server, con il loro pezzo di URL.
enum ServerTab {
  overview(''),
  players('players'),
  mods('mods'),
  history('history'),
  admin('admin');

  const ServerTab(this.slug);
  final String slug;

  static ServerTab? fromSlug(String? s) =>
      s == null || s.isEmpty ? overview : values.where((t) => t.slug == s).firstOrNull;
}

/// Sezioni dell'area Admin (`/admin/<slug>`), nell'ordine del design.
enum AdminSection {
  general('general'),
  members('members'),
  history('history'),
  sessions('sessions'),
  protection('protection'),
  exclusions('exclusions'),
  telegram('telegram'),
  stats('stats'),
  system('system');

  const AdminSection(this.slug);
  final String slug;

  static AdminSection? fromSlug(String? s) => values.where((t) => t.slug == s).firstOrNull;
}

/// Gli URL delle pagine.
abstract final class HubRoutes {
  static const overview = '/';
  static const download = '/dl';
  static const admin = '/admin';

  static String server(String id, [ServerTab tab = ServerTab.overview]) => tab == ServerTab.overview
      ? '/server/${Uri.encodeComponent(id)}'
      : '/server/${Uri.encodeComponent(id)}/${tab.slug}';

  static String adminSection(AdminSection s) => '/admin/${s.slug}';
}

Page<void> _page(GoRouterState s, Widget child) =>
    NoTransitionPage<void>(key: s.pageKey, child: child);

/// Il router della web UI; [initialLocation] serve ai test.
GoRouter buildRouter({String? initialLocation}) => GoRouter(
  initialLocation: initialLocation,
  errorPageBuilder: (context, s) =>
      _page(s, HubShell(location: s.uri.path, child: const NotFoundPage())),
  routes: [
    ShellRoute(
      builder: (context, s, child) => HubShell(location: s.uri.path, child: child),
      routes: [
        GoRoute(path: HubRoutes.overview, pageBuilder: (c, s) => _page(s, const OverviewPage())),
        GoRoute(path: HubRoutes.download, pageBuilder: (c, s) => _page(s, const DownloadPage())),
        GoRoute(
          path: '/server/:id',
          pageBuilder: (c, s) => _page(s, ServerPage(id: s.pathParameters['id']!)),
          routes: [
            GoRoute(
              path: ':tab',
              pageBuilder: (c, s) {
                final tab = ServerTab.fromSlug(s.pathParameters['tab']);
                return _page(
                  s,
                  tab == null
                      ? const NotFoundPage()
                      : ServerPage(id: s.pathParameters['id']!, tab: tab),
                );
              },
            ),
          ],
        ),
        GoRoute(
          path: HubRoutes.admin,
          pageBuilder: (c, s) => _page(s, const AdminPage()),
          routes: [
            GoRoute(
              path: ':section',
              pageBuilder: (c, s) {
                final sec = AdminSection.fromSlug(s.pathParameters['section']);
                return _page(s, sec == null ? const NotFoundPage() : AdminPage(section: sec));
              },
            ),
          ],
        ),
      ],
    ),
  ],
);
