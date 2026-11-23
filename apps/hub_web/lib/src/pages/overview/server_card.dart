// Card di un server nella Panoramica: icona del mondo (o texture), nome,
// #HEAD, versione e loader; sotto lo stato del lock con chi gioca e da
// quanto, oppure l'ultimo salvataggio, oppure il lock stale.
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../../l10n/l10n.dart';
import '../../router.dart';
import '../../state/hub_state.dart';
import '../../widgets/lock_view.dart';
import '../../widgets/page.dart';
import '../../widgets/ticking.dart';

class ServerCard extends StatelessWidget {
  const ServerCard({super.key, required this.space});
  final SpaceSummary space;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final sp = space;
    final g = PixelScope.of(context);
    return MsCard(
      semanticLabel: s.overview.openServer(sp.name),
      onTap: () => context.go(HubRoutes.server(sp.id)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SpaceIcon(id: sp.id),
              const PixelGap(16, 0),
              Expanded(
                child: MsStack(
                  gap: 4,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MsRow(gap: 8, children: [MsText.h3(sp.name, maxLines: 1)]),
                    MsMeta(worldItems(s, sp), maxLines: 1),
                  ],
                ),
              ),
            ],
          ),
          Padding(
            padding: EdgeInsets.only(top: g.d(16), bottom: g.d(12)),
            child: const MsDivider(),
          ),
          Ticking(builder: (context) => _LockPart(space: sp)),
        ],
      ),
    );
  }
}

class _LockPart extends StatelessWidget {
  const _LockPart({required this.space});
  final SpaceSummary space;

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s;
    final o = s.overview;
    final f = s.fmt;
    final sp = space;
    final l = sp.lock;
    final now = app.now();
    final head = sp.head;
    return switch (lockViewOf(sp)) {
      LockView.play => MsStack(
        gap: 8,
        children: [
          MsRow(
            gap: 8,
            children: [
              lockBadge(context, sp),
              MsText.small(o.online(l!.info.players.length), weight: 600),
            ],
          ),
          MsText.rich(
            [
              MsSpan(o.openSince),
              MsSpan(
                f.duration(now.difference(app.localTime(l.since))) +
                    (head == null ? '' : o.lastSave(f.ago(app.localTime(head.ts), now))),
                strong: true,
              ),
            ],
            kind: MsTextKind.small,
            tone: MsTextTone.secondary,
          ),
          if (l.info.players.isNotEmpty)
            MsRow(
              gap: 8,
              children: [
                MsAvatarStack(names: l.info.players, size: MsAvatarSize.small),
                MsText.small(f.names(l.info.players), tone: MsTextTone.secondary),
              ],
            ),
        ],
      ),
      LockView.stale => MsStack(
        gap: 8,
        children: [
          Align(alignment: Alignment.centerLeft, child: lockBadge(context, sp)),
          MsText.small(
            o.staleText(
              l!.name,
              l.lastBeat <= 0 ? null : f.duration(now.difference(app.localTime(l.lastBeat))),
            ),
            tone: MsTextTone.secondary,
          ),
        ],
      ),
      LockView.free => MsStack(
        gap: 8,
        children: [
          Align(alignment: Alignment.centerLeft, child: lockBadge(context, sp)),
          if (head == null)
            MsText.small(o.neverSaved, tone: MsTextTone.secondary)
          else
            MsStack(
              gap: 4,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MsText.small(o.lastSaved, tone: MsTextTone.secondary),
                MsMeta([head.author, f.when(app.localTime(head.ts), now), f.size(head.stats.size)]),
              ],
            ),
        ],
      ),
    };
  }
}
