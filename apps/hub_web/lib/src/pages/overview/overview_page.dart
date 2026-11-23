// Panoramica (`/`): intestazione con "Nuovo server" (admin), avviso disco
// dell'hub quasi pieno, riepilogo (server, aperti ora, giocatori ora,
// disco), card dei server e feed Attività dal vivo.
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../../l10n/l10n.dart';
import '../../router.dart';
import '../../state/hub_state.dart';
import '../../widgets/lock_view.dart';
import '../../widgets/page.dart';
import 'activity_panel.dart';
import 'new_server_dialog.dart';
import 'server_card.dart';

/// Disco quasi pieno: meno del 10 % libero o meno di due volte la soglia
/// sotto cui l'hub rifiuta i salvataggi (come l'evento `disk`).
bool hubDiskLow(DiskInfo? d) =>
    d != null && d.total > 0 && (d.free < d.total ~/ 10 || d.free < d.minFree * 2);

class OverviewPage extends StatelessWidget {
  const OverviewPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s;
    final o = s.overview;
    final hub = app.hub;
    final g = PixelScope.of(context);
    final empty = app.spacesLoaded && app.spaces.isEmpty;
    final worlds = MsStack(
      gap: 12,
      children: [
        MsText.label(o.worlds, tone: MsTextTone.secondary),
        if (empty)
          const _EmptyWorlds()
        else
          AutoGrid(
            // card della stessa riga alte uguali, anche il riquadro «Nuovo server»
            equal: true,
            children: [
              for (final sp in app.spaces) ServerCard(key: ValueKey(sp.id), space: sp),
              if (app.isAdmin)
                MsCard.add(
                  label: o.newServer,
                  icon: const MsIcon(MsIcons.plus),
                  semanticLabel: o.newServer,
                  onTap: () => showNewServerDialog(context),
                ),
            ],
          ),
      ],
    );
    return PageBody(
      title: o.pageTitle,
      children: [
        LayoutBuilder(
          builder: (context, c) {
            final heading = MsStack(
              gap: 4,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (hub != null)
                  MsEyebrow(hub.dnsZone == null ? hub.name : '${hub.name} (${hub.dnsZone})'),
                MsText.h1(o.title),
              ],
            );
            final add = MsButton(
              label: o.newServer,
              variant: MsButtonVariant.primary,
              icon: const MsIcon(MsIcons.plus),
              onPressed: () => showNewServerDialog(context),
            );
            // come ms-row con flex 1 1 320px: il pulsante va sotto se non c'è posto
            if (!app.isAdmin || designWidth(context, c.maxWidth) < 560) {
              return MsStack(
                gap: 16,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [heading, if (app.isAdmin) add],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(child: heading),
                const PixelGap(16, 0),
                add,
              ],
            );
          },
        ),
        if (hubDiskLow(hub?.disk)) _DiskAlert(disk: hub!.disk),
        if (hub != null) const _Stats(),
        LayoutBuilder(
          builder: (context, c) {
            // come flex 999 1 560px / 1 1 360px: affiancati se c'è posto
            if (designWidth(context, c.maxWidth) < 560 + 24 + 360) {
              return MsStack(gap: 24, children: [worlds, const ActivityPanel()]);
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: worlds),
                SizedBox(width: g.d(24)),
                SizedBox(width: g.d(400), child: const ActivityPanel()),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _DiskAlert extends StatelessWidget {
  const _DiskAlert({required this.disk});
  final DiskInfo disk;

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s;
    final o = s.overview;
    final f = s.fmt;
    final text = o.diskText(
      f.size(disk.free),
      f.size(disk.total),
      f.percentSpaced(disk.free / disk.total),
      f.size(disk.minFree),
    );
    return MsAlert(
      tone: MsAlertTone.warn,
      title: o.diskTitle,
      text: app.isAdmin ? text : '$text ${o.diskMemberNote}',
      actions: [
        if (app.isAdmin)
          MsButton(
            label: o.diskAction,
            size: MsButtonSize.sm,
            icon: const MsIcon(MsIcons.disk),
            onPressed: () => context.go(HubRoutes.adminSection(AdminSection.history)),
          ),
      ],
    );
  }
}

class _Stats extends StatelessWidget {
  const _Stats();

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s;
    final o = s.overview;
    final f = s.fmt;
    final g = PixelScope.of(context);
    final disk = app.hub!.disk;
    final open = app.spaces.where(isOpenNow).toList();
    final players = {for (final sp in open) ...sp.lock!.info.players}.toList();
    final used = disk.total <= 0 ? 0.0 : (disk.total - disk.free) / disk.total;
    Widget withDetail(Widget stat, List<Widget> detail) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        stat,
        if (detail.isNotEmpty)
          Padding(
            // slot dell'icona di 56 px più lo spazio di 16 di MsStat
            padding: EdgeInsets.only(left: g.d(56 + 16), top: g.d(4)),
            child: MsStack(gap: 6, children: detail),
          ),
      ],
    );
    return MsPanel(
      semanticLabel: o.statsLabel,
      child: AutoGrid(
        minWidth: 200,
        gap: 24,
        children: [
          MsStat(
            value: '${app.spaces.length}',
            label: o.statServers,
            icon: const MsIcon(MsIcons.server),
          ),
          MsStat(
            value: '${open.length}',
            label: o.statOpen,
            icon: const MsIcon(MsIcons.play),
            iconTone: MsTextTone.info,
          ),
          withDetail(
            MsStat(
              value: '${players.length}',
              label: o.statPlayers,
              icon: const MsIcon(MsIcons.players),
              iconTone: MsTextTone.ok,
            ),
            [if (players.isNotEmpty) MsText.small(f.names(players), tone: MsTextTone.secondary)],
          ),
          withDetail(
            MsStat(
              value: f.percentSpaced(used),
              label: o.statDisk,
              icon: const MsIcon(MsIcons.disk),
              iconTone: hubDiskLow(disk) ? MsTextTone.warn : MsTextTone.accent,
            ),
            [
              MsProgress(
                value: used,
                thin: true,
                tone: hubDiskLow(disk) ? MsProgressTone.warn : MsProgressTone.accent,
                semanticLabel: o.statDiskBar,
              ),
              MsText.small(
                o.diskFreeOf(f.size(disk.free), f.size(disk.total)),
                tone: MsTextTone.secondary,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyWorlds extends StatelessWidget {
  const _EmptyWorlds();

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final o = context.s.overview;
    return MsPanel(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: PixelScope.of(context).d(32)),
        child: MsEmptyState(
          title: o.emptyTitle,
          text: app.isAdmin ? o.emptyAdmin : o.emptyMember,
          art: const MsArt(MsArts.emptyIsland),
          action: app.isAdmin
              ? MsButton(
                  label: o.newServer,
                  variant: MsButtonVariant.primary,
                  size: MsButtonSize.lg,
                  icon: const MsIcon(MsIcons.plus),
                  onPressed: () => showNewServerDialog(context),
                )
              : null,
        ),
      ),
    );
  }
}
