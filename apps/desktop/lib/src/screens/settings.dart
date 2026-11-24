// Impostazioni (canvas "AppSettings"): preferenze dell'app su questo PC
// (lingua, tema, stile, dimensione, animazioni, avvio con il sistema, area
// di notifica, notifiche), limite di banda e informazioni. Le preferenze di
// un server (cartella, Java, memoria, spegnimento) sono nella sua pagina.
// Le modifiche si salvano da sole.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:ms_l10n/ms_l10n.dart' show parseLang;
import 'package:ms_ui/ms_ui.dart';

import '../app.dart';
import '../l10n/l10n.dart';
import '../state/app_state.dart';
import 'common.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

/// Una riga delle impostazioni: etichetta, spiegazione e controllo. Le
/// parole servono alla ricerca.
final class _Item {
  const _Item(this.label, this.control, {this.hint, this.below = false});
  final String label;
  final String? hint;
  final Widget control;

  /// Controllo sotto il testo (elenchi, gruppi di caselle).
  final bool below;

  bool matches(String q) =>
      q.isEmpty || label.toLowerCase().contains(q) || (hint?.toLowerCase().contains(q) ?? false);
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'settings search');
  final _keys = List.generate(3, (_) => GlobalKey());
  int _section = 0;
  bool? _autostart;
  late final _kib = TextEditingController();
  final _scroll = ScrollController();

  /// Durante lo scorrimento animato verso una sezione la voce attiva non
  /// segue lo scorrimento (resta quella cliccata).
  bool _jumping = false;

  @override
  void initState() {
    super.initState();
    final app = AppStateScope.read(context);
    unawaited(
      app.deps.platform.autostart.enabled.then((v) {
        if (mounted) setState(() => _autostart = v);
      }),
    );
    _kib.text = '${UploadLimit.fromPrefs(app.config.prefs).kib}';
    _scroll.addListener(_followScroll);
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _kib.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Porta la sezione [i] in cima all'area che scorre: il menu resta fermo
  /// (come nel design, dove è sticky).
  Future<void> _go(int i) async {
    setState(() => _section = i);
    final ctx = _keys[i].currentContext;
    if (ctx == null) return;
    final instant = MsTheme.reducedMotionOf(context);
    _jumping = true;
    try {
      await Scrollable.ensureVisible(
        ctx,
        duration: instant ? Duration.zero : const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } finally {
      _jumping = false;
    }
  }

  /// La voce attiva del menu è l'ultima sezione il cui titolo è già salito
  /// in cima all'area che scorre.
  void _followScroll() {
    if (_jumping || !_scroll.hasClients) return;
    final viewport = _scroll.position.context.storageContext.findRenderObject();
    if (viewport is! RenderBox) return;
    final top = viewport.localToGlobal(Offset.zero).dy;
    var current = 0;
    for (var i = 0; i < _keys.length; i++) {
      final box = _keys[i].currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;
      if (box.localToGlobal(Offset.zero).dy - top <= 48) current = i;
    }
    // in fondo alla pagina vince l'ultima sezione, anche se è corta
    if (_scroll.position.extentAfter < 1) {
      for (var i = _keys.length - 1; i >= 0; i--) {
        if (_keys[i].currentContext != null) {
          current = i;
          break;
        }
      }
    }
    if (current != _section) setState(() => _section = current);
  }

  Future<void> _setLimit(AppState app, UploadLimit l) async {
    await app.setPref('uploadLimit', l.toJson());
    final measured = (app.config.prefs[measuredUploadPref] as num?)?.toInt();
    app.session?.setUploadLimit(l.bytesPerSecond(app.session?.measuredUploadBps ?? measured));
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final t = context.s.settings;
    final g = PixelScope.of(context);
    final q = _search.text.trim().toLowerCase();
    final sections = [
      (t.general, _general(context, app)),
      (t.network, _network(context, app)),
      (t.info, _info(context, app)),
    ];
    final visible = <Widget>[];
    for (var i = 0; i < sections.length; i++) {
      final (title, items) = sections[i];
      final shown = items.where((it) => it.matches(q)).toList();
      if (shown.isEmpty) continue;
      visible.add(
        KeyedSubtree(
          key: _keys[i],
          child: MsPanel(
            title: title,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var k = 0; k < shown.length; k++) ...[
                  if (k > 0) const MsDivider(),
                  _row(context, shown[k]),
                ],
              ],
            ),
          ),
        ),
      );
    }

    final search = MsTextInput(
      key: const ValueKey('settings-search'),
      controller: _search,
      focusNode: _searchFocus,
      placeholder: t.searchHint,
      semanticLabel: t.searchLabel,
      onChanged: (_) => setState(() {}),
    );
    // la ricerca sta in cima all'indice delle sezioni, larga come l'indice
    final nav = SizedBox(
      width: g.d(200),
      child: MsStack(
        gap: 12,
        children: [
          search,
          Semantics(
            label: t.sectionsLabel,
            container: true,
            child: MsNav(
              children: [
                for (var i = 0; i < sections.length; i++)
                  MsNavItem(
                    label: sections[i].$1,
                    quiet: true,
                    current: _section == i,
                    trailing: i == sections.length - 1 && app.deps.platform.updates.ready != null
                        ? const MsNavTrail(dot: MsNavDotKind.play)
                        : null,
                    onPressed: () => _go(i),
                  ),
              ],
            ),
          ),
        ],
      ),
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _searchFocus.requestFocus,
      },
      // larga come le altre pagine: in una finestra grande i controlli non
      // finiscono lontani dalle loro etichette
      child: LayoutBuilder(
        builder: (context, box) {
          final panels = visible.isEmpty
              ? MsText(t.noMatch, tone: MsTextTone.secondary)
              : MsStack(gap: 16, children: visible);
          final title = MsStack(
            gap: 4,
            children: [
              MsText(t.title, kind: MsTextKind.h2),
              MsText(t.intro, tone: MsTextTone.secondary),
            ],
          );
          // con l'interfaccia ingrandita in una finestra stretta l'indice
          // sparisce e scorre tutto insieme
          if (box.maxWidth < g.d(820) + g.d(64)) {
            return SingleChildScrollView(
              controller: _scroll,
              padding: EdgeInsets.fromLTRB(g.d(24), g.d(20), g.d(24), g.d(24)),
              child: MsStack(gap: 16, children: [title, search, panels]),
            );
          }
          return Padding(
            padding: EdgeInsets.fromLTRB(g.d(24), g.d(20), g.d(24), 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                title,
                SizedBox(height: g.d(16)),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      nav,
                      SizedBox(width: g.d(16)),
                      Expanded(
                        child: SingleChildScrollView(
                          controller: _scroll,
                          padding: EdgeInsets.only(bottom: g.d(24)),
                          child: panels,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _row(BuildContext context, _Item it) {
    final g = PixelScope.of(context);
    final text = MsStack(
      gap: 2,
      children: [
        MsText(it.label, weight: 700),
        if (it.hint != null) MsText.small(it.hint!, tone: MsTextTone.secondary),
      ],
    );
    return Padding(
      padding: EdgeInsets.symmetric(vertical: g.d(12)),
      child: LayoutBuilder(
        builder: (context, box) => it.below || box.maxWidth < g.d(560)
            ? MsStack(
                gap: 10,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [text, it.control],
              )
            : Row(
                children: [
                  Expanded(child: text),
                  SizedBox(width: g.d(24)),
                  it.control,
                ],
              ),
      ),
    );
  }

  // --- generali -----------------------------------------------------------------------

  List<_Item> _general(BuildContext context, AppState app) {
    final t = context.s.settings;
    final p = app.config.prefs;
    final theme = app.theme;
    final me = app.me;
    final hub = app.config.hub;
    final hubAddress = hub == null ? null : (Uri.tryParse(hub)?.authority ?? hub);
    final notify = <(String, String)>[
      ('friendOpens', t.notifyFriendOpens),
      ('serverFree', t.notifyServerFree),
      ('sessionProblems', t.notifySessionProblems),
      ('everySave', t.notifyEverySave),
      ('update', t.notifyUpdate),
    ];
    return [
      _Item(
        t.hub,
        // l'indirizzo sta nel testo: a destra solo il pulsante, alto come gli
        // altri controlli
        hint: me != null
            ? t.hubHint(hubAddress, me.name, me.admin)
            : hubAddress != null
            ? t.notConnectedTo(hubAddress)
            : t.notConnected,
        MsButton(
          label: t.changeHub,
          size: MsButtonSize.sm,
          onPressed: app.hosting ? null : () => app.go(const FirstRunRoute()),
        ),
      ),
      _Item(
        t.language,
        MsSegmented<String>(
          semanticLabel: t.language,
          value: app.config.lang ?? 'system',
          onChanged: (v) => app.setLang(parseLang(v)),
          segments: [
            MsSegment(value: 'it', label: t.italian),
            MsSegment(value: 'en', label: t.english),
            MsSegment(value: 'system', label: t.asSystem),
          ],
        ),
      ),
      _Item(
        t.theme,
        MsSegmented<String>(
          semanticLabel: t.theme,
          value: switch (p['theme']) {
            'light' => 'light',
            'system' => 'system',
            _ => 'dark',
          },
          onChanged: (v) => app.setPref('theme', v),
          segments: [
            MsSegment(value: 'dark', label: t.dark),
            MsSegment(value: 'light', label: t.light),
            MsSegment(value: 'system', label: t.asSystem),
          ],
        ),
      ),
      _Item(
        t.style,
        hint: t.styleHint,
        MsSegmented<MsPalette>(
          semanticLabel: t.style,
          value: theme.palette,
          onChanged: (v) => app.setPref('palette', v.name),
          segments: [
            MsSegment(value: MsPalette.prato, label: t.prato),
            MsSegment(value: MsPalette.abisso, label: t.abisso),
          ],
        ),
      ),
      _Item(
        t.size,
        hint: t.sizeHint,
        MsSegmented<int>(
          semanticLabel: t.size,
          value: theme.sizeStep.clamp(0, 2),
          onChanged: (v) => app.setPref('sizeStep', v),
          segments: [
            MsSegment(value: 0, label: t.sizeNormal),
            MsSegment(value: 1, label: t.sizeLarge),
            MsSegment(value: 2, label: t.sizeLarger),
          ],
        ),
      ),
      _Item(
        t.motion,
        hint: t.motionHint,
        MsSwitch(
          value: theme.reducedMotion,
          semanticLabel: t.motion,
          onChanged: (v) => app.setPref('reducedMotion', v),
        ),
      ),
      _Item(
        t.autostart,
        hint: t.autostartHint,
        MsSwitch(
          value: _autostart ?? false,
          semanticLabel: t.autostart,
          onChanged: _autostart == null
              ? null
              : (v) async {
                  setState(() => _autostart = v);
                  await app.deps.platform.autostart.setEnabled(v);
                },
        ),
      ),
      _Item(
        t.tray,
        hint: t.trayHint,
        MsSwitch(
          value: p['tray'] as bool? ?? true,
          semanticLabel: t.tray,
          onChanged: (v) => app.setPref('tray', v),
        ),
      ),
      _Item(
        t.notifications,
        hint: t.notificationsHint,
        below: true,
        // due colonne quando c'è spazio: cinque caselle una sotto l'altra
        // occupano molto in verticale
        AutoGrid(
          minWidth: 280,
          gap: 8,
          children: [
            for (final (k, label) in notify)
              MsCheckbox(
                value: app.notifyPref(k),
                label: label,
                onChanged: (v) => app.setPref('notify.$k', v),
              ),
          ],
        ),
      ),
    ];
  }

  // --- rete ---------------------------------------------------------------------------------

  List<_Item> _network(BuildContext context, AppState app) {
    final t = context.s.settings;
    final l = UploadLimit.fromPrefs(app.config.prefs);
    final measured =
        app.session?.measuredUploadBps ?? (app.config.prefs[measuredUploadPref] as num?)?.toInt();
    final g = PixelScope.of(context);
    return [
      _Item(
        t.bandwidth,
        hint: t.bandwidthHint,
        below: true,
        MsRadioGroup<UploadLimitMode>(
          semanticLabel: t.bandwidthLabel,
          value: l.mode,
          onChanged: (m) => _setLimit(app, l.copyWith(mode: m)),
          options: [
            MsRadioOption(
              value: UploadLimitMode.auto,
              title: t.bwAuto,
              description: t.bwAutoMeta(
                measured == null
                    ? null
                    : context.s.common.sizeBytes(measured * UploadLimit.autoShare ~/ 100),
              ),
            ),
            MsRadioOption(
              value: UploadLimitMode.percent,
              title: t.bwPercent,
              description: t.bwPercentMeta(l.percent),
            ),
            MsRadioOption(
              value: UploadLimitMode.fixed,
              title: t.bwFixed,
              description: t.bwFixedMeta(l.kib),
            ),
            MsRadioOption(value: UploadLimitMode.none, title: t.bwNone, description: t.bwNoneMeta),
          ],
        ),
      ),
      // i controlli del modo stanno fuori dalle righe del gruppo: dentro una
      // riga di MsRadioGroup non ricevono il fuoco
      if (l.mode == UploadLimitMode.percent)
        _Item(
          t.bwPercent,
          SizedBox(
            width: g.d(260),
            child: MsRow(
              wrap: false,
              gap: 8,
              children: [
                Expanded(
                  child: MsSlider(
                    value: l.percent.toDouble(),
                    min: 10,
                    max: 100,
                    step: 5,
                    semanticLabel: t.bwPercent,
                    semanticFormatter: (v) => '${v.round()}%',
                    onChanged: (v) => _setLimit(app, l.copyWith(percent: v.round())),
                  ),
                ),
                MsText.small('${l.percent}%', tabular: true),
              ],
            ),
          ),
        ),
      if (l.mode == UploadLimitMode.fixed)
        _Item(
          t.kibLabel,
          MsRow(
            wrap: false,
            gap: 8,
            children: [
              SizedBox(
                width: g.d(110),
                child: MsTextInput(
                  controller: _kib,
                  mono: true,
                  semanticLabel: t.kibLabel,
                  keyboardType: TextInputType.number,
                  onChanged: (v) {
                    final n = int.tryParse(v.trim());
                    if (n != null && n > 0) unawaited(_setLimit(app, l.copyWith(kib: n)));
                  },
                ),
              ),
              MsText.small(t.kibUnit),
            ],
          ),
        ),
    ];
  }

  // --- info -----------------------------------------------------------------------------------

  List<_Item> _info(BuildContext context, AppState app) {
    final t = context.s.settings;
    final up = app.deps.platform.updates;
    final ready = up.ready;
    final os = Platform.operatingSystem;
    final diag = [
      'MineSync $appVersion',
      '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'hub: ${app.config.hub ?? '-'} (${app.hub?.version ?? '?'})',
      'connection: ${app.connection.name}',
      'servers: ${app.spaces.length}, linked: ${app.config.links.length}',
      if (app.session != null) 'session: ${app.session!.space} ${app.session!.phase.name}',
    ].join('\n');
    return [
      _Item(
        'MineSync $appVersion',
        hint: t.platform(os),
        MsRow(
          gap: 8,
          children: [
            const MsLogo(size: 32),
            if (ready != null) ...[
              MsChip(t.ready(ready), tone: MsChipTone.update),
              MsButton(
                label: t.restartUpdate,
                variant: MsButtonVariant.primary,
                icon: const MsIcon(MsIcons.refresh),
                onPressed: app.hosting ? null : up.restart,
              ),
            ],
          ],
        ),
      ),
      _Item(
        t.updates,
        hint: t.updatesHint,
        MsRow(
          gap: 8,
          children: [
            if (ready == null) MsPill(t.upToDate, tone: MsStatusTone.ok),
            MsButton(
              label: t.checkNow,
              size: MsButtonSize.sm,
              onPressed: app.config.hub == null ? null : () => up.check(Uri.parse(app.config.hub!)),
            ),
          ],
        ),
      ),
      _Item(
        t.diagnostics,
        hint: t.diagnosticsHint,
        MsButton(
          label: t.copyDiagnostics,
          size: MsButtonSize.sm,
          icon: const MsIcon(MsIcons.copy),
          onPressed: () {
            unawaited(Clipboard.setData(ClipboardData(text: diag)));
            ToastScope.of(context).show(MsToastData(title: t.copied, tone: MsToastTone.ok));
          },
        ),
      ),
    ];
  }
}
