// Primo avvio: presentazione a sinistra, a destra la connessione all'hub in
// tre passi (hub, rete ZeroTier, pronto). Niente viene salvato finché
// l'utente non preme "Inizia": prima si prova l'hub, si mostrano i server
// che aspettano e si sceglie dove tenere i mondi.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:ms_core/ms_core.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../l10n/l10n.dart';
import '../state/app_state.dart';
import 'common.dart';

enum _Step { welcome, connecting, error, connected }

/// Motivo per cui la connessione non è riuscita.
enum _Failure { unreachable, timeout, notMember, other }

class FirstRunScreen extends StatefulWidget {
  const FirstRunScreen({super.key});

  @override
  State<FirstRunScreen> createState() => _FirstRunScreenState();
}

class _FirstRunScreenState extends State<FirstRunScreen> {
  late final TextEditingController _address;
  late final TextEditingController _worlds;
  late final bool _prefilled;
  var _step = _Step.welcome;
  var _attempt = 0;
  _Failure? _failure;
  String _details = '';
  String? _invalid;
  HubInfo? _info;
  List<SpaceSummary> _spaces = const [];
  var _autostart = true;
  var _starting = false;
  var _showZt = false;

  @override
  void initState() {
    super.initState();
    final app = AppStateScope.read(context);
    final pre = app.config.hub ?? app.deps.env['MINESYNC_HUB'];
    _prefilled = pre != null && pre.isNotEmpty;
    _address = TextEditingController(text: pre ?? '');
    _worlds = TextEditingController(text: app.displayPath(app.worldsDir));
  }

  @override
  void dispose() {
    _address.dispose();
    _worlds.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final app = AppStateScope.read(context);
    final s = context.s.firstRun;
    final text = _address.text.trim();
    final Uri uri;
    try {
      uri = AppState.hubUri(text);
      if (text.isEmpty || uri.host.isEmpty) throw const FormatException();
    } on FormatException {
      setState(() => _invalid = s.addressInvalid);
      return;
    }
    final attempt = ++_attempt;
    setState(() {
      _invalid = null;
      _step = _Step.connecting;
    });
    try {
      final (info, spaces) = await app.probeHub(text);
      if (!mounted || attempt != _attempt) return;
      unawaited(app.probePc());
      setState(() {
        _info = info;
        _spaces = spaces;
        _step = _Step.connected;
      });
    } on Object catch (e) {
      if (!mounted || attempt != _attempt) return;
      setState(() {
        _failure = _classify(e);
        _details = '$uri\n$e';
        _step = _Step.error;
      });
    }
  }

  static _Failure _classify(Object e) => switch (e) {
    HubUnreachable(:final cause) when cause is TimeoutException => _Failure.timeout,
    HubUnreachable() => _Failure.unreachable,
    ApiError(:final code) when code == ErrorCode.unauthenticated || code == ErrorCode.forbidden =>
      _Failure.notMember,
    _ => _Failure.other,
  };

  void _cancel() => setState(() {
    _attempt++;
    _step = _Step.welcome;
  });

  Future<void> _start() async {
    final app = AppStateScope.read(context);
    setState(() => _starting = true);
    final shown = app.displayPath(app.worldsDir);
    final worlds = _worlds.text.trim();
    if (worlds.isNotEmpty && worlds != shown) await app.setPref('worldsDir', worlds);
    try {
      await app.deps.platform.autostart.setEnabled(_autostart);
    } on Object {
      // l'avvio automatico si può sistemare dalle impostazioni
    }
    try {
      await app.connectTo(_address.text);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _failure = _classify(e);
        _details = '$e';
        _step = _Step.error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= g.d(980);
        final panel = Padding(
          padding: EdgeInsets.fromLTRB(g.d(48), g.d(40), g.d(48), g.d(48)),
          child: Center(child: _panel(context)),
        );
        if (!wide) {
          return SingleChildScrollView(child: Column(children: [const _Intro(), panel]));
        }
        // presentazione a sinistra, collegamento a destra
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Expanded(child: SingleChildScrollView(child: _Intro())),
                  SizedBox(
                    width: g.d(560),
                    child: SingleChildScrollView(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: c.maxHeight),
                        child: panel,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _panel(BuildContext context) {
    final s = context.s.firstRun;
    final g = PixelScope.of(context);
    final idx = switch (_step) {
      _Step.welcome || _Step.connecting => 0,
      _Step.error => _failure == _Failure.notMember ? 1 : 0,
      _Step.connected => 2,
    };
    return MsStack(
      gap: 16,
      children: [
        MsPanel(
          raised: true,
          semanticLabel: s.panelLabel,
          padding: MsPanelPadding.none,
          child: Padding(
            padding: EdgeInsets.all(g.d(28)),
            child: MsStack(
              gap: 24,
              children: [
                _Steps(current: idx, error: _step == _Step.error, done: _step == _Step.connected),
                switch (_step) {
                  _Step.welcome => _welcome(context),
                  _Step.connecting => _connecting(context),
                  _Step.error => _error(context),
                  _Step.connected => _connected(context),
                },
              ],
            ),
          ),
        ),
        // una volta sola: nel passo finale c'è già abbastanza da leggere
        if (_step != _Step.connected)
          MsText.small(s.footer, tone: MsTextTone.secondary, align: TextAlign.center),
      ],
    );
  }

  Widget _addressField(BuildContext context, {bool enabled = true}) {
    final s = context.s.firstRun;
    return MsField(
      label: s.addressLabel,
      // senza indirizzo precompilato basta l'esempio nel campo
      help: _prefilled ? s.addressHintPrefilled : null,
      error: _invalid,
      child: MsTextInput(
        controller: _address,
        mono: true,
        enabled: enabled,
        autofocus: enabled,
        error: _invalid != null,
        placeholder: 'http://192.0.2.10:8084',
        onSubmitted: (_) => _connect(),
      ),
    );
  }

  Widget _welcome(BuildContext context) {
    final s = context.s.firstRun;
    return MsStack(
      gap: 20,
      children: [
        MsStack(
          gap: 6,
          children: [
            MsText.h2(s.welcomeTitle),
            MsText(s.welcomeText, tone: MsTextTone.secondary),
          ],
        ),
        _addressField(context),
        MsRow(
          children: [
            MsButton(
              label: s.connect,
              variant: MsButtonVariant.primary,
              size: MsButtonSize.lg,
              onPressed: _connect,
            ),
            MsButton(
              label: s.whatIsZt,
              variant: MsButtonVariant.ghost,
              size: MsButtonSize.sm,
              icon: const MsIcon(MsIcons.info),
              onPressed: () => setState(() => _showZt = !_showZt),
            ),
          ],
        ),
        if (_showZt) MsText.small(s.ztExplain, tone: MsTextTone.secondary),
      ],
    );
  }

  Widget _connecting(BuildContext context) {
    final s = context.s.firstRun;
    final c = MsTheme.colorsOf(context);
    final g = PixelScope.of(context);
    Widget line(Widget mark, String text, {bool dim = false}) => SizedBox(
      height: g.d(32),
      child: Row(
        spacing: g.d(12),
        children: [
          SizedBox(
            width: g.d(16),
            height: g.d(16),
            child: Center(child: mark),
          ),
          MsText(text, tone: dim ? MsTextTone.tertiary : MsTextTone.primary),
        ],
      ),
    );
    return MsStack(
      gap: 20,
      children: [
        MsStack(
          gap: 6,
          children: [
            MsText.h2(s.connectingTitle),
            MsText(s.connectingText, tone: MsTextTone.secondary),
          ],
        ),
        _addressField(context, enabled: false),
        MsProgress.indeterminate(semanticLabel: s.progressLabel),
        MsStack(
          gap: 4,
          children: [
            line(MsIcon(MsIcons.check, color: c.ok), s.checkAddress),
            line(const MsSpinner(), s.checkReach),
            line(
              SizedBox.square(
                dimension: g.d(16),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: c.text3, width: g.d(2)),
                  ),
                ),
              ),
              s.checkWho,
              dim: true,
            ),
          ],
        ),
        MsRow(
          children: [
            MsButton(
              label: s.connectingButton,
              variant: MsButtonVariant.primary,
              size: MsButtonSize.lg,
              loading: true,
              onPressed: null,
            ),
            MsButton(label: s.cancel, variant: MsButtonVariant.ghost, onPressed: _cancel),
          ],
        ),
      ],
    );
  }

  Widget _error(BuildContext context) {
    final strings = context.s;
    final s = strings.firstRun;
    final g = PixelScope.of(context);
    final (title, text) = switch (_failure!) {
      _Failure.notMember => (s.errNotMemberTitle, s.errNotMemberText),
      _Failure.unreachable => (s.errUnreachableTitle, s.errUnreachableText(_address.text.trim())),
      _Failure.timeout => (s.errTimeoutTitle, s.errTimeoutText),
      _Failure.other => (s.errOtherTitle, s.errOtherText(_details.split('\n').last)),
    };
    return MsStack(
      gap: 18,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: g.d(16),
          children: [
            const MsArt(MsArts.crackedBlock, size: 64),
            Expanded(
              child: MsStack(
                gap: 6,
                children: [
                  MsText.h2(title, tone: MsTextTone.err),
                  MsText(text),
                ],
              ),
            ),
          ],
        ),
        MsSlot(
          padding: EdgeInsets.all(g.d(16)),
          child: MsStack(
            gap: 10,
            children: [
              MsText.label(s.whatToDo),
              for (var i = 0; i < s.todo.length; i++)
                RichLine([('${i + 1}. ', false), ...s.todo[i]], kind: MsTextKind.small),
            ],
          ),
        ),
        MsText.small(s.untouched, tone: MsTextTone.secondary),
        MsRow(
          children: [
            MsButton(
              label: s.retry,
              variant: MsButtonVariant.primary,
              size: MsButtonSize.lg,
              icon: const MsIcon(MsIcons.refresh),
              onPressed: _connect,
            ),
            MsButton(
              label: s.changeAddress,
              variant: MsButtonVariant.ghost,
              onPressed: () => setState(() => _step = _Step.welcome),
            ),
            MsButton(
              label: s.copyDetails,
              variant: MsButtonVariant.ghost,
              icon: const MsIcon(MsIcons.copy),
              onPressed: () => copyText(context, _details, s.copied),
            ),
          ],
        ),
        MsStack(
          gap: 4,
          children: [
            MsText.small(s.otherReasons, tone: MsTextTone.secondary, weight: 600),
            for (final r in s.reasons)
              RichLine(r, kind: MsTextKind.small, tone: MsTextTone.secondary),
          ],
        ),
      ],
    );
  }

  Widget _connected(BuildContext context) {
    final app = AppStateScope.of(context);
    final strings = context.s;
    final s = strings.firstRun;
    final info = _info!;
    final g = PixelScope.of(context);
    final free = app.worldsDisk == null ? null : strings.fmt.size(app.worldsDisk!.free);
    return MsStack(
      gap: 20,
      children: [
        Row(
          spacing: g.d(16),
          children: [
            MsAvatar(info.me.name, size: MsAvatarSize.large),
            Expanded(
              child: MsStack(
                gap: 4,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MsPill(s.connected, tone: MsStatusTone.ok),
                  MsText.h2(s.hello(info.me.name)),
                  RichLine(s.youAre(info.name, info.me.admin), tone: MsTextTone.secondary),
                ],
              ),
            ),
          ],
        ),
        MsStack(
          gap: 6,
          children: [
            MsText.label(s.waiting(_spaces.length), tone: MsTextTone.secondary),
            if (_spaces.isNotEmpty)
              MsList(
                children: [
                  for (final sp in _spaces)
                    MsListRow(
                      lead: const MsIcon(MsIcons.server),
                      title: sp.name,
                      trail: lockBadge(context, sp),
                    ),
                ],
              ),
          ],
        ),
        MsField(
          label: s.worldsLabel,
          help: s.worldsHint(free),
          child: MsTextInput(controller: _worlds, mono: true),
        ),
        MsSwitch(
          value: _autostart,
          label: s.autostart,
          description: s.autostartText,
          onChanged: (v) => setState(() => _autostart = v),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: MsButton(
            label: s.start,
            variant: MsButtonVariant.primary,
            size: MsButtonSize.lg,
            trailing: const MsIcon(MsIcons.chev),
            loading: _starting,
            onPressed: _starting ? null : _start,
          ),
        ),
      ],
    );
  }
}

/// Indicatore dei tre passi: quello corrente su fondo d'accento (o di
/// errore) con una barra di 4 px sotto.
class _Steps extends StatelessWidget {
  const _Steps({required this.current, required this.error, required this.done});
  final int current;
  final bool error;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final s = context.s.firstRun;
    final c = MsTheme.colorsOf(context);
    final g = PixelScope.of(context);
    return Semantics(
      label: s.stepsLabel,
      child: Row(
        spacing: g.d(4),
        children: [
          for (var i = 0; i < s.steps.length; i++)
            Expanded(
              child: () {
                final now = i == current;
                final isDone = i < current;
                final bg = now ? (error ? c.errBg : c.accentBg) : c.inset;
                final fg = now
                    ? (error ? c.err : c.text)
                    : isDone
                    ? c.text2
                    : c.text3;
                return Semantics(
                  selected: now,
                  child: ColoredBox(
                    color: bg,
                    child: Column(
                      children: [
                        Padding(
                          padding: EdgeInsets.fromLTRB(g.d(12), g.d(8), g.d(12), g.d(4)),
                          child: Row(
                            spacing: g.d(8),
                            children: [
                              MsText.label('${i + 1}', color: fg),
                              Flexible(child: MsText(s.steps[i], color: fg, maxLines: 1)),
                            ],
                          ),
                        ),
                        SizedBox(
                          height: g.d(4),
                          child: ColoredBox(
                            color: now ? (error ? c.err : c.accent) : bg,
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }(),
            ),
        ],
      ),
    );
  }
}

/// Presentazione: logo, nome e i tre punti.
class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    final s = context.s.firstRun;
    final c = MsTheme.colorsOf(context);
    final g = PixelScope.of(context);
    Widget feat(MsIconData icon, String title) => Row(
      spacing: g.d(14),
      children: [
        SizedBox.square(
          dimension: g.d(44),
          child: MsSlot.square(
            child: Center(child: MsIcon(icon, size: 24, color: c.accentInk)),
          ),
        ),
        Expanded(child: MsText(title, weight: 700)),
      ],
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(g.d(48), g.d(48), g.d(48), g.d(28)),
      child: MsStack(
        gap: 28,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const MsLogo(size: 64),
          MsText.display(context.s.shell.appName),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: g.d(460)),
            child: MsStack(
              gap: 16,
              children: [
                feat(MsIcons.play, s.feat1Title),
                feat(MsIcons.save, s.feat2Title),
                feat(MsIcons.shield, s.feat3Title),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
