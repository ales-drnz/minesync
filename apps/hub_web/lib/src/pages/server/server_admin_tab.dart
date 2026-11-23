// Scheda Amministrazione di un server (solo admin): nome e profilo, valori
// propri o ereditati (salvataggio automatico, spegnimento, riavvii, prova
// della porta, conservazione, protezione dalle cancellazioni), esclusioni
// proprie con quelle ereditate in vista, disco e pulizia con anteprima,
// eliminazione del server (scrivendo il nome; bloccata con un lock vivo).
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../../api/hub_api.dart';
import '../../l10n/l10n.dart';
import '../../router.dart';
import '../../shell/feedback.dart';
import '../../state/hub_state.dart';
import '../../widgets/page.dart';
import 'server_data.dart';

/// Pulizia manuale predefinita: mantieni le ultime N.
const defaultGcKeep = 20;

/// Righe dei profili mostrate prima di "altre N".
const _profilePreview = 6;

class ServerAdminTab extends StatelessWidget {
  const ServerAdminTab({super.key, required this.space});
  final SpaceSummary space;

  @override
  Widget build(BuildContext context) {
    final d = ServerDataScope.of(context);
    final det = d.details.value;
    if (det == null) return LoadState(error: d.details.error, onRetry: d.reload);
    return MsStack(
      gap: 24,
      children: [
        AutoGrid(
          minWidth: 460,
          gap: 24,
          equal: true,
          children: [
            _IdentityPanel(key: ValueKey('id-${space.name}'), space: space),
            _OverridesPanel(key: ValueKey(det.overrides.toString()), details: det),
            _ExclusionsPanel(details: det),
            _DiskPanel(space: space, details: det),
          ],
        ),
        _DangerPanel(space: space, details: det),
      ],
    );
  }
}

Future<void> _patch(BuildContext context, String id, SpacePatch p, String done) async {
  final app = HubStateScope.read(context);
  final data = ServerData.of(app, id);
  try {
    final d = await app.api.updateSpace(id, p);
    data.setDetails(d);
    if (context.mounted) toast(context, done);
    await app.refreshSpaces();
  } on Object catch (e) {
    if (context.mounted) toastError(context, e);
    rethrow;
  }
}

// ------------------------------------------------------------------ identità

class _IdentityPanel extends StatefulWidget {
  const _IdentityPanel({super.key, required this.space});
  final SpaceSummary space;

  @override
  State<_IdentityPanel> createState() => _IdentityPanelState();
}

class _IdentityPanelState extends State<_IdentityPanel> {
  late final _name = TextEditingController(text: widget.space.name);
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _rename() async {
    final a = context.s.server.admin;
    final n = _name.text.trim();
    if (n.isEmpty) {
      setState(() => _error = a.nameRequired);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _patch(context, widget.space.id, SpacePatch(name: n), a.renamed(n));
    } on Object catch (e) {
      if (mounted) setState(() => _error = errorText(context.s, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final a = s.server.admin;
    final sp = widget.space;
    final changed = _name.text.trim() != sp.name && _name.text.trim().isNotEmpty;
    return MsPanel(
      title: a.identityTitle,
      child: MsStack(
        gap: 20,
        children: [
          MsField(
            label: a.name,
            help: a.nameHint,
            error: _error,
            child: MsInputGroup(
              input: MsTextInput(
                controller: _name,
                maxLength: 40,
                error: _error != null,
                semanticLabel: a.name,
                onSubmitted: (_) => _rename(),
              ),
              actions: [
                MsButton(
                  label: a.rename,
                  loading: _busy,
                  onPressed: _busy || !changed ? null : _rename,
                ),
              ],
            ),
          ),
          MsRow(
            gap: 6,
            children: [
              MsText.small(a.idLabel, tone: MsTextTone.secondary),
              MsCode(sp.id),
              if (sp.dnsName != null) MsText.small('(${sp.dnsName})', tone: MsTextTone.secondary),
            ],
          ),
          MsStack(
            gap: 6,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MsText.label(a.profile, tone: MsTextTone.secondary),
              MsRow(gap: 6, children: [MsChip(a.profileName(sp.profile)), MsChip(a.readOnly)]),
              MsText.small(a.profileHint, tone: MsTextTone.secondary),
            ],
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ sovrascritture

/// Un gruppo di campi che si eredita o si personalizza insieme.
enum _Group { autosave, autostop, crash, port, retention, protection }

class _OverridesPanel extends StatefulWidget {
  const _OverridesPanel({super.key, required this.details});
  final SpaceDetails details;

  @override
  State<_OverridesPanel> createState() => _OverridesPanelState();
}

class _OverridesPanelState extends State<_OverridesPanel> {
  final _custom = <_Group>{};
  final _c = <String, TextEditingController>{};
  late bool _autostop;
  late bool _portTest;
  final _errors = <String, String>{};
  bool _busy = false;

  SpaceDetails get det => widget.details;
  SpaceSettings get eff => det.settings ?? const SpaceSettings();
  SpaceSettings get inh => det.inherited ?? const SpaceSettings();

  Map<String, Object?> _ov(String section) =>
      (det.overrides[section] as Map<String, Object?>?) ?? const {};

  static const _fields = {
    _Group.autosave: ('sessions', ['autosaveMinutes']),
    _Group.autostop: ('sessions', ['autostop', 'autostopMinutes']),
    _Group.crash: ('sessions', ['crashRestarts']),
    _Group.port: ('sessions', ['portTest']),
    _Group.retention: ('history', ['keepLast', 'keepHours', 'keepDays']),
    _Group.protection: ('protection', ['massDeleteRatio', 'massDeleteMinFiles']),
  };

  @override
  void initState() {
    super.initState();
    for (final e in _fields.entries) {
      final ov = _ov(e.value.$1);
      if (e.value.$2.any(ov.containsKey)) _custom.add(e.key);
    }
    final ss = eff.sessions;
    final h = eff.history;
    final p = eff.protection;
    void ctl(String k, Object v) => _c[k] = TextEditingController(text: '$v');
    ctl('autosaveMinutes', ss.autosaveMinutes);
    ctl('autostopMinutes', ss.autostopMinutes);
    ctl('crashRestarts', ss.crashRestarts);
    ctl('keepLast', h.keepLast);
    ctl('keepHours', h.keepHours);
    ctl('keepDays', h.keepDays);
    ctl('massDeleteRatio', (p.massDeleteRatio * 100).round());
    ctl('massDeleteMinFiles', p.massDeleteMinFiles);
    _autostop = ss.autostop;
    _portTest = ss.portTest;
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  int? _int(String k) => int.tryParse(_c[k]!.text.trim());

  Future<void> _save() async {
    final a = context.s.server.admin;
    _errors.clear();
    final sections = <String, Map<String, Object?>>{
      'sessions': {},
      'history': {},
      'protection': {},
    };
    void put(String section, String k, Object? v) {
      if (v == null) {
        _errors[k] = a.notANumber;
      } else {
        sections[section]![k] = v;
      }
    }

    for (final g in _custom) {
      switch (g) {
        case _Group.autosave:
          put('sessions', 'autosaveMinutes', _int('autosaveMinutes'));
        case _Group.autostop:
          put('sessions', 'autostop', _autostop);
          if (_autostop) put('sessions', 'autostopMinutes', _int('autostopMinutes'));
        case _Group.crash:
          put('sessions', 'crashRestarts', _int('crashRestarts'));
        case _Group.port:
          put('sessions', 'portTest', _portTest);
        case _Group.retention:
          for (final k in ['keepLast', 'keepHours', 'keepDays']) {
            put('history', k, _int(k));
          }
        case _Group.protection:
          final pct = _int('massDeleteRatio');
          put('protection', 'massDeleteRatio', pct == null ? null : pct / 100);
          put('protection', 'massDeleteMinFiles', _int('massDeleteMinFiles'));
      }
    }
    if (_errors.isNotEmpty) {
      setState(() {});
      return;
    }
    setState(() => _busy = true);
    try {
      await _patch(context, det.summary.id, SpacePatch(overrides: sections), a.overridesSaved);
    } on ApiError catch (e) {
      final field = e.details['field'];
      if (field is String && mounted) {
        setState(() => _errors[field.split('.').last] = errorText(context.s, e));
      }
    } on Object {
      // già notificato
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _num(String k, {String? unit, double width = 72}) {
    final g = PixelScope.of(context);
    return MsRow(
      gap: 8,
      wrap: false,
      children: [
        SizedBox(
          width: g.d(width),
          child: MsTextInput(
            controller: _c[k],
            mono: true,
            error: _errors.containsKey(k),
            keyboardType: TextInputType.number,
            semanticLabel: context.s.server.admin.fieldLabel(k),
          ),
        ),
        if (unit != null) MsText(unit, tone: MsTextTone.secondary),
      ],
    );
  }

  Widget _row(_Group grp, String label, String inherited, Widget Function() custom) {
    final a = context.s.server.admin;
    final on = _custom.contains(grp);
    final errs = [for (final k in _fields[grp]!.$2) ?_errors[k]];
    return MsStack(
      gap: 8,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MsText.label(label),
        MsRow(
          gap: 12,
          children: [
            MsSegmented<bool>(
              semanticLabel: a.originOf(label),
              value: on,
              segments: [
                MsSegment(value: false, label: a.inherit),
                MsSegment(value: true, label: a.customize),
              ],
              onChanged: (v) => setState(() => v ? _custom.add(grp) : _custom.remove(grp)),
            ),
            if (!on) MsText(inherited, tone: MsTextTone.secondary),
          ],
        ),
        if (on) custom(),
        MsText.small(on ? a.globalIs(inherited) : a.fromGlobal, tone: MsTextTone.tertiary),
        for (final e in errs) MsFieldError(e),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final a = s.server.admin;
    final i = inh;
    return MsPanel(
      title: a.overridesTitle,
      foot: [
        MsButton(
          label: s.common.save,
          variant: MsButtonVariant.primary,
          loading: _busy,
          onPressed: _busy ? null : _save,
        ),
        MsText.small(a.overridesNote, tone: MsTextTone.secondary),
      ],
      child: MsStack(
        gap: 20,
        children: [
          _row(
            _Group.autosave,
            a.autosave,
            a.minutes(i.sessions.autosaveMinutes),
            () => _num('autosaveMinutes', unit: a.minutesUnit),
          ),
          _row(
            _Group.autostop,
            a.autostop,
            i.sessions.autostop ? a.autostopOn(i.sessions.autostopMinutes) : a.off,
            () => MsStack(
              gap: 8,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MsSwitch(
                  value: _autostop,
                  label: a.autostopSwitch,
                  onChanged: (v) => setState(() => _autostop = v),
                ),
                if (_autostop) _num('autostopMinutes', unit: a.autostopUnit),
              ],
            ),
          ),
          _row(
            _Group.crash,
            a.crashRestarts,
            '${i.sessions.crashRestarts}',
            () => _num('crashRestarts'),
          ),
          _row(
            _Group.port,
            a.portTest,
            i.sessions.portTest ? a.on : a.off,
            () => MsSwitch(
              value: _portTest,
              label: a.portTestSwitch,
              onChanged: (v) => setState(() => _portTest = v),
            ),
          ),
          _row(
            _Group.retention,
            a.retention,
            a.retentionValue(i.history.keepLast, i.history.keepHours, i.history.keepDays),
            () => MsStack(
              gap: 8,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _num('keepLast', unit: a.keepLastUnit),
                _num('keepHours', unit: a.keepHoursUnit),
                _num('keepDays', unit: a.keepDaysUnit),
              ],
            ),
          ),
          _row(
            _Group.protection,
            a.protection,
            a.protectionValue(
              (i.protection.massDeleteRatio * 100).round(),
              i.protection.massDeleteMinFiles,
            ),
            () => MsStack(
              gap: 8,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _num('massDeleteRatio', unit: a.ratioUnit),
                _num('massDeleteMinFiles', unit: a.minFilesUnit),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ esclusioni

class _ExclusionsPanel extends StatefulWidget {
  const _ExclusionsPanel({required this.details});
  final SpaceDetails details;

  @override
  State<_ExclusionsPanel> createState() => _ExclusionsPanelState();
}

class _ExclusionsPanelState extends State<_ExclusionsPanel> {
  final _new = TextEditingController();
  bool _busy = false;
  bool _all = false;
  String? _error;

  @override
  void dispose() {
    _new.dispose();
    super.dispose();
  }

  Future<void> _set(List<String> list, String done) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _patch(context, widget.details.summary.id, SpacePatch(exclusions: list), done);
      _new.clear();
    } on Object catch (e) {
      if (mounted) setState(() => _error = errorText(context.s, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _add() {
    final a = context.s.server.admin;
    final p = _new.text.trim();
    final own = widget.details.ownExclusions;
    if (p.isEmpty) return;
    if (own.contains(p)) {
      setState(() => _error = a.alreadyThere);
      return;
    }
    _set([...own, p], a.patternAdded(p));
  }

  @override
  Widget build(BuildContext context) {
    final a = context.s.server.admin;
    final d = widget.details;
    final profile = d.profileExclusions;
    final shownProfile = _all ? profile : profile.take(_profilePreview).toList();
    Widget line(String pattern, Widget trail, {bool dim = false}) => Row(
      children: [
        Expanded(
          child: MsText.mono(
            pattern,
            tone: dim ? MsTextTone.secondary : MsTextTone.primary,
            maxLines: 1,
          ),
        ),
        const PixelGap(8, 0),
        trail,
      ],
    );
    return MsPanel(
      title: a.exclusionsTitle,
      child: MsStack(
        gap: 12,
        children: [
          MsSlot(
            child: MsStack(
              gap: 6,
              children: [
                for (final p in systemExclusions) line(p, MsChip(a.system)),
                for (final p in shownProfile) line(p, MsChip(a.fromProfile), dim: true),
                if (profile.length > shownProfile.length)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: MsButton(
                      label: a.moreFromProfile(
                        profile.length - shownProfile.length,
                        a.profileName(d.summary.profile),
                      ),
                      size: MsButtonSize.sm,
                      variant: MsButtonVariant.ghost,
                      onPressed: () => setState(() => _all = true),
                    ),
                  ),
                for (final p in d.ownExclusions)
                  line(
                    p,
                    MsButton.icon(
                      icon: const MsIcon(MsIcons.x),
                      size: MsButtonSize.sm,
                      variant: MsButtonVariant.ghost,
                      semanticLabel: a.removePattern(p),
                      onPressed: _busy
                          ? null
                          : () => _set([
                              ...d.ownExclusions.where((x) => x != p),
                            ], a.patternRemoved(p)),
                    ),
                  ),
              ],
            ),
          ),
          MsField(
            label: a.newPattern,
            error: _error,
            child: MsInputGroup(
              input: MsTextInput(
                controller: _new,
                mono: true,
                placeholder: a.patternPlaceholder,
                semanticLabel: a.newPattern,
                error: _error != null,
                onSubmitted: (_) => _add(),
              ),
              actions: [MsButton(label: a.add, loading: _busy, onPressed: _busy ? null : _add)],
            ),
          ),
          MsText.small(a.exclusionsNote(d.summary.name), tone: MsTextTone.secondary),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ disco

class _DiskPanel extends StatefulWidget {
  const _DiskPanel({required this.space, required this.details});
  final SpaceSummary space;
  final SpaceDetails details;

  @override
  State<_DiskPanel> createState() => _DiskPanelState();
}

class _DiskPanelState extends State<_DiskPanel> {
  final _keep = TextEditingController(text: '$defaultGcKeep');
  Future<GcPreview>? _preview;
  Future<HubUsage>? _usage;
  Timer? _debounce;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final api = HubStateScope.read(context).api;
    _usage = api.usage();
    _refreshPreview();
    _keep.addListener(() {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 300), () {
        if (mounted) setState(_refreshPreview);
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _keep.dispose();
    super.dispose();
  }

  int? get _keepN {
    final n = int.tryParse(_keep.text.trim());
    return n == null || n < 1 ? null : n;
  }

  void _refreshPreview() {
    final k = _keepN;
    _preview = k == null
        ? null
        : HubStateScope.read(context).api.gcPreview(space: widget.space.id, keep: k);
  }

  Future<void> _clean(GcPreviewRow row) async {
    final s = context.s;
    final a = s.server.admin;
    final f = s.fmt;
    final keep = _keepN!;
    final ok = await showMsDialog<bool>(
      context: context,
      builder: (c) => MsDialog(
        title: a.gcTitle(widget.space.name),
        icon: const MsIcon(MsIcons.trash),
        tone: MsDialogTone.danger,
        step: a.irreversible,
        onDismiss: () => Navigator.of(c).pop(false),
        body: MsText(a.gcBody(keep, row.now - row.after, f.size(row.bytes))),
        actions: [
          MsButton(label: s.common.cancel, onPressed: () => Navigator.of(c).pop(false)),
          MsButton(
            label: a.gcConfirm,
            variant: MsButtonVariant.danger,
            onPressed: () => Navigator.of(c).pop(true),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final app = HubStateScope.read(context);
    setState(() => _busy = true);
    try {
      final r = await app.api.gc(space: widget.space.id, keep: keep);
      if (!mounted) return;
      toast(context, a.gcDone, text: a.gcDoneText(r.generations, f.size(r.bytes)));
      await Future.wait([app.refreshSpaces(), ServerData.of(app, widget.space.id).reloadDetails()]);
      if (mounted) {
        setState(() {
          _refreshPreview();
          _usage = app.api.usage();
        });
      }
    } on Object catch (e) {
      if (mounted) toastError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final a = s.server.admin;
    final f = s.fmt;
    final u = widget.details.usage;
    final g = PixelScope.of(context);
    return MsPanel(
      title: a.diskTitle,
      child: MsStack(
        gap: 16,
        children: [
          if (u == null)
            MsText.small(a.usagePending, tone: MsTextTone.secondary)
          else ...[
            MsRow(
              gap: 32,
              children: [
                MsStack(
                  gap: 2,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MsText.h2(f.size(u.logical)),
                    MsText.small(a.generations(u.generations), tone: MsTextTone.secondary),
                  ],
                ),
                MsStack(
                  gap: 2,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MsText.h2(f.size(u.referenced)),
                    MsText.small(a.reallyUsed, tone: MsTextTone.secondary),
                  ],
                ),
              ],
            ),
            FutureBuilder<HubUsage>(
              future: _usage,
              builder: (context, snap) {
                final hub = snap.data;
                if (hub == null || hub.blobs <= 0) return const SizedBox.shrink();
                final frac = (u.referenced / hub.blobs).clamp(0.0, 1.0);
                return MsStack(
                  gap: 6,
                  children: [
                    MsProgress(value: frac, semanticLabel: a.shareBar),
                    MsProgressMeta(
                      start: MsText.small(
                        a.shareOfHub(f.percentSpaced(frac)),
                        tone: MsTextTone.secondary,
                      ),
                      end: MsText.small(a.hubTotal(f.size(hub.blobs)), tone: MsTextTone.secondary),
                    ),
                  ],
                );
              },
            ),
          ],
          MsRow(
            gap: 8,
            children: [
              MsText(a.keepBefore, tone: MsTextTone.secondary),
              SizedBox(
                width: g.d(72),
                child: MsTextInput(
                  controller: _keep,
                  mono: true,
                  keyboardType: TextInputType.number,
                  error: _keepN == null,
                  semanticLabel: a.keepLabel,
                ),
              ),
              MsText(a.keepAfter, tone: MsTextTone.secondary),
            ],
          ),
          FutureBuilder<GcPreview>(
            future: _preview,
            builder: (context, snap) {
              // con un numero non valido il vecchio esito non vale più
              final row = _preview == null
                  ? null
                  : snap.data?.spaces.where((r) => r.id == widget.space.id).firstOrNull;
              final removes = row == null ? 0 : row.now - row.after;
              return MsRow(
                gap: 12,
                children: [
                  MsButton(
                    label: a.gcButton(widget.space.name),
                    icon: const MsIcon(MsIcons.trash),
                    loading: _busy,
                    onPressed: _busy || row == null || removes <= 0 ? null : () => _clean(row),
                  ),
                  MsText.small(
                    _preview == null
                        ? a.keepInvalid
                        : snap.hasError
                        ? errorText(s, snap.error!)
                        : row == null
                        ? s.common.loading
                        : removes <= 0
                        ? a.gcNothing
                        : a.gcWould(removes, f.size(row.bytes)),
                    tone: MsTextTone.secondary,
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ eliminazione

class _DangerPanel extends StatefulWidget {
  const _DangerPanel({required this.space, required this.details});
  final SpaceSummary space;
  final SpaceDetails details;

  @override
  State<_DangerPanel> createState() => _DangerPanelState();
}

class _DangerPanelState extends State<_DangerPanel> {
  bool _busy = false;

  Future<void> _delete() async {
    final s = context.s;
    final a = s.server.admin;
    final sp = widget.space;
    final ok = await confirmByName(
      context,
      title: a.deleteTitle(sp.name),
      body: MsText(a.deleteBody(sp.name)),
      name: sp.name,
      confirmLabel: a.deleteConfirm(sp.name),
      help: a.deleteHelp,
    );
    if (!ok || !mounted) return;
    final app = HubStateScope.read(context);
    final router = GoRouter.of(context);
    setState(() => _busy = true);
    try {
      await app.api.deleteSpace(sp.id);
      if (!mounted) return;
      toast(context, a.deleted(sp.name));
      router.go(HubRoutes.overview);
      await app.refreshSpaces();
    } on Object catch (e) {
      if (mounted) {
        toastError(context, e);
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s;
    final a = s.server.admin;
    final f = s.fmt;
    final sp = widget.space;
    final u = widget.details.usage;
    final l = sp.lock;
    final live = l != null && !l.stale;
    return MsPanel(
      title: a.dangerTitle,
      semanticLabel: a.dangerTitle,
      child: MsStack(
        gap: 12,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MsText(a.deleteServer, weight: 700),
          MsText.small(
            a.deleteText(sp.name, u?.generations, u == null ? null : f.size(u.logical)),
            tone: MsTextTone.secondary,
          ),
          if (live)
            MsAlert(
              tone: MsAlertTone.err,
              title: a.blockedTitle,
              text: a.blockedText(l.name, f.duration(app.now().difference(app.localTime(l.since)))),
            ),
          MsButton(
            label: a.deleteButton(sp.name),
            variant: MsButtonVariant.danger,
            icon: const MsIcon(MsIcons.trash),
            loading: _busy,
            onPressed: _busy || live ? null : _delete,
          ),
        ],
      ),
    );
  }
}
