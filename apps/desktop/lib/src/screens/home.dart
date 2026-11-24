// Home: avvisi (offline, disco dell'hub, aggiornamento), i server in card
// con lo stato del lock e l'attività dal vivo. "Nuovo server" sta nella barra
// laterale. Senza server: stato vuoto con "Crea il primo server" per gli
// admin.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../l10n/l10n.dart';
import '../state/app_state.dart';
import '../state/space_state.dart';
import 'common.dart';
import 'dialogs.dart';

/// Righe di attività mostrate senza "Tutta l'attività".
const _feedShort = 6;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(AppStateScope.read(context).probePc());
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final s = context.s.home;
    final empty = app.spaces.isEmpty && app.connection == Connection.online;
    final alerts = [
      if (app.connection == Connection.offline) const _OfflineAlert(),
      if (_hubNearlyFull(app.hub?.disk) && !empty) const _HubFullAlert(),
      if (app.deps.platform.updates.ready != null && !app.updateDismissed) const _UpdateAlert(),
    ];
    if (empty) {
      return ScreenBody(
        children: [
          ...alerts,
          const _EmptyHome(),
          Center(child: MsLive(s.connectedTo(app.hub?.name ?? '', app.latencyMs ?? 0))),
        ],
      );
    }
    return Focus(
      autofocus: true,
      child: ScreenBody(
        children: [
          ...alerts,
          MsText.h2(s.question),
          // server a sinistra e attività a destra quando c'è spazio: il
          // registro ha righe corte, a tutta larghezza lascerebbe metà vuota
          Columns(
            minWidth: 460,
            equal: false,
            children: [
              (
                2,
                AutoGrid(
                  minWidth: 360,
                  children: [
                    for (final sp in app.spaces) _ServerCard(key: ValueKey(sp.id), space: sp),
                  ],
                ),
              ),
              (3, const _ActivityPanel()),
            ],
          ),
        ],
      ),
    );
  }
}

/// Il disco dell'hub è quasi pieno: meno del 5% o meno di due volte la
/// soglia sotto cui l'hub rifiuta i salvataggi.
bool _hubNearlyFull(DiskInfo? d) =>
    d != null && d.total > 0 && (d.free < d.total ~/ 20 || d.free < d.minFree * 2);

class _OfflineAlert extends StatelessWidget {
  const _OfflineAlert();

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final s = context.s.home;
    return MsAlert(
      tone: MsAlertTone.warn,
      title: s.offlineTitle,
      text: s.offlineText(app.deps.retryEvery.inSeconds),
      actions: [
        MsButton(
          label: s.retry,
          size: MsButtonSize.sm,
          icon: const MsIcon(MsIcons.refresh),
          onPressed: app.retry,
        ),
      ],
    );
  }
}

class _HubFullAlert extends StatelessWidget {
  const _HubFullAlert();

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final s = context.s;
    final d = app.hub!.disk;
    return MsAlert(
      tone: MsAlertTone.err,
      title: s.home.hubFullTitle(s.fmt.size(d.free), s.fmt.size(d.total)),
      text: s.home.hubFullText,
      // la pulizia la fa solo un admin; gli altri leggono solo il testo
      actions: [
        if (app.me?.admin ?? false)
          MsButton(
            label: s.home.cleanup,
            size: MsButtonSize.sm,
            icon: const MsIcon(MsIcons.trash),
            onPressed: app.connection == Connection.online ? () => showGcDialog(context) : null,
          ),
      ],
    );
  }
}

class _UpdateAlert extends StatelessWidget {
  const _UpdateAlert();

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final s = context.s.home;
    final updates = app.deps.platform.updates;
    return MsAlert(
      tone: MsAlertTone.ok,
      title: s.updateTitle(updates.ready!),
      text: s.updateText,
      actions: [
        MsButton(
          label: s.later,
          variant: MsButtonVariant.ghost,
          size: MsButtonSize.sm,
          onPressed: app.dismissUpdate,
        ),
        MsButton(
          label: s.restartNow,
          variant: MsButtonVariant.primary,
          size: MsButtonSize.sm,
          // mai mentre si ospita un server: resta il chip nella barra
          onPressed: app.hosting ? null : updates.restart,
        ),
      ],
    );
  }
}

/// Card di un server: lock, chi gioca, indirizzo o pre-scarico, azioni.
class _ServerCard extends StatefulWidget {
  const _ServerCard({super.key, required this.space});
  final SpaceSummary space;

  @override
  State<_ServerCard> createState() => _ServerCardState();
}

class _ServerCardState extends State<_ServerCard> {
  @override
  void initState() {
    super.initState();
    final app = AppStateScope.read(context);
    if (app.folderOf(widget.space.id) != null) {
      app.spaceState(widget.space.id).ensureLoaded();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final ss = app.spaceState(widget.space.id);
    return ListenableBuilder(listenable: ss, builder: (context, _) => _card(context, app, ss));
  }

  Widget _card(BuildContext context, AppState app, SpaceState ss) {
    final strings = context.s;
    final s = strings.home;
    final sv = strings.server;
    final f = strings.fmt;
    final sp = widget.space;
    final now = app.now();
    final view = lockViewOf(sp, app.me);
    final l = sp.lock;
    final layout = ss.layout;
    // la copia su questo PC se c'è, altrimenti quello che l'hub sa della HEAD
    final loader = layout?.loader ?? sp.world?.loader?.name;
    final mc = layout?.mcVersion ?? sp.world?.mcVersion;
    final kind = sp.profile == Profile.generic
        ? [sv.genericFolder]
        : [
            if (loader != null) sv.loaderName(loader),
            if (mc != null) sv.minecraft(mc) else 'Minecraft',
          ];
    final last = sp.lastSession;
    // alto come il pulsante accanto (Gioca, Copia indirizzo…)
    final details = MsButton(
      label: sv.details,
      variant: MsButtonVariant.ghost,
      trailing: const MsIcon(MsIcons.chev),
      onPressed: () => app.go(ServerRoute(sp.id)),
    );
    // in gioco: giocatori e durata come etichette; altrimenti una frase
    final List<String> meta = switch (view) {
      LockView.play || LockView.mine => [
        s.playingOnline(l!.info.players.length),
        s.playingSince(f.duration(now.difference(app.localTime(l.since)))),
      ],
      LockView.stale => [
        if (l!.lastBeat > 0) s.staleMeta(f.duration(now.difference(app.localTime(l.lastBeat)))),
      ],
      LockView.free => [
        last != null
            ? s.freeMeta(last.name, f.ago(app.localTime(last.end ?? last.start), now))
            : sp.head == null
            ? s.freeNever
            : s.freeMeta(sp.head!.author, f.ago(app.localTime(sp.head!.ts), now)),
      ],
    };
    final t = ss.transfer;
    final here = app.session?.space == sp.id;
    final address = l == null ? null : joinAddress(sp);
    return MsCard(
      kind: MsCardKind.static,
      semanticLabel: sp.name,
      // i pulsanti in fondo: in una riga di card alte uguali stanno allineati
      child: MsFillColumn(
        gap: 14,
        fill: MsFill.pushLast,
        children: [
          Row(
            children: [
              // alta quanto nome ed etichette accanto (28 + 4 + 20)
              ServerTile(id: sp.id, size: 52, iconUrl: serverIconUrl(app, sp.id, sp.head?.n)),
              SizedBox(width: PixelScope.of(context).d(14)),
              Expanded(
                child: MsStack(
                  gap: 4,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MsText.h3(sp.name, maxLines: 1),
                    MsMeta([...kind, if (sp.head == null) s.stillEmpty], maxLines: 1),
                  ],
                ),
              ),
            ],
          ),
          MsRow(
            gap: 10,
            children: [
              lockBadge(context, sp),
              if (view == LockView.play || view == LockView.mine)
                MsMeta(meta)
              else
                for (final m in meta) MsText.small(m, tone: MsTextTone.secondary),
            ],
          ),
          if (view == LockView.play)
            MsRow(
              gap: 8,
              children: [
                if (l!.info.players.isNotEmpty) MsAvatarStack(names: l.info.players),
                if (address != null) ...[
                  MsText.small(s.joinOn, tone: MsTextTone.secondary),
                  MsCode(address),
                ] else
                  MsText.small(s.addressPending, tone: MsTextTone.secondary),
              ],
            ),
          if (view == LockView.mine)
            MsText.small(here ? s.youHost : s.youHostElsewhere, tone: MsTextTone.secondary),
          if (t != null && t.background)
            MsStack(
              gap: 4,
              children: [
                MsProgressMeta(
                  start: MsText.small(s.prefetch),
                  end: MsText.small(f.percent(t.fraction ?? 0), weight: 700, tabular: true),
                ),
                MsProgress(value: t.fraction ?? 0, thin: true, semanticLabel: s.prefetch),
              ],
            ),
          MsRow(
            gap: 8,
            children: switch (view) {
              LockView.free => [
                MsButton(
                  label: sv.play,
                  variant: MsButtonVariant.primary,
                  icon: const MsIcon(MsIcons.play),
                  onPressed: () => startPlay(app, sp.id),
                ),
                details,
              ],
              LockView.play => [
                if (address != null)
                  MsButton(
                    label: s.copyAddress,
                    icon: const MsIcon(MsIcons.copy),
                    onPressed: () => copyText(context, address, sv.copied),
                  ),
                details,
              ],
              // la propria sessione rimasta appesa: si riprende da qui, come
              // nella pagina del server
              LockView.stale when l!.memberId == app.me?.id => [
                MsButton(
                  label: sv.resume,
                  variant: MsButtonVariant.warn,
                  icon: const MsIcon(MsIcons.play),
                  onPressed: app.connection == Connection.online
                      ? () => startPlay(app, sp.id, force: true)
                      : null,
                ),
                details,
              ],
              LockView.stale => [
                MsButton(
                  label: s.whatToDo,
                  icon: const MsIcon(MsIcons.info),
                  onPressed: () => app.go(ServerRoute(sp.id)),
                ),
                details,
              ],
              // la sessione si apre solo se gira davvero in questa finestra
              LockView.mine => [
                if (here)
                  MsButton(
                    label: s.openSession,
                    variant: MsButtonVariant.primary,
                    icon: const MsIcon(MsIcons.terminal),
                    onPressed: () => app.go(ServerRoute(sp.id)),
                  ),
                details,
              ],
            },
          ),
        ],
      ),
    );
  }
}

class _ActivityPanel extends StatefulWidget {
  const _ActivityPanel();

  @override
  State<_ActivityPanel> createState() => _ActivityPanelState();
}

class _ActivityPanelState extends State<_ActivityPanel> {
  var _all = false;

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final strings = context.s;
    final s = strings.home;
    final now = app.now();
    final events = app.events;
    final shown = _all ? events : events.take(_feedShort).toList();
    final more = !app.olderEventsEnd && app.connection == Connection.online;
    final toggle = MsButton(
      label: _all ? s.showLess : s.showAll,
      variant: MsButtonVariant.ghost,
      size: MsButtonSize.sm,
      onPressed: () {
        setState(() => _all = !_all);
        // poche righe in memoria: si chiede subito la pagina precedente
        if (_all && more && events.length < 2 * _feedShort) {
          unawaited(app.loadOlderEvents());
        }
      },
    );
    final canToggle = events.length > _feedShort || more;
    // «Tutta l'attività» nella testa del pannello; il piede solo per l'elenco
    // completo (pagine più vecchie)
    return MsPanel(
      title: s.activity,
      padding: MsPanelPadding.none,
      actions: [if (canToggle) toggle],
      foot: [
        if (_all && app.olderEventsError != null)
          MsText.small(s.olderFailed, tone: MsTextTone.secondary),
        if (_all && more)
          MsButton(
            label: s.olderActivity,
            variant: MsButtonVariant.ghost,
            size: MsButtonSize.sm,
            icon: const MsIcon(MsIcons.history),
            loading: app.olderEventsLoading,
            onPressed: app.olderEventsLoading ? null : () => unawaited(app.loadOlderEvents()),
          ),
      ],
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: PixelScope.of(context).d(8),
          vertical: PixelScope.of(context).d(4),
        ),
        child: shown.isEmpty
            ? Padding(
                padding: EdgeInsets.all(PixelScope.of(context).d(12)),
                child: MsText.small(s.noActivity, tone: MsTextTone.secondary),
              )
            : MsList(
                flat: true,
                children: [
                  for (final e in shown)
                    MsListRow(
                      lead: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: PixelScope.of(context).d(52),
                            child: MsText(
                              strings.fmt.eventTime(app.localTime(e.ts), now),
                              kind: MsTextKind.mono,
                              tone: MsTextTone.secondary,
                              maxLines: 1,
                            ),
                          ),
                          // colonna di larghezza fissa: il testo parte sempre dallo stesso punto
                          SizedBox(
                            width: PixelScope.of(context).d(116),
                            child: MsBadge(s.eventBadge(e.type), kind: eventBadgeKind(e)),
                          ),
                        ],
                      ),
                      titleSpans: [
                        for (final p in s.eventText(
                          e.type,
                          e.actor,
                          e.space == null ? null : (app.space(e.space!)?.name ?? e.space),
                          e.data,
                          strings.fmt,
                        ))
                          MsSpan(p.$1, strong: p.$2),
                      ],
                    ),
                ],
              ),
      ),
    );
  }
}

class _EmptyHome extends StatelessWidget {
  const _EmptyHome();

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final s = context.s.home;
    final admin = app.me?.admin ?? false;
    return Padding(
      padding: EdgeInsets.only(top: PixelScope.of(context).d(24)),
      child: MsPanel(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: PixelScope.of(context).d(44)),
          child: MsStack(
            gap: 16,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              MsEmptyState(
                title: s.emptyTitle,
                text: s.emptyText,
                art: const MsArt(MsArts.emptyIsland),
                action: admin
                    ? MsButton(
                        label: s.createFirst,
                        variant: MsButtonVariant.primary,
                        size: MsButtonSize.lg,
                        icon: const MsIcon(MsIcons.plus),
                        onPressed: () => AppStateScope.read(context).go(const NewServerRoute()),
                      )
                    : null,
              ),
              MsText.small(s.notAdminHint, tone: MsTextTone.secondary, align: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
