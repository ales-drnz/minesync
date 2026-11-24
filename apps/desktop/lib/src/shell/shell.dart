// Cornice dell'app: barra del titolo disegnata dall'app, barra laterale con
// i server e il contenuto della schermata corrente.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../dialogs/app_dialogs.dart';
import '../l10n/l10n.dart';
import '../platform/platform.dart';
import '../screens/common.dart' show ServerNavIcon, serverIconUrl;
import '../screens/screens.dart';
import '../state/app_state.dart';

/// Sistema operativo per l'aspetto della barra del titolo.
MsTitlebarOs get hostTitlebarOs => Platform.isMacOS
    ? MsTitlebarOs.mac
    : Platform.isWindows
    ? MsTitlebarOs.windows
    : MsTitlebarOs.linux;

/// Scala per cui è stata impostata l'ultima dimensione minima della finestra.
double? _minScale;

class Shell extends StatelessWidget {
  const Shell({super.key, required this.platform, this.os});

  final PlatformServices platform;

  /// Aspetto della barra del titolo (di default quello del sistema).
  final MsTitlebarOs? os;

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final s = context.s.shell;
    final c = MsTheme.colorsOf(context);
    final route = app.route;
    // finestra minima in proporzione alla dimensione dell'interfaccia
    final scale = PixelScope.of(context).scale;
    if (scale != _minScale) {
      _minScale = scale;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(platform.window.setMinimumSize(minWindowDesignSize * scale)),
      );
    }
    final firstRun = route is FirstRunRoute;
    return ColoredBox(
      color: c.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MsTitlebar(
            os: os ?? hostTitlebarOs,
            title: s.appName,
            version: '0.1.0',
            logo: const MsLogo(size: 16),
            minimizeLabel: s.minimize,
            maximizeLabel: s.maximize,
            closeLabel: s.close,
            crumbs: _crumbs(context, route),
            end: [
              if (!firstRun) _UpdateChip(platform: platform),
              if (!firstRun) _ConnectionChip(app: app),
            ],
            onMinimize: platform.window.minimize,
            onMaximize: platform.window.toggleMaximize,
            onClose: platform.window.hide,
            dragArea: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => platform.window.startDragging(),
              onDoubleTap: platform.window.toggleMaximize,
            ),
          ),
          Expanded(
            child: firstRun
                ? const FirstRunScreen()
                : CallbackShortcuts(
                    bindings: {
                      // nuovo server (solo admin), da ogni schermata
                      const SingleActivator(LogicalKeyboardKey.keyN, control: true): () {
                        if (app.me?.admin ?? false) app.go(const NewServerRoute());
                      },
                    },
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const AppSidebar(),
                        Expanded(child: screenFor(route)),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  List<String> _crumbs(BuildContext context, AppRoute r) {
    final app = AppStateScope.of(context);
    final s = context.s.shell;
    String name(String id) => app.space(id)?.name ?? id;
    return switch (r) {
      FirstRunRoute() => const [],
      HomeRoute() => [s.home],
      ServerRoute(:final space) => [s.servers, name(space)],
      SessionRoute(:final space) => [s.servers, name(space)],
      HistoryRoute(:final space) => [s.servers, name(space)],
      ModpackRoute(:final space, :final client) => [
        s.servers,
        name(space),
        client ? context.s.modpack.viewClient : context.s.modpack.tab,
      ],
      NewServerRoute() => [s.servers, s.newServer],
      SettingsRoute() => [s.settings],
    };
  }
}

/// "Riavvia per vX" quando un aggiornamento è pronto; il dialogo non si apre
/// mai durante una sessione.
class _UpdateChip extends StatelessWidget {
  const _UpdateChip({required this.platform});
  final PlatformServices platform;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: platform.updates,
    builder: (context, _) {
      final v = platform.updates.ready;
      if (v == null) return const SizedBox.shrink();
      return MsChip(
        context.s.shell.restartFor(v),
        tone: MsChipTone.update,
        icon: const MsIcon(MsIcons.download),
        onTap: () async {
          if (await showUpdateReady(context, version: v)) await platform.updates.restart();
        },
      );
    },
  );
}

class _ConnectionChip extends StatelessWidget {
  const _ConnectionChip({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final s = context.s.shell;
    return switch (app.connection) {
      Connection.online => MsLive(s.connected(app.hub?.name ?? '', app.latencyMs ?? 0)),
      Connection.offline => MsLive(s.offline, online: false),
      Connection.connecting || Connection.none => MsLive(s.connecting, online: false),
    };
  }
}

/// Barra laterale: Home, i server dell'hub con lo stato del lock, le
/// impostazioni.
class AppSidebar extends StatelessWidget {
  const AppSidebar({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final s = context.s.shell;
    final route = app.route;
    final g = PixelScope.of(context);
    return MsSidebar(
      children: [
        MsNavItem(
          label: s.home,
          icon: const MsIcon(MsIcons.home),
          current: route is HomeRoute,
          onPressed: () => app.go(const HomeRoute()),
        ),
        MsSidebarSection(s.servers),
        for (final sp in app.spaces)
          MsNavItem(
            label: sp.name,
            icon: ServerNavIcon(url: serverIconUrl(app, sp.id, sp.head?.n)),
            iconSize: 24,
            current: switch (route) {
              ServerRoute(:final space) ||
              SessionRoute(:final space) ||
              HistoryRoute(:final space) ||
              ModpackRoute(:final space) => space == sp.id,
              _ => false,
            },
            trailing: MsNavTrail(dot: _dot(sp.lock)),
            // lo stato non solo dal colore del pallino
            semanticLabel:
                '${sp.name}, ${switch (_dot(sp.lock)) {
                  MsNavDotKind.free => context.s.server.lockFree,
                  MsNavDotKind.stale => context.s.server.lockStale,
                  _ => context.s.server.lockPlay,
                }}',
            onPressed: () => app.go(ServerRoute(sp.id)),
          ),
        if (app.spaces.isEmpty && app.connection == Connection.online)
          Padding(
            padding: EdgeInsets.fromLTRB(g.d(8), g.d(4), g.d(8), g.d(8)),
            child: MsText.small(context.s.home.noServers, tone: MsTextTone.secondary),
          ),
        // slot tratteggiato allineato alle voci (stessa colonna dell'icona);
        // Ctrl+N funziona ma non si mostra
        if (app.me?.admin ?? false)
          MsNavItem(
            label: s.newServer,
            icon: const MsIcon(MsIcons.plus),
            dashed: true,
            current: route is NewServerRoute,
            semanticLabel: s.newServer,
            onPressed: () => app.go(const NewServerRoute()),
          ),
        const Spacer(),
        if (app.prefetching case final id?) _Prefetch(space: id),
      ],
      // Impostazioni in fondo, sotto un filo: voce di servizio, non un luogo
      // come i server
      footer: [
        MsNavItem(
          label: s.settings,
          icon: const MsIcon(MsIcons.gear),
          current: route is SettingsRoute,
          onPressed: () => app.go(const SettingsRoute()),
        ),
      ],
    );
  }

  static MsNavDotKind _dot(LockHolder? l) => l == null
      ? MsNavDotKind.free
      : l.stale
      ? MsNavDotKind.stale
      : MsNavDotKind.play;
}

/// Pre-scarico in background in fondo alla barra laterale.
class _Prefetch extends StatelessWidget {
  const _Prefetch({required this.space});
  final String space;

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final strings = context.s;
    final s = strings.home;
    final ss = app.spaceState(space);
    return ListenableBuilder(
      listenable: ss,
      builder: (context, _) {
        final frac = ss.transfer?.fraction ?? 0;
        final name = app.space(space)?.name ?? space;
        return MsSlot(
          padding: const EdgeInsets.all(12),
          child: MsStack(
            gap: 8,
            children: [
              MsText.label(strings.shell.background, tone: MsTextTone.secondary),
              MsProgressMeta(
                start: MsText.rich([
                  MsSpan('${s.prefetchWord} '),
                  MsSpan(name, strong: true),
                ], kind: MsTextKind.small),
                end: MsText.small(strings.fmt.percent(frac), weight: 700, tabular: true),
              ),
              MsProgress(
                value: frac,
                thin: true,
                semanticLabel: strings.shell.prefetching(name, (frac * 100).floor()),
              ),
              MsText.small(s.prefetchHint, tone: MsTextTone.secondary),
            ],
          ),
        );
      },
    );
  }
}
