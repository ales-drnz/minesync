// Storia e disco: disco dell'hub con lo spazio per server (`/usage`),
// regole di retention con l'anteprima dal vivo (`POST /gc/preview` con le
// regole in bozza), soglia di spazio libero (vale il più alto dei due
// valori), pulizia manuale «mantieni le ultime N» con conferma.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../../../l10n/l10n.dart';
import '../../../shell/feedback.dart';
import '../../../state/hub_state.dart';
import '../../../widgets/page.dart';
import '../admin_data.dart';
import '../admin_dialogs.dart';
import '../admin_widgets.dart';

/// Generazioni tenute dalla pulizia manuale, se non si cambia.
const defaultManualKeep = 20;

class HistorySection extends StatefulWidget {
  const HistorySection({super.key, this.previewDelay = const Duration(milliseconds: 400)});

  /// Attesa dopo l'ultima modifica prima di chiedere un'anteprima.
  final Duration previewDelay;

  @override
  State<HistorySection> createState() => _HistorySectionState();
}

class _HistorySectionState extends State<HistorySection> {
  final _keep = TextEditingController(text: '$defaultManualKeep');
  String? _keepError;
  Timer? _rulesTimer;
  Timer? _keepTimer;
  (int, int, int)? _rulesAsked;
  GcPreview? _rules;
  Object? _rulesError;
  GcPreview? _manual;
  bool _cleaning = false;

  @override
  void initState() {
    super.initState();
    _askManual();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final d = AdminScope.of(context);
    if (d.settings == null) return;
    final r = (
      d.value('history', 'keepLast')! as int,
      d.value('history', 'keepHours')! as int,
      d.value('history', 'keepDays')! as int,
    );
    if (r == _rulesAsked) return;
    final first = _rulesAsked == null;
    _rulesAsked = r;
    _rulesTimer?.cancel();
    if (first) {
      _askRules(r);
    } else {
      _rulesTimer = Timer(widget.previewDelay, () => _askRules(r));
    }
  }

  @override
  void dispose() {
    _rulesTimer?.cancel();
    _keepTimer?.cancel();
    _keep.dispose();
    super.dispose();
  }

  Future<void> _askRules((int, int, int) r) async {
    final api = HubStateScope.read(context).api;
    try {
      final p = await api.gcPreview(
        history: HistorySettings(keepLast: r.$1, keepHours: r.$2, keepDays: r.$3),
      );
      if (mounted && _rulesAsked == r) {
        setState(() {
          _rules = p;
          _rulesError = null;
        });
      }
    } on Object catch (e) {
      if (mounted && _rulesAsked == r) setState(() => _rulesError = e);
    }
  }

  int? get _keepN {
    final v = int.tryParse(_keep.text.trim());
    return v == null || v < 1 || v > 10000 ? null : v;
  }

  void _keepChanged(String _) {
    final s = context.s.admin;
    setState(() => _keepError = _keepN == null ? s.rangeError(1, 10000) : null);
    _keepTimer?.cancel();
    if (_keepN != null) _keepTimer = Timer(widget.previewDelay, _askManual);
  }

  Future<void> _askManual() async {
    final n = _keepN;
    if (n == null) return;
    final api = HubStateScope.read(context).api;
    try {
      final p = await api.gcPreview(keep: n);
      if (mounted && _keepN == n) setState(() => _manual = p);
    } on Object {
      if (mounted) setState(() => _manual = null);
    }
  }

  Future<void> _clean() async {
    final n = _keepN;
    if (n == null) return;
    final s = context.s;
    final d = AdminScope.read(context);
    final p = _manual;
    final ok = await confirmAction(
      context,
      title: s.admin.gcTitle,
      danger: true,
      icon: MsIcons.trash,
      confirmLabel: s.admin.gcConfirm,
      body: MsText(s.admin.gcBody(n, p == null ? 0 : p.now - p.after, s.fmt.size(p?.bytes ?? 0))),
    );
    if (!ok || !mounted) return;
    setState(() => _cleaning = true);
    try {
      final r = await d.app.api.gc(keep: n);
      if (mounted) toast(context, s.admin.gcDone(r.generations, s.fmt.size(r.bytes)));
      unawaited(d.reloadUsage());
      unawaited(_askManual());
      if (_rulesAsked != null) unawaited(_askRules(_rulesAsked!));
    } on Object catch (e) {
      if (mounted) toastError(context, e);
    } finally {
      if (mounted) setState(() => _cleaning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s.admin;
    String gens(Object? v) => '$v';
    return SectionPanel(
      title: s.historyTitle,
      icon: MsIcons.history,
      lead: s.historyLead,
      children: [
        const _DiskRow(),
        NumberSetting(
          section: 'history',
          field: 'keepLast',
          label: s.keepLast,
          hint: s.keepLastHint,
          unit: s.unitGenerations,
          text: gens,
        ),
        NumberSetting(
          section: 'history',
          field: 'keepHours',
          label: s.keepHours,
          hint: s.keepHoursHint,
          unit: s.unitHours,
          text: (v) => s.hours(v! as int),
        ),
        NumberSetting(
          section: 'history',
          field: 'keepDays',
          label: s.keepDays,
          hint: s.keepDaysHint,
          unit: s.unitDays,
          text: (v) => s.days(v! as int),
          last: true,
        ),
        Padding(
          padding: EdgeInsets.only(
            top: PixelScope.of(context).d(4),
            bottom: PixelScope.of(context).d(18),
          ),
          child: _RulesPreview(preview: _rules, error: _rulesError),
        ),
        const _MinFreeRow(),
        _manualRow(context),
      ],
    );
  }

  Widget _manualRow(BuildContext context) {
    final s = context.s;
    final a = s.admin;
    final p = _manual;
    return SettingRow(
      label: a.manual,
      hint: a.manualHint,
      line: inputLine,
      last: true,
      child: MsStack(
        gap: 8,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MsRow(
            gap: 10,
            children: [
              MsText(a.keepN, tone: MsTextTone.secondary),
              SizedBox(
                width: PixelScope.of(context).d(112),
                child: MsTextInput(
                  controller: _keep,
                  mono: true,
                  error: _keepError != null,
                  keyboardType: TextInputType.number,
                  semanticLabel: a.keepN,
                  onChanged: _keepChanged,
                ),
              ),
              MsText(a.unitGenerations, tone: MsTextTone.secondary),
            ],
          ),
          if (_keepError != null) MsFieldError(_keepError!),
          MsRow(
            gap: 12,
            children: [
              MsButton(
                label: a.manualButton,
                icon: const MsIcon(MsIcons.trash),
                loading: _cleaning,
                onPressed: _cleaning || _keepN == null ? null : _clean,
              ),
              if (p != null)
                MsText.small(
                  p.bytes > 0 || p.now > p.after
                      ? a.wouldFree(s.fmt.size(p.bytes))
                      : a.nothingToFree,
                  tone: MsTextTone.secondary,
                ),
            ],
          ),
          MsText.small(a.defaultIs('$defaultManualKeep'), tone: MsTextTone.tertiary),
        ],
      ),
    );
  }
}

/// Disco dell'hub e spazio per server.
class _DiskRow extends StatelessWidget {
  const _DiskRow();

  @override
  Widget build(BuildContext context) {
    final d = AdminScope.of(context);
    final app = HubStateScope.of(context);
    final s = context.s;
    final a = s.admin;
    final u = d.usage;
    final disk = u?.disk ?? app.hub?.disk;
    final c = MsTheme.colorsOf(context);
    final g = PixelScope.of(context);
    Widget left = const SizedBox.shrink();
    if (disk != null) {
      final tone = diskTone(disk);
      final used = diskUsed(disk);
      left = MsStack(
        gap: 8,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MsRow(
            gap: 8,
            children: [
              MsText(a.diskCard, weight: 600),
              MsPill(
                s.fmt.percentSpaced(used),
                tone: tone == MsStatusTone.ok ? MsStatusTone.neutral : tone,
              ),
              MsText.small(switch (tone) {
                MsStatusTone.err => a.diskFull,
                MsStatusTone.warn => a.diskAlmostFull,
                _ => a.diskOk,
              }, tone: MsTextTone.secondary),
            ],
          ),
          MsProgress(
            value: used,
            semanticLabel: a.diskCard,
            tone: switch (tone) {
              MsStatusTone.err => MsProgressTone.err,
              MsStatusTone.warn => MsProgressTone.warn,
              _ => MsProgressTone.accent,
            },
          ),
          MsProgressMeta(
            start: MsText.rich([
              for (final (t, b) in a.diskFreeOf(s.fmt.size(disk.free), s.fmt.size(disk.total)))
                MsSpan(t, strong: b),
            ], kind: MsTextKind.small),
            end: MsText.small(a.diskThreshold(s.fmt.size(disk.minFree))),
          ),
          if (u != null)
            MsText.small(a.hubUses(s.fmt.size(u.blobs + u.dl)), tone: MsTextTone.secondary),
        ],
      );
    }
    final right = u == null
        ? MsText.small(
            d.usageError == null ? a.usagePending : errorText(s, d.usageError!),
            tone: MsTextTone.secondary,
          )
        : _perServer(context, u);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: c.pxShadow, width: g.d(2)),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: g.d(18)),
        child: Columns(minWidth: 260, gap: 32, children: [(1, left), (1, right)]),
      ),
    );
  }

  Widget _perServer(BuildContext context, HubUsage u) {
    final app = HubStateScope.of(context);
    final s = context.s;
    final g = PixelScope.of(context);
    final rows = [
      for (final sp in app.spaces)
        if (u.spaces[sp.id] != null) (sp.id, sp.name, u.spaces[sp.id]!.referenced),
    ]..sort((a, b) => b.$3.compareTo(a.$3));
    final top = [for (final r in rows) r.$3, u.dl].fold(1, (m, v) => v > m ? v : m);
    Widget line(String? id, String name, int bytes) => MsStack(
      gap: 4,
      children: [
        Row(
          children: [
            SizedBox(
              width: g.d(16),
              height: g.d(16),
              child: id == null ? null : MsTexture(textureFor(id), width: g.d(16), height: g.d(16)),
            ),
            const PixelGap(8, 0),
            Expanded(child: MsText(name, weight: 600, maxLines: 1)),
            MsText(s.fmt.size(bytes), kind: MsTextKind.mono, tabular: true),
          ],
        ),
        MsProgress(value: bytes / top, thin: true),
      ],
    );
    return MsStack(
      gap: 10,
      children: [
        MsText(s.admin.perServer, weight: 600),
        for (final r in rows) line(r.$1, r.$2, r.$3),
        line(null, s.admin.other, u.dl),
      ],
    );
  }
}

/// Anteprima della pulizia con le regole in bozza.
class _RulesPreview extends StatelessWidget {
  const _RulesPreview({required this.preview, required this.error});

  final GcPreview? preview;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final a = s.admin;
    final p = preview;
    final c = MsTheme.colorsOf(context);
    final g = PixelScope.of(context);
    Widget legend(Color color, String label) => MsRow(
      gap: 6,
      children: [
        SizedBox(
          width: g.d(12),
          height: g.d(12),
          child: ColoredBox(color: color),
        ),
        MsText.small(label),
      ],
    );
    return Semantics(
      liveRegion: true,
      container: true,
      child: MsSlot(
        padding: const EdgeInsets.all(16),
        child: MsStack(
          gap: 16,
          children: [
            MsRow(
              gap: 8,
              children: [
                MsText.label(a.preview),
                MsText.small(a.previewLead, tone: MsTextTone.secondary),
                legend(c.accent, a.previewKeeps),
                legend(c.text3, a.previewDrops),
              ],
            ),
            if (p == null)
              error == null
                  ? const MsSkeleton.text()
                  : MsText.small('${a.previewError}: ${errorText(s, error!)}', tone: MsTextTone.err)
            else ...[
              for (final r in p.spaces.where((r) => r.after < r.now))
                MsStack(
                  gap: 4,
                  children: [
                    MsText.small(a.previewRow(r.name, r.now, r.after), weight: 600),
                    MsProgress(
                      value: r.now == 0 ? 0 : r.after / r.now,
                      semanticLabel: a.previewRow(r.name, r.now, r.after),
                    ),
                  ],
                ),
              MsScrollX(
                child: MsTable(
                  semanticLabel: a.preview,
                  columns: [
                    MsTableColumn(a.colServer),
                    MsTableColumn(a.colNow, end: true),
                    MsTableColumn(a.colAfter, end: true),
                    MsTableColumn(a.colFreed, end: true),
                  ],
                  rows: [
                    for (final r in p.spaces)
                      [
                        MsRow(
                          gap: 8,
                          children: [
                            MsText.small(r.name, weight: 600),
                            if (r.ownRules) MsChip(a.ownRules),
                          ],
                        ),
                        MsText.small('${r.now}', tabular: true),
                        MsText.small('${r.after}', tabular: true),
                        MsText.small(
                          r.bytes == 0 ? '0' : a.approx(s.fmt.size(r.bytes)),
                          tabular: true,
                        ),
                      ],
                    [
                      MsText.small(a.total, weight: 700),
                      MsText.small('${p.now}', weight: 700, tabular: true),
                      MsText.small('${p.after}', weight: 700, tabular: true),
                      MsText.small(
                        p.bytes == 0 ? '0' : a.approx(s.fmt.size(p.bytes)),
                        weight: 700,
                        tabular: true,
                      ),
                    ],
                  ],
                ),
              ),
            ],
            MsText.small(a.previewNote, tone: MsTextTone.secondary),
          ],
        ),
      ),
    );
  }
}

/// Spazio libero minimo: GiB oppure % del disco, con il valore di oggi.
class _MinFreeRow extends StatelessWidget {
  const _MinFreeRow();

  @override
  Widget build(BuildContext context) {
    final d = AdminScope.of(context);
    final app = HubStateScope.of(context);
    final s = context.s;
    final a = s.admin;
    final disk = d.usage?.disk ?? app.hub?.disk;
    final gib = d.value('disk', 'minFreeGiB')! as int;
    final pct = d.value('disk', 'minFreePercent')! as int;
    final env = d.system?.minFreeEnv;
    String? today;
    if (disk != null) {
      final rule = DiskSettings(minFreeGiB: gib, minFreePercent: pct);
      final bytes = rule.thresholdFor(disk.total);
      final byGib = (gib << 30) >= disk.total ~/ 100 * pct;
      today = a.todayWorth(
        s.fmt.size(bytes),
        byGib ? a.ruleGiB(gib) : a.rulePercent(pct, s.fmt.size(disk.total)),
      );
    }
    final defG = d.defaultOf('disk', 'minFreeGiB')! as int;
    final defP = d.defaultOf('disk', 'minFreePercent')! as int;
    return SettingRow(
      label: a.minFree,
      hint: a.minFreeHint,
      line: inputLine,
      child: MsStack(
        gap: 8,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MsRow(
            gap: 10,
            children: [
              NumberInput(section: 'disk', field: 'minFreeGiB', semanticLabel: '${a.minFree} GiB'),
              const MsText('GiB', tone: MsTextTone.secondary),
              MsText(a.or, tone: MsTextTone.secondary),
              NumberInput(
                section: 'disk',
                field: 'minFreePercent',
                width: 80,
                semanticLabel: '${a.minFree} %',
              ),
              MsText(a.unitPercentDisk, tone: MsTextTone.secondary),
            ],
          ),
          if (today != null) MsText.small(today),
          if (env != null) MsText.small(a.minFreeEnv(s.fmt.size(env)), tone: MsTextTone.warn),
          FieldFoot(
            section: 'disk',
            field: 'minFreeGiB',
            text: (v) => a.gib(v! as int),
            defaultText: a.minFreeDefault(defG, defP),
          ),
          FieldFoot(
            section: 'disk',
            field: 'minFreePercent',
            text: (v) => a.percent(v! as int),
            defaultText: '',
          ),
        ],
      ),
    );
  }
}
