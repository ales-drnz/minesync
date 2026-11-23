// Pagina di un server: percorso, intestazione (icona, nome, #HEAD, lock,
// chip versione/loader/mod/spazio, zip della HEAD) e schede Panoramica,
// Giocatori, Mod, Storia, Amministrazione (solo admin), ognuna con il suo
// URL `/server/<id>/<scheda>`. I dati condivisi stanno in [ServerData] e si
// aggiornano dal vivo con gli eventi dell'hub.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../../l10n/l10n.dart';
import '../../router.dart';
import '../../state/hub_state.dart';
import '../../widgets/lock_view.dart';
import '../../widgets/page.dart';
import '../not_found_page.dart';
import 'history_tab.dart';
import 'mods_tab.dart';
import 'overview_tab.dart';
import 'players_tab.dart';
import 'server_admin_tab.dart';
import 'server_data.dart';

class ServerPage extends StatelessWidget {
  const ServerPage({super.key, required this.id, this.tab = ServerTab.overview});

  final String id;
  final ServerTab tab;

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s.server;
    final sp = app.space(id);
    if (sp == null && app.spacesLoaded) return const NotFoundPage();
    // la scheda Amministrazione è solo per gli admin
    if (tab == ServerTab.admin && !app.isAdmin && app.me != null) return const NotFoundPage();
    final data = ServerData.of(app, id)..sync(sp);
    final name = sp?.name ?? id;
    return ServerDataScope(
      data: data,
      child: Builder(
        builder: (context) {
          final d = ServerDataScope.of(context);
          final world = d.world.value;
          final gens = d.details.value?.usage?.generations ?? sp?.headN;
          return PageBody(
            title: '$name: ${tabLabel(s, tab)}',
            children: [
              _Heading(id: id, space: sp, name: name),
              MsTabs<ServerTab>(
                semanticLabel: s.tabsLabel(name),
                value: tab,
                tabs: [
                  for (final t in ServerTab.values)
                    if (t != ServerTab.admin || app.isAdmin)
                      MsTab(
                        value: t,
                        label: tabLabel(s, t),
                        icon: t == ServerTab.admin ? const MsIcon(MsIcons.shield) : null,
                        count: switch (t) {
                          ServerTab.players when (world?.players ?? 0) > 0 => '${world!.players}',
                          ServerTab.mods when (sp?.world?.mods ?? 0) > 0 => '${sp!.world!.mods}',
                          ServerTab.history when (gens ?? 0) > 0 => '$gens',
                          _ => null,
                        },
                      ),
                ],
                onChanged: (t) => context.go(HubRoutes.server(id, t)),
              ),
              _tabBody(sp),
            ],
          );
        },
      ),
    );
  }

  static String tabLabel(ServerStrings s, ServerTab t) => switch (t) {
    ServerTab.overview => s.tabOverview,
    ServerTab.players => s.tabPlayers,
    ServerTab.mods => s.tabMods,
    ServerTab.history => s.tabHistory,
    ServerTab.admin => s.tabAdmin,
  };

  Widget _tabBody(SpaceSummary? sp) {
    if (sp == null) {
      return const MsStack(gap: 12, children: [MsSkeleton.title(), MsSkeleton.text()]);
    }
    return switch (tab) {
      ServerTab.overview => ServerOverviewTab(space: sp),
      ServerTab.players => PlayersTab(space: sp),
      ServerTab.mods => ModsTab(space: sp),
      ServerTab.history => HistoryTab(space: sp),
      ServerTab.admin => ServerAdminTab(space: sp),
    };
  }
}

/// Percorso, icona, nome, #HEAD, lock e chip.
class _Heading extends StatelessWidget {
  const _Heading({required this.id, required this.space, required this.name});

  final String id;
  final SpaceSummary? space;
  final String name;

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s;
    final sv = s.server;
    final o = s.overview;
    final sp = space;
    final d = ServerDataScope.of(context);
    final usage = d.details.value?.usage;
    final w = sp?.world;
    final l = sp?.lock;
    final lock = sp == null
        ? null
        : switch (lockViewOf(sp)) {
            LockView.free => MsLock(label: o.lockFree),
            LockView.play => MsLock(
              label: o.lockPlay,
              state: MsLockState.play,
              meta: l!.info.players.isEmpty
                  ? l.name
                  : '${l.name}, ${o.online(l.info.players.length)}',
            ),
            LockView.stale => MsLock(label: o.lockStale, state: MsLockState.stale, meta: l!.name),
          };
    final chips = <Widget>[
      if (sp?.profile == Profile.generic)
        MsChip(o.genericFolder)
      else ...[
        if (w?.mcVersion != null) MsChip(o.minecraft(w!.mcVersion)),
        if (w?.loader case final lo? when lo != Loader.vanilla)
          MsChip(o.loader(loaderName(lo), w!.loaderVersion)),
        if (w?.loader == Loader.vanilla) const MsChip('vanilla'),
        if (w != null && w.mods > 0) MsChip(o.mods(w.mods)),
      ],
      if (usage != null) MsChip(sv.onHub(s.fmt.size(usage.logical))),
    ];
    final head = sp?.head;
    final title = MsStack(
      gap: 8,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MsRow(gap: 12, children: [MsText.h1(name, maxLines: 2), ?lock]),
        if (chips.isNotEmpty) MsRow(gap: 8, children: chips),
      ],
    );
    final zip = head == null
        ? null
        : MsButton(
            label: sv.zipHead(head.n),
            icon: const MsIcon(MsIcons.download),
            onPressed: () =>
                app.platform.download(app.api.zipUrl(id, n: head.n), filename: '$id-${head.n}.zip'),
          );
    return MsStack(
      gap: 16,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // percorso: il primo testo parte dal bordo del contenuto e la barra
        // ha lo stesso spazio ai due lati
        MsRow(
          gap: 8,
          children: [
            _Crumb(label: sv.crumb, onTap: () => context.go(HubRoutes.overview)),
            const MsText.small('/', tone: MsTextTone.tertiary),
            MsText.small(name, tone: MsTextTone.secondary, maxLines: 1),
          ],
        ),
        LayoutBuilder(
          builder: (context, c) {
            final narrow = designWidth(context, c.maxWidth) < 720;
            final left = Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SpaceIcon(id: id, size: 64),
                const PixelGap(16, 0),
                Expanded(child: title),
              ],
            );
            if (zip == null) return left;
            if (narrow) {
              return MsStack(
                gap: 16,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [left, zip],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: left),
                const PixelGap(16, 0),
                zip,
              ],
            );
          },
        ),
      ],
    );
  }
}

/// Voce cliccabile del percorso: testo senza cornice (il pulsante ghost
/// aggiungerebbe il suo margine interno a sinistra e a destra), sottolineato
/// al passaggio del mouse e con il contorno di focus fuori dal testo.
class _Crumb extends StatefulWidget {
  const _Crumb({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_Crumb> createState() => _CrumbState();
}

class _CrumbState extends State<_Crumb> {
  var _hover = false;
  var _focus = false;

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final g = PixelScope.of(context);
    final fg = _hover ? c.text : c.accentInk;
    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (v) => setState(() => _hover = v),
      onShowFocusHighlight: (v) => setState(() => _focus = v),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: Semantics(
          link: true,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Padding(
                // 4 sopra, 2 sotto più i 2 della sottolineatura: testo centrato
                padding: EdgeInsets.only(top: g.d(4), bottom: g.d(2)),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: _hover ? fg : const Color(0x00000000),
                        width: g.d(2),
                      ),
                    ),
                  ),
                  child: Padding(
                    padding: EdgeInsets.only(bottom: g.d(2)),
                    child: MsText.small(widget.label, color: fg, weight: 600, maxLines: 1),
                  ),
                ),
              ),
              if (_focus)
                Positioned(
                  left: -g.d(4),
                  right: -g.d(4),
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(color: c.focus, width: g.d(2)),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
