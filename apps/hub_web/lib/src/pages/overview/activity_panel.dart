// Feed Attività dal vivo: filtri (tutto, sessioni, salvataggi, admin),
// righe con ora, badge per tipo, frase e server; "Mostra le precedenti"
// mostra quelle già in memoria e poi chiede all'hub la pagina con `before`.
import 'package:flutter/widgets.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../../l10n/l10n.dart';
import '../../shell/feedback.dart';
import '../../state/hub_state.dart';
import '../../widgets/page.dart';

/// Filtri del feed.
enum ActivityFilter { all, sessions, saves, admin }

/// I tipi di evento di ogni filtro.
bool matchesFilter(ActivityFilter f, String type) => switch (f) {
  ActivityFilter.all => true,
  ActivityFilter.sessions => const [
    EventType.lock,
    EventType.unlock,
    EventType.stale,
    EventType.force,
    EventType.port,
  ].contains(type),
  ActivityFilter.saves => const [
    EventType.push,
    EventType.restore,
    EventType.restoreFile,
    EventType.generationDelete,
  ].contains(type),
  ActivityFilter.admin => const [
    EventType.spaceCreate,
    EventType.spaceUpdate,
    EventType.spaceDelete,
    EventType.gc,
    EventType.gcError,
    EventType.disk,
    EventType.settings,
    EventType.memberRole,
    EventType.ztnet,
    EventType.telegramError,
  ].contains(type),
};

/// Colore del badge di un tipo di evento.
MsBadgeKind badgeKind(String type) => switch (type) {
  EventType.push => MsBadgeKind.push,
  EventType.lock || EventType.port => MsBadgeKind.lock,
  EventType.unlock => MsBadgeKind.stop,
  EventType.force || EventType.stale || EventType.telegramError => MsBadgeKind.force,
  EventType.restore || EventType.restoreFile => MsBadgeKind.restore,
  EventType.disk => MsBadgeKind.disk,
  EventType.gc || EventType.gcError || EventType.generationDelete => MsBadgeKind.gc,
  EventType.spaceCreate || EventType.spaceUpdate || EventType.spaceDelete => MsBadgeKind.server,
  EventType.settings || EventType.memberRole || EventType.ztnet => MsBadgeKind.settings,
  _ => MsBadgeKind.neutral,
};

/// Righe mostrate all'inizio e a ogni "Mostra le precedenti".
const activityStep = 8;

class ActivityPanel extends StatefulWidget {
  const ActivityPanel({super.key});

  @override
  State<ActivityPanel> createState() => _ActivityPanelState();
}

class _ActivityPanelState extends State<ActivityPanel> {
  var _filter = ActivityFilter.all;
  var _shown = activityStep;

  Future<void> _more(HubState app, int available) async {
    if (_shown < available) {
      setState(() => _shown += activityStep * 2);
      return;
    }
    try {
      await app.loadOlderEvents();
      if (mounted) setState(() => _shown += activityStep * 2);
    } on Object catch (e) {
      if (mounted) toastError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s;
    final o = s.overview;
    final g = PixelScope.of(context);
    final now = app.now();
    final all = [
      for (final e in app.events)
        if (matchesFilter(_filter, e.type)) e,
    ];
    final shown = all.take(_shown).toList();
    final canMore = all.length > _shown || (app.eventsMore && app.events.isNotEmpty);
    return MsPanel(
      title: o.activity,
      foot: [
        if (canMore)
          MsButton(
            label: o.showOlder,
            variant: MsButtonVariant.ghost,
            size: MsButtonSize.sm,
            icon: const MsIcon(MsIcons.history),
            loading: app.loadingOlder,
            onPressed: app.loadingOlder ? null : () => _more(app, all.length),
          ),
      ],
      child: MsStack(
        gap: 12,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // su schermi stretti i filtri scorrono invece di uscire dal pannello
          MsScrollX(
            child: MsSegmented<ActivityFilter>(
              semanticLabel: o.filterLabel,
              value: _filter,
              segments: [
                MsSegment(value: ActivityFilter.all, label: o.filterAll),
                MsSegment(value: ActivityFilter.sessions, label: o.filterSessions),
                MsSegment(value: ActivityFilter.saves, label: o.filterSaves),
                MsSegment(value: ActivityFilter.admin, label: o.filterAdmin),
              ],
              onChanged: (f) => setState(() {
                _filter = f;
                _shown = activityStep;
              }),
            ),
          ),
          if (shown.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: g.d(8)),
              child: MsText.small(o.noActivity, tone: MsTextTone.secondary),
            )
          else
            MsList(
              flat: true,
              semanticLabel: o.activityList,
              children: [for (final e in shown) _row(context, app, e, now)],
            ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, HubState app, HubEvent e, DateTime now) {
    final s = context.s;
    final g = PixelScope.of(context);
    final sp = e.space == null ? null : app.space(e.space!);
    final name = sp?.name ?? e.space;
    return MsListRow(
      lead: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: g.d(52),
            child: MsText(
              s.fmt.eventTime(app.localTime(e.ts), now),
              kind: MsTextKind.mono,
              tone: MsTextTone.secondary,
              maxLines: 1,
            ),
          ),
          MsBadge(s.events.badge(e.type), kind: badgeKind(e.type)),
        ],
      ),
      titleSpans: [for (final p in s.events.text(e, name, s.fmt)) MsSpan(p.$1, strong: p.$2)],
      // senza l'indirizzo DNS: nella colonna stretta del pannello verrebbe
      // tagliato; per intero e da copiare sta nella pagina del server
      meta: listMeta(s.events.meta(e, name)),
      // le frasi vanno a capo, come nel design (white-space: normal)
      titleMaxLines: null,
    );
  }
}
