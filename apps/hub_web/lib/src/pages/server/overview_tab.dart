// Scheda Panoramica di un server: sessione e indirizzo (lock dal vivo,
// giocatori, indirizzo fisso e IP diretto da copiare, prova della porta,
// rilascio forzato), mondo (level.dat), server (server.properties),
// statistiche delle sessioni, storia recente, regole e spazio.
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../../l10n/l10n.dart';
import '../../router.dart';
import '../../shell/feedback.dart';
import '../../state/hub_state.dart';
import '../../widgets/lock_view.dart';
import '../../widgets/page.dart';
import '../../widgets/ticking.dart';
import 'server_data.dart';

/// Porta di gioco quando chi ospita non la dichiara.
const defaultGamePort = 25565;

class ServerOverviewTab extends StatelessWidget {
  const ServerOverviewTab({super.key, required this.space});
  final SpaceSummary space;

  @override
  Widget build(BuildContext context) {
    final minecraft = space.profile == Profile.minecraft;
    return MsStack(
      gap: 24,
      children: [
        Ticking(builder: (context) => LockPanel(space: space)),
        if (minecraft)
          const AutoGrid(
            minWidth: 380,
            gap: 24,
            equal: true,
            children: [_WorldPanel(), _PropertiesPanel()],
          ),
        const _StatsPanel(),
        AutoGrid(
          minWidth: 380,
          gap: 24,
          equal: true,
          children: [
            _RecentPanel(space: space),
            _SpacePanel(space: space),
          ],
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ lock

/// Sessione e indirizzo: stato del lock con le azioni.
class LockPanel extends StatefulWidget {
  const LockPanel({super.key, required this.space});
  final SpaceSummary space;

  @override
  State<LockPanel> createState() => _LockPanelState();
}

class _LockPanelState extends State<LockPanel> {
  /// Esito di "Ripeti il test" finché il riassunto dal vivo non lo supera.
  PortCheck? _port;
  int? _portSince;
  bool _testing = false;
  bool _releasing = false;

  SpaceSummary get sp => widget.space;

  @override
  void didUpdateWidget(LockPanel old) {
    super.didUpdateWidget(old);
    // nuova sessione: l'esito locale non vale più
    if (sp.lock?.since != _portSince) _port = null;
  }

  Future<void> _retest() async {
    final app = HubStateScope.read(context);
    setState(() => _testing = true);
    try {
      final p = await app.api.portCheck(sp.id);
      if (!mounted) return;
      setState(() {
        _port = p;
        _portSince = sp.lock?.since;
      });
    } on Object catch (e) {
      if (mounted) toastError(context, e);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _release({required bool stale}) async {
    final s = context.s;
    final v = s.server;
    final l = sp.lock!;
    final bool ok;
    if (stale) {
      ok = await _confirmOnce(
        context,
        title: v.releaseStaleTitle(l.name),
        body: MsText(v.releaseStaleBody(l.name, s.fmt.gen(sp.headN))),
        confirm: v.releaseStale,
      );
    } else {
      ok = await showMsTwoStepConfirm(
        context: context,
        first: MsConfirmStep(
          title: v.forceTitle(sp.name),
          body: MsText(v.forceBody1(l.name, l.info.players.length)),
          cancelLabel: s.common.cancel,
          confirmLabel: v.forceContinue,
          step: v.step(1, 2),
          icon: const MsIcon(MsIcons.warn),
        ),
        second: MsConfirmStep(
          title: v.forceTitle2,
          body: MsText(v.forceBody2(l.name, s.fmt.gen(sp.headN))),
          cancelLabel: s.common.cancel,
          confirmLabel: v.forceRelease,
          step: v.step(2, 2),
          icon: const MsIcon(MsIcons.unlock),
        ),
      );
    }
    if (!ok || !mounted) return;
    final app = HubStateScope.read(context);
    setState(() => _releasing = true);
    try {
      await app.api.forceReleaseLock(sp.id);
      if (!mounted) return;
      toast(context, v.released(sp.name));
      await app.refreshSpaces();
    } on Object catch (e) {
      if (mounted) toastError(context, e);
    } finally {
      if (mounted) setState(() => _releasing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s;
    final v = s.server;
    final f = s.fmt;
    final view = lockViewOf(sp);
    final l = sp.lock;
    final now = app.now();
    final foot = <Widget>[
      if (view == LockView.play && app.isAdmin)
        _footRow(
          MsButton(
            label: v.forceRelease,
            variant: MsButtonVariant.danger,
            icon: const MsIcon(MsIcons.unlock),
            loading: _releasing,
            onPressed: _releasing ? null : () => _release(stale: false),
          ),
          v.forceAdminNote(l!.name),
        ),
      if (view == LockView.play && !app.isAdmin)
        _footRow(
          MsButton(
            label: v.forceRelease,
            variant: MsButtonVariant.danger,
            icon: const MsIcon(MsIcons.unlock),
            onPressed: null,
          ),
          v.forceMemberNote(l!.name),
        ),
      if (view == LockView.stale)
        _footRow(
          MsButton(
            label: v.releaseStale,
            variant: MsButtonVariant.primary,
            icon: const MsIcon(MsIcons.unlock),
            loading: _releasing,
            onPressed: _releasing ? null : () => _release(stale: true),
          ),
          v.releaseStaleNote,
        ),
    ];
    final Widget body = switch (view) {
      LockView.play => _playing(context, l!, now),
      LockView.stale => MsStack(
        gap: 16,
        children: [
          MsRow(
            gap: 12,
            children: [
              MsLock(
                label: s.overview.lockStale,
                state: MsLockState.stale,
                meta: l!.name,
                big: true,
              ),
              MsText.small(
                v.staleSince(
                  l.lastBeat <= 0 ? null : f.duration(now.difference(app.localTime(l.lastBeat))),
                ),
                tone: MsTextTone.secondary,
              ),
            ],
          ),
          MsAlert(
            tone: MsAlertTone.warn,
            title: v.staleTitle(l.name),
            text: v.staleText(
              f.gen(sp.headN),
              sp.head == null ? null : f.clock(app.localTime(sp.head!.ts)),
              l.name,
            ),
          ),
        ],
      ),
      LockView.free => MsStack(
        gap: 16,
        children: [
          MsRow(
            gap: 12,
            children: [
              MsLock(label: s.overview.lockFree, big: true),
              MsText.small(_lastSession(context, now), tone: MsTextTone.secondary),
            ],
          ),
          MsSlot(
            child: MsText.rich([
              MsSpan(v.freeHowTo1),
              MsSpan(v.play, strong: true),
              MsSpan(v.freeHowTo2(sp.dnsName)),
            ], kind: MsTextKind.small),
          ),
        ],
      ),
    };
    return MsPanel(title: v.lockTitle, semanticLabel: v.lockTitle, foot: foot, child: body);
  }

  Widget _footRow(Widget button, String note) => MsRow(
    gap: 12,
    children: [
      button,
      MsText.small(note, tone: MsTextTone.secondary),
    ],
  );

  String _lastSession(BuildContext context, DateTime now) {
    final app = HubStateScope.of(context);
    final s = context.s;
    final last = sp.lastSession;
    if (last == null) return s.server.nobodyHosts;
    final start = app.localTime(last.start);
    final end = last.end == null ? null : s.fmt.clock(app.localTime(last.end!));
    return s.server.lastSession(last.name, s.fmt.when(start, now), end);
  }

  Widget _playing(BuildContext context, LockHolder l, DateTime now) {
    final app = HubStateScope.of(context);
    final s = context.s;
    final v = s.server;
    final f = s.fmt;
    final head = sp.head;
    final players = l.info.players;
    final push = l.info.action == 'push';
    final port = l.info.port ?? defaultGamePort;
    final check = _port ?? l.portCheck;
    final ip = l.ip;
    return MsStack(
      gap: 16,
      children: [
        MsRow(
          gap: 12,
          children: [
            MsLock(
              label: push ? v.lockPush : s.overview.lockPlay,
              state: MsLockState.play,
              meta: l.name,
              big: true,
            ),
            MsText.rich(
              [
                MsSpan(push ? v.pushSince : v.sessionSince),
                MsSpan(f.duration(now.difference(app.localTime(l.since))), strong: true),
                if (head != null) MsSpan(s.overview.lastSave(f.ago(app.localTime(head.ts), now))),
              ],
              kind: MsTextKind.small,
              tone: MsTextTone.secondary,
            ),
          ],
        ),
        if (players.isNotEmpty)
          MsRow(
            gap: 8,
            children: [
              MsAvatarStack(names: players, size: MsAvatarSize.small),
              MsText.rich([
                MsSpan(v.onlineList(players.length), strong: true),
                MsSpan(' ${players.map((p) => p == l.name ? v.host(p) : p).join(', ')}'),
              ], kind: MsTextKind.small),
            ],
          ),
        if (!push && (sp.dnsName != null || ip != null))
          MsSlot(
            child: MsStack(
              gap: 12,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MsText.label(v.joinOn, tone: MsTextTone.secondary),
                if (sp.dnsName != null)
                  MsStack(
                    gap: 6,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MsText.small(v.fixedAddress, tone: MsTextTone.secondary),
                      CopyValue(value: sp.dnsName!, copyLabel: v.copyFixed, strong: true),
                    ],
                  ),
                if (sp.dnsName != null && ip != null) const MsDivider(),
                if (ip != null)
                  MsStack(
                    gap: 6,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MsText.small(v.directIp, tone: MsTextTone.secondary),
                      CopyValue(value: '$ip:$port', copyLabel: v.copyDirect),
                    ],
                  ),
              ],
            ),
          ),
        if (!push && check != null)
          MsRow(
            gap: 12,
            children: [
              MsPill(
                v.portState(check.state),
                tone: switch (check.state) {
                  PortState.reachable => MsStatusTone.ok,
                  PortState.blocked => MsStatusTone.err,
                  PortState.pending => MsStatusTone.info,
                  PortState.off => MsStatusTone.neutral,
                },
              ),
              MsText.small(
                v.portText(
                  check.state,
                  check.port ?? port,
                  check.checkedAt == null ? null : f.clock(app.localTime(check.checkedAt!)),
                ),
                tone: MsTextTone.secondary,
              ),
              if (check.state != PortState.off)
                MsButton(
                  label: v.portRetry,
                  size: MsButtonSize.sm,
                  variant: MsButtonVariant.ghost,
                  icon: const MsIcon(MsIcons.refresh),
                  loading: _testing,
                  onPressed: _testing ? null : _retest,
                ),
            ],
          ),
      ],
    );
  }
}

/// Conferma semplice (una sola domanda).
Future<bool> _confirmOnce(
  BuildContext context, {
  required String title,
  required Widget body,
  required String confirm,
}) async {
  final s = context.s.common;
  final r = await showMsDialog<bool>(
    context: context,
    builder: (c) => MsDialog(
      title: title,
      icon: const MsIcon(MsIcons.unlock),
      tone: MsDialogTone.warn,
      onDismiss: () => Navigator.of(c).pop(false),
      body: body,
      actions: [
        MsButton(label: s.cancel, onPressed: () => Navigator.of(c).pop(false)),
        MsButton(
          label: confirm,
          variant: MsButtonVariant.primary,
          onPressed: () => Navigator.of(c).pop(true),
        ),
      ],
    ),
  );
  return r ?? false;
}

// ------------------------------------------------------------------ mondo

class _WorldPanel extends StatelessWidget {
  const _WorldPanel();

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final v = s.server;
    final f = s.fmt;
    final d = ServerDataScope.of(context);
    final w = d.world.value;
    final Widget child;
    if (w == null) {
      child = LoadState(error: d.world.error, onRetry: d.reload);
    } else if (w.n == 0) {
      child = MsText.small(v.noSaveYet, tone: MsTextTone.secondary);
    } else if (w.level == null) {
      child = MsText.small(v.noLevel, tone: MsTextTone.secondary);
    } else {
      final lv = w.level!;
      final version = [
        lv.version ?? w.chip.mcVersion,
        if (w.chip.loader case final lo?) loaderName(lo),
      ].nonNulls.toList();
      child = MsFacts([
        if (lv.name != null) MsFact(v.worldName, lv.name!),
        if (version.isNotEmpty) MsFact(v.worldVersion, version.join(', '), child: MsMeta(version)),
        if (lv.difficulty != null)
          MsFact(
            v.difficulty,
            v.difficultyName(lv.difficulty!),
            child: MsText.rich(
              [
                MsSpan(v.difficultyName(lv.difficulty!), strong: true),
                if (lv.hardcore != null) MsSpan(' (${v.hardcore(lv.hardcore!)})'),
              ],
              kind: MsTextKind.small,
              strongWeight: 600,
            ),
          ),
        if (lv.gameMode != null) MsFact(v.gameMode, v.gameModeName(lv.gameMode!)),
        if (lv.day != null)
          MsFact(
            v.worldTime,
            v.dayLine(
              groupInt(s.lang, lv.day!),
              lv.timeTicks == null ? null : lv.timeTicks! ~/ 72000,
            ),
          ),
        if (lv.spawn case final p?)
          MsFact(
            v.spawn,
            'X ${p.x}, Y ${p.y}, Z ${p.z}',
            child: MsText.mono('X ${_minus(p.x)}, Y ${_minus(p.y)}, Z ${_minus(p.z)}', weight: 600),
          ),
        if (lv.seed != null)
          MsFact(
            v.seed,
            lv.seed!,
            child: CopyValue(value: lv.seed!, copyLabel: v.copySeed),
          ),
      ]);
    }
    return MsPanel(
      title: v.worldTitle,
      actions: [
        if (w != null && w.n > 0) MsText.small(v.fromLevel(f.gen(w.n)), tone: MsTextTone.secondary),
      ],
      child: child,
    );
  }

  static String _minus(int n) => n < 0 ? '−${-n}' : '$n';
}

class _PropertiesPanel extends StatelessWidget {
  const _PropertiesPanel();

  @override
  Widget build(BuildContext context) {
    final v = context.s.server;
    final d = ServerDataScope.of(context);
    final w = d.world.value;
    final p = w?.properties;
    final Widget child;
    if (w == null) {
      child = LoadState(error: d.world.error, onRetry: d.reload);
    } else if (p == null) {
      child = MsText.small(w.n == 0 ? v.noSaveYet : v.noProperties, tone: MsTextTone.secondary);
    } else {
      child = MsFacts([
        if (p.motd != null) MsFact(v.motd, p.motd!),
        if (p.maxPlayers != null) MsFact(v.maxPlayers, '${p.maxPlayers}'),
        if (p.pvp != null)
          MsFact(
            v.pvp,
            v.yesNo(p.pvp!),
            child: Align(
              alignment: Alignment.centerLeft,
              child: MsPill(v.yesNo(p.pvp!), tone: p.pvp! ? MsStatusTone.ok : MsStatusTone.neutral),
            ),
          ),
        if (p.whitelist != null)
          MsFact(
            v.whitelist,
            v.onOff(p.whitelist!),
            child: MsRow(
              gap: 8,
              children: [
                MsPill(
                  v.onOff(p.whitelist!),
                  tone: p.whitelist! ? MsStatusTone.ok : MsStatusTone.neutral,
                ),
                if (p.whitelistCount != null)
                  MsText.small(v.names(p.whitelistCount!), tone: MsTextTone.secondary),
              ],
            ),
          ),
        if (p.viewDistance != null) MsFact(v.viewDistance, v.chunks(p.viewDistance!)),
        if (p.simulationDistance != null)
          MsFact(v.simulationDistance, v.chunks(p.simulationDistance!)),
      ]);
    }
    return MsPanel(
      title: v.propsTitle,
      actions: [MsText.small(v.fromProperties, tone: MsTextTone.secondary)],
      foot: [MsText.small(v.propsNote, tone: MsTextTone.secondary)],
      child: child,
    );
  }
}

// ------------------------------------------------------------------ statistiche

class _StatsPanel extends StatelessWidget {
  const _StatsPanel();

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s;
    final v = s.server;
    final f = s.fmt;
    final d = ServerDataScope.of(context);
    final st = d.stats.value;
    if (st == null) {
      return MsPanel(
        title: v.statsTitle,
        child: LoadState(error: d.stats.error, onRetry: d.reload),
      );
    }
    if (st.sessions.isEmpty) {
      return MsPanel(
        title: v.statsTitle,
        child: MsText.small(v.noSessions, tone: MsTextTone.secondary),
      );
    }
    final now = app.now();
    int lengthOf(SessionRecord r) => (r.end ?? now.millisecondsSinceEpoch) - r.start;
    final ended = st.sessions.where((r) => r.ended != SessionEnd.ongoing).toList();
    final avg = ended.isEmpty ? null : ended.map(lengthOf).reduce((a, b) => a + b) ~/ ended.length;
    final longest = st.sessions.reduce((a, b) => lengthOf(a) >= lengthOf(b) ? a : b);
    final last = st.sessions.first;
    return MsPanel(
      title: v.statsTitle,
      semanticLabel: v.statsTitle,
      child: AutoGrid(
        minWidth: 260,
        gap: 32,
        children: [
          _Ranking(title: v.playHours, note: v.playHoursNote, entries: st.play),
          _Ranking(title: v.hostHours, note: v.hostHoursNote, entries: st.hosting),
          MsStack(
            gap: 12,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MsText.label(v.sessionsTitle, tone: MsTextTone.secondary),
              MsStat(
                value: '${st.sessions.length}',
                label: v.sessionsLabel(st.sessions.length),
                icon: const MsIcon(MsIcons.clock),
              ),
              MsFacts([
                if (avg != null) MsFact(v.average, f.duration(Duration(milliseconds: avg))),
                MsFact(
                  v.longest,
                  '${f.duration(Duration(milliseconds: lengthOf(longest)))} (${longest.name})',
                ),
                MsFact(
                  v.lastOne,
                  last.ended == SessionEnd.ongoing
                      ? v.ongoing
                      : f.when(app.localTime(last.start), now),
                ),
              ]),
              MsText.small(v.keptNote(st.kept), tone: MsTextTone.secondary),
            ],
          ),
        ],
      ),
    );
  }
}

/// Classifica: posizione, avatar, nome, ore, barra rispetto al primo.
class _Ranking extends StatelessWidget {
  const _Ranking({required this.title, required this.note, required this.entries});

  final String title;
  final String note;
  final List<RankEntry> entries;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final top = entries.isEmpty ? 1 : entries.first.ms.clamp(1, 1 << 62);
    return MsStack(
      gap: 12,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MsText.label(title, tone: MsTextTone.secondary),
        if (entries.isEmpty)
          MsText.small(s.server.noRanking, tone: MsTextTone.secondary)
        else
          for (final (i, e) in entries.take(5).indexed)
            RankRow(rank: i + 1, name: e.name, value: hoursOf(s.fmt, e.ms), fraction: e.ms / top),
        MsText.small(note, tone: MsTextTone.secondary),
      ],
    );
  }
}

/// Una riga di classifica (usata anche dai Giocatori).
class RankRow extends StatelessWidget {
  const RankRow({
    super.key,
    required this.rank,
    required this.name,
    required this.value,
    required this.fraction,
  });

  final int rank;
  final String name;
  final String value;
  final double fraction;

  @override
  Widget build(BuildContext context) => MsStack(
    gap: 6,
    children: [
      Row(
        children: [
          SizedBox(
            width: PixelScope.of(context).d(20),
            child: MsText.mono('$rank', tone: MsTextTone.tertiary),
          ),
          MsAvatar(name, size: MsAvatarSize.small),
          const PixelGap(8, 0),
          Expanded(child: MsText(name, maxLines: 1)),
          MsText.mono(value),
        ],
      ),
      MsProgress(value: fraction.clamp(0, 1).toDouble(), thin: true, semanticLabel: '$name $value'),
    ],
  );
}

// ------------------------------------------------------------------ storia

class _RecentPanel extends StatefulWidget {
  const _RecentPanel({required this.space});
  final SpaceSummary space;

  @override
  State<_RecentPanel> createState() => _RecentPanelState();
}

class _RecentPanelState extends State<_RecentPanel> {
  late Future<List<GenerationSummary>> _gens;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _gens = HubStateScope.read(context).api.generations(widget.space.id, limit: 3);
  }

  @override
  void didUpdateWidget(_RecentPanel old) {
    super.didUpdateWidget(old);
    if (old.space.headDigest != widget.space.headDigest) setState(_load);
  }

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s;
    final v = s.server;
    final h = v.history;
    void open() => context.go(HubRoutes.server(widget.space.id, ServerTab.history));
    return MsPanel(
      title: v.recentTitle,
      foot: [
        MsButton(
          label: v.allHistory,
          size: MsButtonSize.sm,
          variant: MsButtonVariant.ghost,
          icon: const MsIcon(MsIcons.history),
          onPressed: open,
        ),
      ],
      child: FutureBuilder<List<GenerationSummary>>(
        future: _gens,
        builder: (context, snap) {
          if (!snap.hasData) {
            return LoadState(error: snap.error, onRetry: () => setState(_load));
          }
          final gens = snap.data!;
          if (gens.isEmpty) return MsText.small(h.emptyTitle, tone: MsTextTone.secondary);
          final now = app.now();
          return MsList(
            semanticLabel: v.recentLabel,
            children: [
              for (final g in gens)
                MsListRow(
                  lead: MsLevel(s.fmt.gen(g.n)),
                  title: h.title(g),
                  meta: listMeta([
                    g.author,
                    s.fmt.when(app.localTime(g.ts), now),
                    s.fmt.size(g.stats.size),
                  ]),
                  trail: ChangeCounts(stats: g.stats),
                  onTap: open,
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Regole di conservazione e spazio occupato.
class _SpacePanel extends StatelessWidget {
  const _SpacePanel({required this.space});
  final SpaceSummary space;

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s;
    final v = s.server;
    final f = s.fmt;
    final d = ServerDataScope.of(context);
    final det = d.details.value;
    final disk = app.hub?.disk;
    final Widget body;
    if (det == null) {
      body = LoadState(error: d.details.error, onRetry: d.reload);
    } else {
      final rules = det.settings?.history ?? const HistorySettings();
      final global = det.inherited?.history ?? const HistorySettings();
      final own = (det.overrides['history'] as Map<String, Object?>?)?.isNotEmpty ?? false;
      final u = det.usage;
      final used = disk == null || disk.total <= 0 ? 0.0 : (disk.total - disk.free) / disk.total;
      final low = disk != null && disk.free < disk.minFree * 2;
      body = MsStack(
        gap: 20,
        children: [
          MsStack(
            gap: 8,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MsText.label(v.keepTitle, tone: MsTextTone.secondary),
              MsText.small(_sentence(v.history.rules(rules))),
              MsText.small(
                own
                    ? v.ownRules(space.name, global.keepLast, global.keepHours, global.keepDays)
                    : v.hubRules,
                tone: MsTextTone.secondary,
              ),
            ],
          ),
          if (u != null)
            MsFacts([
              MsFact(
                v.versionsKept,
                u.oldest == null
                    ? '${u.generations}'
                    : v.versionsRange(u.generations, f.gen(u.oldest!), f.gen(space.headN)),
              ),
              MsFact(v.spaceOf(space.name), f.size(u.logical)),
            ]),
          if (disk != null && disk.total > 0)
            MsStack(
              gap: 6,
              children: [
                Row(
                  children: [
                    Expanded(child: MsText.small(v.hubFree, tone: MsTextTone.secondary)),
                    MsText.mono(s.overview.diskFreeOf(f.size(disk.free), f.size(disk.total))),
                  ],
                ),
                MsProgress(
                  value: used,
                  thin: true,
                  tone: low ? MsProgressTone.warn : MsProgressTone.accent,
                  semanticLabel: v.hubDiskBar,
                ),
                MsText.small(
                  v.diskUsed(f.percentSpaced(used), f.size(disk.minFree)),
                  tone: MsTextTone.secondary,
                ),
              ],
            ),
        ],
      );
    }
    return MsPanel(
      title: v.spaceTitle,
      actions: [if (!app.isAdmin) MsChip(v.readOnly)],
      foot: [
        if (app.isAdmin)
          MsButton(
            label: v.editRules,
            size: MsButtonSize.sm,
            variant: MsButtonVariant.ghost,
            icon: const MsIcon(MsIcons.gear),
            onPressed: () => context.go(HubRoutes.server(space.id, ServerTab.admin)),
          )
        else
          MsText.small(v.adminChanges, tone: MsTextTone.secondary),
      ],
      child: body,
    );
  }
}

/// Frasi brevi in una sola frase: «Sempre le ultime 10 versioni, tutte
/// quelle delle ultime 24 ore.».
String _sentence(List<String> parts) {
  final t = parts.join(', ');
  return t.isEmpty ? t : '${t[0].toUpperCase()}${t.substring(1)}.';
}
