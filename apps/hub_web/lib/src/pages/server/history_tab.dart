// Scheda Storia: generazioni dalla più nuova (#N, messaggio o ripristino,
// HEAD, file danneggiati, autore · data · file · dimensione, +~−, barra
// della dimensione), ricerca e filtri, pagine precedenti. Azioni: zip per
// tutti; ripristina ed elimina per gli admin; differenze con la precedente
// (al più 120 file per gruppo) con i file danneggiati e "Ripristina integro".
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../../l10n/l10n.dart';
import '../../router.dart';
import '../../shell/feedback.dart';
import '../../state/hub_state.dart';
import 'server_data.dart';

/// Generazioni chieste per pagina.
const historyPageSize = 20;

enum HistoryFilter { all, saves, restores, damaged }

bool _isRegion(String p) => p.endsWith('.mca') || p.endsWith('.mcr');

class HistoryTab extends StatefulWidget {
  const HistoryTab({super.key, required this.space});
  final SpaceSummary space;

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  final _gens = <GenerationSummary>[];
  Object? _error;
  bool _loading = true;
  bool _more = false;
  bool _loadingMore = false;
  final _open = <int>{};
  final _diffs = <int, Future<GenerationChanges>>{};
  final _query = TextEditingController();
  var _filter = HistoryFilter.all;

  SpaceSummary get sp => widget.space;

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
    _reload();
  }

  @override
  void didUpdateWidget(HistoryTab old) {
    super.didUpdateWidget(old);
    if (old.space.headDigest != sp.headDigest) _reload();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final api = HubStateScope.read(context).api;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await api.generations(sp.id, limit: historyPageSize);
      if (!mounted) return;
      setState(() {
        _gens
          ..clear()
          ..addAll(page);
        _more = page.length >= historyPageSize;
        _diffs.clear();
        _loading = false;
      });
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_gens.isEmpty) return;
    final api = HubStateScope.read(context).api;
    setState(() => _loadingMore = true);
    try {
      final page = await api.generations(sp.id, before: _gens.last.n, limit: historyPageSize);
      if (!mounted) return;
      setState(() {
        _gens.addAll(page);
        _more = page.length >= historyPageSize;
      });
    } on Object catch (e) {
      if (mounted) toastError(context, e);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _toggle(int n) => setState(() {
    if (!_open.remove(n)) {
      _open.add(n);
      _diffs[n] ??= HubStateScope.read(context).api.diff(sp.id, n, limit: diffDefaultLimit);
    }
  });

  /// Dopo un'azione: rilegge la storia, il server e i dati condivisi.
  Future<void> _afterChange() async {
    final app = HubStateScope.read(context);
    final data = ServerData.of(app, sp.id);
    await Future.wait([_reload(), app.refreshSpaces(), data.reloadDetails()]);
  }

  Future<void> _restore(GenerationSummary g) async {
    final app = HubStateScope.read(context);
    final s = context.s;
    final h = s.server.history;
    final ok = await showMsDialog<bool>(
      context: context,
      builder: (c) => _RestoreDialog(space: sp, gen: g, next: sp.headN + 1),
    );
    if (ok != true || !mounted) return;
    try {
      final r = await app.api.restore(sp.id, g.n);
      if (!mounted) return;
      toast(context, h.restored(s.fmt.gen(g.n), s.fmt.gen(r.n)));
      await _afterChange();
    } on Object catch (e) {
      if (mounted) toastError(context, e);
    }
  }

  Future<void> _delete(GenerationSummary g) async {
    final app = HubStateScope.read(context);
    final s = context.s;
    final h = s.server.history;
    final ok = await showMsDialog<bool>(
      context: context,
      builder: (c) => _DeleteDialog(space: sp, gen: g),
    );
    if (ok != true || !mounted) return;
    try {
      final r = await app.api.deleteGeneration(sp.id, g.n);
      if (!mounted) return;
      toast(context, h.deleted(s.fmt.gen(g.n)), text: h.freedText(s.fmt.size(r.bytes)));
      setState(() {
        _gens.removeWhere((x) => x.n == g.n);
        _open.remove(g.n);
      });
      await _afterChange();
    } on Object catch (e) {
      if (mounted) toastError(context, e);
    }
  }

  Future<void> _restoreFile(GenerationSummary g, DamagedReport d) async {
    final app = HubStateScope.read(context);
    final s = context.s;
    final h = s.server.history;
    final ok = await showMsDialog<bool>(
      context: context,
      builder: (c) => _RestoreFileDialog(space: sp, report: d),
    );
    if (ok != true || !mounted) return;
    try {
      final r = await app.api.restoreFile(
        sp.id,
        RestoreFileRequest(path: d.file.path, from: d.lastIntact ?? 0),
      );
      if (!mounted) return;
      toast(context, h.fileRestored(d.file.path), text: h.newGen(s.fmt.gen(r.n)));
      await _afterChange();
    } on Object catch (e) {
      if (mounted) toastError(context, e);
    }
  }

  bool _keep(GenerationSummary g, String q) {
    final ok = switch (_filter) {
      HistoryFilter.all => true,
      HistoryFilter.saves => g.kind != GenerationKind.restore,
      HistoryFilter.restores => g.kind == GenerationKind.restore,
      HistoryFilter.damaged => g.damaged.isNotEmpty,
    };
    if (!ok) return false;
    if (q.isEmpty) return true;
    final n = q.startsWith('#') ? q.substring(1) : q;
    return '${g.n}' == n ||
        g.message.toLowerCase().contains(q) ||
        g.author.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s;
    final h = s.server.history;
    final f = s.fmt;
    final det = ServerDataScope.of(context).details.value;
    if (_loading && _gens.isEmpty) return LoadState(error: null, onRetry: _reload);
    if (_error != null && _gens.isEmpty) return LoadState(error: _error, onRetry: _reload);
    if (_gens.isEmpty) {
      return MsPanel(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: PixelScope.of(context).d(24)),
          child: MsEmptyState(
            title: h.emptyTitle,
            text: h.emptyText,
            art: const MsIcon(MsIcons.history, size: 32),
          ),
        ),
      );
    }
    final usage = det?.usage;
    final total = usage?.generations ?? _gens.length;
    final q = _query.text.trim().toLowerCase();
    final shown = _gens.where((g) => _keep(g, q)).toList();
    final biggest = _gens.map((g) => g.stats.size).fold(1, (a, b) => a > b ? a : b);
    final rules = det?.settings?.history;
    final remaining = usage == null ? null : (usage.generations - _gens.length).clamp(0, 1 << 30);
    return MsStack(
      gap: 20,
      children: [
        MsStack(
          gap: 16,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MsStack(
              gap: 4,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MsText.h2(h.count(total)),
                if (usage != null)
                  MsText(
                    h.lead(f.size(usage.logical), f.size(usage.referenced)),
                    tone: MsTextTone.secondary,
                  ),
              ],
            ),
            MsRow(
              gap: 12,
              children: [
                SizedBox(
                  width: PixelScope.of(context).d(260),
                  child: MsTextInput(
                    controller: _query,
                    placeholder: h.search,
                    semanticLabel: h.searchLabel,
                  ),
                ),
                MsScrollX(
                  child: MsSegmented<HistoryFilter>(
                    semanticLabel: h.filterLabel,
                    value: _filter,
                    segments: [
                      for (final k in HistoryFilter.values)
                        MsSegment(
                          value: k,
                          label: switch (k) {
                            HistoryFilter.all => h.filterAll,
                            HistoryFilter.saves => h.filterSaves,
                            HistoryFilter.restores => h.filterRestores,
                            HistoryFilter.damaged => h.filterDamaged,
                          },
                        ),
                    ],
                    onChanged: (k) => setState(() => _filter = k),
                  ),
                ),
              ],
            ),
          ],
        ),
        if (rules != null)
          MsSlot(
            child: MsRow(
              gap: 12,
              children: [
                MsText.small(h.retention(rules)),
                if (app.isAdmin)
                  MsButton(
                    label: h.changeRules,
                    size: MsButtonSize.sm,
                    variant: MsButtonVariant.ghost,
                    onPressed: () => context.go(HubRoutes.server(sp.id, ServerTab.admin)),
                  ),
              ],
            ),
          ),
        if (shown.isEmpty)
          MsText(s.server.noMatch, tone: MsTextTone.secondary)
        else
          Semantics(
            label: h.listLabel(sp.name),
            container: true,
            child: MsStack(
              gap: 12,
              children: [
                for (final g in shown)
                  _GenerationRow(
                    key: ValueKey(g.n),
                    space: sp,
                    gen: g,
                    head: g.n == sp.headN,
                    fraction: g.stats.size / biggest,
                    open: _open.contains(g.n),
                    diff: _diffs[g.n],
                    onToggle: () => _toggle(g.n),
                    onRestore: () => _restore(g),
                    onDelete: () => _delete(g),
                    onRestoreFile: (d) => _restoreFile(g, d),
                  ),
              ],
            ),
          ),
        if (_more)
          Align(
            alignment: Alignment.centerLeft,
            child: MsButton(
              label: h.loadMore(remaining),
              variant: MsButtonVariant.ghost,
              loading: _loadingMore,
              onPressed: _loadingMore ? null : _loadMore,
            ),
          ),
      ],
    );
  }
}

class _GenerationRow extends StatelessWidget {
  const _GenerationRow({
    super.key,
    required this.space,
    required this.gen,
    required this.head,
    required this.fraction,
    required this.open,
    required this.diff,
    required this.onToggle,
    required this.onRestore,
    required this.onDelete,
    required this.onRestoreFile,
  });

  final SpaceSummary space;
  final GenerationSummary gen;
  final bool head;
  final double fraction;
  final bool open;
  final Future<GenerationChanges>? diff;
  final VoidCallback onToggle;
  final VoidCallback onRestore;
  final VoidCallback onDelete;
  final void Function(DamagedReport) onRestoreFile;

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s;
    final h = s.server.history;
    final f = s.fmt;
    final g = gen;
    final n = f.gen(g.n);
    final damaged = g.damaged.length;
    final regions = g.damaged.every((d) => _isRegion(d.path));
    final main = MsStack(
      gap: 4,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MsRow(
          gap: 8,
          children: [
            MsText(h.title(g), weight: 700),
            // come nell'app: «Attuale», non il termine tecnico
            if (head) MsPill(h.current, tone: MsStatusTone.ok),
            if (g.restoredFrom != null)
              MsChip(
                g.restoredPath == null
                    ? h.restoreOf(f.gen(g.restoredFrom!))
                    : h.fileRestoreOf(g.restoredPath!, f.gen(g.restoredFrom!)),
              ),
            if (damaged > 0) MsPill(h.damagedCount(damaged, regions), tone: MsStatusTone.warn),
          ],
        ),
        MsMeta([
          g.author,
          f.when(app.localTime(g.ts), app.now()),
          h.files(groupInt(s.lang, g.stats.files)),
          f.size(g.stats.size),
        ]),
      ],
    );
    final changes = SizedBox(
      width: PixelScope.of(context).d(120),
      child: MsStack(
        gap: 6,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ChangeCounts(stats: g.stats),
          MsProgress(value: fraction.clamp(0, 1).toDouble(), thin: true, semanticLabel: h.sizeBar),
        ],
      ),
    );
    MsRow actionsRow({required bool wrap}) => MsRow(
      gap: 6,
      wrap: wrap,
      children: [
        MsButton(
          label: h.zip,
          size: MsButtonSize.sm,
          icon: const MsIcon(MsIcons.download),
          semanticLabel: h.zipOf(n),
          onPressed: () => app.platform.download(
            app.api.zipUrl(space.id, n: g.n),
            filename: '${space.id}-${g.n}.zip',
          ),
        ),
        if (app.isAdmin && !head)
          MsButton(
            label: h.restore,
            size: MsButtonSize.sm,
            icon: const MsIcon(MsIcons.history),
            semanticLabel: h.restoreLabel(n),
            onPressed: onRestore,
          ),
        if (app.isAdmin && !head)
          MsButton.icon(
            icon: const MsIcon(MsIcons.trash),
            size: MsButtonSize.sm,
            variant: MsButtonVariant.ghost,
            semanticLabel: h.deleteLabel(n),
            onPressed: onDelete,
          ),
        MsButton.icon(
          icon: const MsIcon(MsIcons.chevDown),
          size: MsButtonSize.sm,
          semanticLabel: open ? h.hideDiff(n) : h.showDiff(n),
          onPressed: onToggle,
        ),
      ],
    );
    return MsPanel(
      semanticLabel: h.rowLabel(n),
      child: MsStack(
        gap: 16,
        children: [
          LayoutBuilder(
            builder: (context, c) {
              final narrow = c.maxWidth < PixelScope.of(context).d(720);
              final level = MsLevel(n);
              if (narrow) {
                return MsStack(
                  gap: 12,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [level, main, changes, actionsRow(wrap: true)],
                );
              }
              return Row(
                children: [
                  level,
                  const PixelGap(16, 0),
                  Expanded(child: main),
                  const PixelGap(16, 0),
                  changes,
                  const PixelGap(16, 0),
                  // larghezza fissa: i conteggi restano in colonna
                  SizedBox(
                    width: PixelScope.of(context).d(app.isAdmin ? 340 : 150),
                    child: Align(alignment: Alignment.centerRight, child: actionsRow(wrap: false)),
                  ),
                ],
              );
            },
          ),
          if (open && diff != null) _DiffView(gen: g, diff: diff!, onRestoreFile: onRestoreFile),
        ],
      ),
    );
  }
}

class _DiffView extends StatelessWidget {
  const _DiffView({required this.gen, required this.diff, required this.onRestoreFile});

  final GenerationSummary gen;
  final Future<GenerationChanges> diff;
  final void Function(DamagedReport) onRestoreFile;

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s;
    final h = s.server.history;
    final f = s.fmt;
    return FutureBuilder<GenerationChanges>(
      future: diff,
      builder: (context, snap) {
        if (snap.hasError) {
          return MsAlert(
            tone: MsAlertTone.err,
            title: h.diffError,
            text: errorText(s, snap.error!),
          );
        }
        if (!snap.hasData) return const MsSkeleton.text();
        final d = snap.data!;
        Widget section(String title, MsTextTone tone, String sign, DiffSection sec, String none) {
          return MsStack(
            gap: 8,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MsText.rich(
                [MsSpan('$title '), MsSpan(groupInt(s.lang, sec.total), strong: true)],
                kind: MsTextKind.label,
                tone: tone,
              ),
              MsSlot(
                child: sec.items.isEmpty
                    ? MsText.small(none, tone: MsTextTone.secondary)
                    : MsStack(
                        gap: 4,
                        children: [
                          for (final e in sec.items)
                            Row(
                              children: [
                                MsText.mono(sign, tone: tone),
                                const PixelGap(8, 0),
                                Expanded(child: MsText.mono(e.path, maxLines: 1)),
                                const PixelGap(8, 0),
                                MsText.mono(
                                  e.prevSize == null
                                      ? f.size(e.size)
                                      : '${f.size(e.prevSize!)} → ${f.size(e.size)}',
                                  tone: MsTextTone.secondary,
                                ),
                              ],
                            ),
                        ],
                      ),
              ),
              MsText.small(
                sec.truncated
                    ? h.shownOf(groupInt(s.lang, sec.items.length), groupInt(s.lang, sec.total))
                    : h.allShown,
                tone: MsTextTone.secondary,
              ),
            ],
          );
        }

        return MsStack(
          gap: 16,
          children: [
            const MsDivider(),
            MsRow(
              gap: 12,
              children: [
                MsText.label(
                  d.parent == 0 ? h.diffWithEmpty : h.diffWith(f.gen(d.parent)),
                  tone: MsTextTone.secondary,
                ),
                MsText.small(h.diffLimit(diffDefaultLimit), tone: MsTextTone.secondary),
              ],
            ),
            LayoutBuilder(
              builder: (context, c) {
                final cols = [
                  section(h.added, MsTextTone.ok, '+', d.added, h.noneAdded),
                  section(h.changed, MsTextTone.warn, '~', d.changed, h.noneChanged),
                  section(h.removed, MsTextTone.err, '−', d.removed, h.noneRemoved),
                ];
                final g = PixelScope.of(context);
                if (c.maxWidth < g.d(3 * 260 + 2 * 20)) return MsStack(gap: 20, children: cols);
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: g.d(20),
                  children: [for (final x in cols) Expanded(child: x)],
                );
              },
            ),
            if (d.damaged.isNotEmpty)
              MsStack(
                gap: 12,
                children: [
                  MsAlert(
                    tone: MsAlertTone.warn,
                    title: h.damagedTitle(d.damaged.length),
                    text: h.damagedText,
                  ),
                  MsScrollX(
                    child: MsTable(
                      semanticLabel: h.damagedTitle(d.damaged.length),
                      columns: [
                        MsTableColumn(h.colFile),
                        MsTableColumn(h.colChunks),
                        MsTableColumn(h.colIntact),
                        MsTableColumn(h.colAction, end: true),
                      ],
                      rows: [
                        for (final r in d.damaged)
                          [
                            MsText.mono(r.file.path),
                            MsText.small(
                              r.file.bad == null
                                  ? '—'
                                  : r.file.total == null
                                  ? groupInt(s.lang, r.file.bad!)
                                  : h.chunksOf(
                                      groupInt(s.lang, r.file.bad!),
                                      groupInt(s.lang, r.file.total!),
                                    ),
                            ),
                            r.lastIntact == null
                                ? MsText.small(h.noIntact, tone: MsTextTone.secondary)
                                : MsLevel(f.gen(r.lastIntact!)),
                            if (!app.isAdmin)
                              MsText.small(h.needsAdmin, tone: MsTextTone.secondary)
                            else
                              MsButton(
                                label: h.restoreIntact,
                                size: MsButtonSize.sm,
                                semanticLabel: r.lastIntact == null
                                    ? h.restoreIntact
                                    : h.restoreIntactLabel(r.file.path, f.gen(r.lastIntact!)),
                                onPressed: r.lastIntact == null ? null : () => onRestoreFile(r),
                              ),
                          ],
                      ],
                    ),
                  ),
                ],
              ),
          ],
        );
      },
    );
  }
}

/// Avviso "ora non si può" quando qualcuno ha il lock vivo.
Widget? _lockedAlert(BuildContext context, SpaceSummary sp, String what) {
  final l = sp.lock;
  if (l == null || l.stale) return null;
  final h = context.s.server.history;
  return MsAlert(
    tone: MsAlertTone.err,
    title: h.notNowTitle,
    text: h.notNowText(l.name, sp.name, what),
  );
}

class _RestoreDialog extends StatelessWidget {
  const _RestoreDialog({required this.space, required this.gen, required this.next});

  final SpaceSummary space;
  final GenerationSummary gen;
  final int next;

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s;
    final h = s.server.history;
    final f = s.fmt;
    final g = gen;
    final blocked = _lockedAlert(context, space, h.restoreWhat);
    final between = space.headN > g.n + 1
        ? h.rangeKept(f.gen(g.n + 1), f.gen(space.headN))
        : h.oneKept(f.gen(space.headN));
    return MsDialog(
      title: h.restoreTitle(f.gen(g.n)),
      icon: const MsIcon(MsIcons.history),
      onDismiss: () => Navigator.of(context).pop(false),
      body: MsStack(
        gap: 16,
        children: [
          MsText.rich([
            MsSpan(h.restoreBody1),
            MsSpan(h.title(g), strong: true),
            MsSpan(h.restoreBody2(g.author, f.when(app.localTime(g.ts), app.now()))),
            MsSpan(f.gen(next), strong: true),
            MsSpan(h.restoreBody3(between)),
          ]),
          MsFacts([MsFact(h.nextPlayer, h.startsFrom(f.gen(next)))]),
          ?blocked,
        ],
      ),
      actions: [
        MsButton(label: s.common.cancel, onPressed: () => Navigator.of(context).pop(false)),
        MsButton(
          label: h.restore,
          variant: MsButtonVariant.primary,
          onPressed: blocked != null ? null : () => Navigator.of(context).pop(true),
        ),
      ],
    );
  }
}

class _DeleteDialog extends StatefulWidget {
  const _DeleteDialog({required this.space, required this.gen});

  final SpaceSummary space;
  final GenerationSummary gen;

  @override
  State<_DeleteDialog> createState() => _DeleteDialogState();
}

class _DeleteDialogState extends State<_DeleteDialog> {
  late final Future<int> _freed;

  @override
  void initState() {
    super.initState();
    _freed = HubStateScope.read(context).api.freed(widget.space.id, widget.gen.n);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final h = s.server.history;
    final f = s.fmt;
    final g = widget.gen;
    final n = f.gen(g.n);
    return MsDialog(
      title: h.deleteTitle(n),
      icon: const MsIcon(MsIcons.trash),
      tone: MsDialogTone.danger,
      step: h.irreversible,
      onDismiss: () => Navigator.of(context).pop(false),
      body: FutureBuilder<int>(
        future: _freed,
        builder: (context, snap) => MsText.rich([
          MsSpan(h.deleteBody1),
          MsSpan('$n (${h.title(g)})', strong: true),
          MsSpan(h.deleteBody2(g.author)),
          MsSpan(snap.hasData ? f.size(snap.data!) : (snap.hasError ? '?' : '…'), strong: true),
          const MsSpan('.'),
        ]),
      ),
      actions: [
        MsButton(label: s.common.cancel, onPressed: () => Navigator.of(context).pop(false)),
        MsButton(
          label: h.deleteConfirm(n),
          variant: MsButtonVariant.danger,
          icon: const MsIcon(MsIcons.trash),
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
  }
}

class _RestoreFileDialog extends StatelessWidget {
  const _RestoreFileDialog({required this.space, required this.report});

  final SpaceSummary space;
  final DamagedReport report;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final h = s.server.history;
    final f = s.fmt;
    final from = f.gen(report.lastIntact!);
    final blocked = _lockedAlert(context, space, h.restoreFileWhat);
    return MsDialog(
      title: h.restoreFileTitle,
      icon: const MsIcon(MsIcons.warn),
      onDismiss: () => Navigator.of(context).pop(false),
      body: MsStack(
        gap: 16,
        children: [
          MsText.mono(report.file.path, weight: 600),
          MsText(h.restoreFileBody(from, f.gen(space.headN), f.gen(space.headN + 1))),
          ?blocked,
        ],
      ),
      actions: [
        MsButton(label: s.common.cancel, onPressed: () => Navigator.of(context).pop(false)),
        MsButton(
          label: h.restoreFileConfirm,
          variant: MsButtonVariant.primary,
          onPressed: blocked != null ? null : () => Navigator.of(context).pop(true),
        ),
      ],
    );
  }
}
