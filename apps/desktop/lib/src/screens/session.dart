// Sessione di gioco (canvas "AppSession"): stato e fasi, salvataggi
// sull'hub, come entrano gli amici, giocatori, server, console con filtri,
// ricerca e comandi, avvisi recenti e avvisi gravi. Apre da sola i dialoghi
// che la sessione chiede (EULA, conflitto, crash, esito, errori di avvio).
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../app.dart';
import '../dialogs/app_dialogs.dart';
import '../l10n/l10n.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'server.dart';

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, required this.space});

  /// Id dello spazio.
  final String space;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

/// Filtro della console per livello.
enum _Filter { all, warn, err }

class _SessionScreenState extends State<SessionScreen> {
  Timer? _tick;
  SessionController? _bound;
  StreamSubscription<SessionSignal>? _signals;
  bool _promptOpen = false;
  bool _conflictOpen = false;
  Object? _errorShown;

  var _filter = _Filter.all;
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'console search');
  final _command = TextEditingController();
  late final _commandFocus = FocusNode(debugLabel: 'console command', onKeyEvent: _onCommandKey);
  int? _historyAt;

  @override
  void initState() {
    super.initState();
    // tempi relativi ("3 min fa", conto alla rovescia)
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && (_bound?.active ?? false)) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppStateScope.of(context);
    final s = app.session;
    _bind(s != null && s.space == widget.space ? s : null);
  }

  void _bind(SessionController? s) {
    if (s == _bound) return;
    _bound?.removeListener(_onSession);
    unawaited(_signals?.cancel());
    _bound = s;
    _promptOpen = false;
    _conflictOpen = false;
    _errorShown = null;
    if (s != null) {
      s.addListener(_onSession);
      _signals = s.signals.listen(_onSignal);
      _onSession();
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _bound?.removeListener(_onSession);
    unawaited(_signals?.cancel());
    _search.dispose();
    _searchFocus.dispose();
    _command.dispose();
    _commandFocus.dispose();
    super.dispose();
  }

  // --- dialoghi chiesti dalla sessione ----------------------------------------------

  void _onSession() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_openDialogs());
    });
  }

  Future<void> _openDialogs() async {
    final s = _bound;
    if (s == null) return;
    if (s.prompt == SessionPrompt.eula && !_promptOpen) {
      _promptOpen = true;
      final ok = await showEulaDialog(context, server: s.name);
      _promptOpen = false;
      s.answerPrompt(ok);
      return;
    }
    if (s.phase == SessionPhase.conflict && s.conflict != null && !_conflictOpen) {
      _conflictOpen = true;
      final app = AppStateScope.read(context);
      final head = app.space(s.space)?.head;
      final choice = await showConflictDialog(
        context,
        ConflictFacts.of(
          s,
          lastAuthor: head == null ? null : '${head.author}, ${hhmm(_ts(head.ts))}',
        ),
      );
      _conflictOpen = false;
      await s.resolveConflict(choice);
      return;
    }
    final e = s.error;
    if (s.phase == SessionPhase.failed &&
        e != null &&
        s.runningSince == null &&
        s.alerts.isEmpty &&
        !identical(e, _errorShown)) {
      _errorShown = e;
      final app = AppStateScope.read(context);
      final a = await showStartError(context, server: s.name, error: e);
      switch (a) {
        case StartErrorAction.retry:
          await _playAgain(app);
        case StartErrorAction.settings:
          // le impostazioni del server (Java, memoria) sono nella sua pagina
          app.closeSession();
          app.go(ServerRoute(widget.space));
        case StartErrorAction.close:
          break;
      }
    }
  }

  Future<void> _onSignal(SessionSignal sig) async {
    final s = _bound;
    if (s == null || !mounted) return;
    final t = context.s.session;
    switch (sig) {
      case SignalCrashed(:final crash):
        final a = await showCrashDialog(context, server: s.name, crash: crash);
        if (a == CrashAction.dontRestart) await s.stop();
      case SignalHubBack():
        ToastScope.of(
          context,
        ).show(MsToastData(title: t.hubBackTitle, text: t.hubBackText, tone: MsToastTone.ok));
      case SignalEnded(:final ok) when ok && s.alerts.isEmpty:
        final app = AppStateScope.read(context);
        final again = await showSessionEnded(context, s);
        if (again) {
          await _playAgain(app);
        }
      default:
        break;
    }
  }

  Future<void> _playAgain(AppState app) async {
    app.closeSession();
    try {
      await app.play(widget.space);
    } on StateError {
      app.go(ServerRoute(widget.space));
    }
  }

  static DateTime _ts(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);

  // --- comandi ------------------------------------------------------------------------

  KeyEventResult _onCommandKey(FocusNode node, KeyEvent e) {
    final s = _bound;
    if (s == null || e is KeyUpEvent) return KeyEventResult.ignored;
    final h = s.commandHistory;
    if (h.isEmpty) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
      _historyAt = ((_historyAt ?? h.length) - 1).clamp(0, h.length - 1);
    } else if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (_historyAt == null) return KeyEventResult.handled;
      final next = _historyAt! + 1;
      _historyAt = next >= h.length ? null : next;
    } else {
      return KeyEventResult.ignored;
    }
    final text = _historyAt == null ? '' : h[_historyAt!];
    _command.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    return KeyEventResult.handled;
  }

  Future<void> _send() async {
    final s = _bound;
    final text = _command.text;
    if (s == null || text.trim().isEmpty) return;
    _command.clear();
    _historyAt = null;
    try {
      await s.send(text);
    } on StateError {
      // server non avviato: il comando resta nella cronologia
    }
  }

  void _copy(String text) {
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    ToastScope.of(context).show(MsToastData(title: context.s.session.copied, tone: MsToastTone.ok));
  }

  // --- costruzione ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final s = _bound;
    final g = PixelScope.of(context);
    // la stessa barra delle altre schede del server (anche Mod)
    final tabs = ServerTabs(space: widget.space, current: ServerTab.overview);
    if (s == null) {
      // la sessione è stata chiusa: torna la panoramica
      return ServerScreen(space: widget.space);
    }
    final head = <Widget>[
      tabs,
      ..._alerts(context, app, s),
      _StatusPanel(session: s, onSave: _save, onStop: _stop, onBack: () => _back(app)),
    ];
    final side = MsStack(
      gap: 16,
      children: [
        ..._side(context, app, s),
        _NoticesPanel(session: s),
      ],
    );
    final pad = EdgeInsets.fromLTRB(g.d(32), g.d(24), g.d(32), g.d(24));
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _searchFocus.requestFocus,
      },
      child: FocusTraversalGroup(
        child: LayoutBuilder(
          builder: (context, box) {
            final width = box.maxWidth - pad.horizontal;
            final tall = box.maxHeight >= g.d(720);
            // finestra stretta o bassa: tutto in colonna e scorre insieme
            if (width < g.d(860) || !tall) {
              return SingleChildScrollView(
                padding: pad,
                child: MsStack(
                  gap: 24,
                  children: [
                    ...head,
                    side,
                    SizedBox(height: g.d(480), child: _console(context, s)),
                  ],
                ),
              );
            }
            // come un pannello di controllo: intestazione fissa, colonna
            // laterale che scorre da sola, console fino al fondo
            return Padding(
              padding: pad,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  MsStack(gap: 24, children: head),
                  SizedBox(height: g.d(24)),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: g.d(360),
                          child: SingleChildScrollView(child: side),
                        ),
                        SizedBox(width: g.d(24)),
                        Expanded(child: _console(context, s)),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  void _save() {
    final s = _bound;
    if (s == null) return;
    if (s.saveNow() == SaveRequest.queued) {
      ToastScope.of(context).show(MsToastData(title: context.s.session.saveQueued));
    }
  }

  void _stop() => unawaited(_bound?.stop());

  void _back(AppState app) {
    app.closeSession();
    app.go(ServerRoute(widget.space));
  }

  List<Widget> _alerts(BuildContext context, AppState app, SessionController s) {
    final t = context.s.session;
    final d = context.s.dialogs;
    final out = <Widget>[];
    final saved = s.lastSaved;
    String facts(String todo) => [
      '${t.safeOnHub}: ${t.safeOnHubValue(saved == null ? null : hhmm(saved.at))}',
      '${t.onlyHere}: ${t.onlyHereValue(s.folder)}',
      if (todo.isNotEmpty) '${t.whatToDo}: $todo',
    ].join('\n');
    String details(String kind) => [
      'MineSync $appVersion',
      '${s.name} (${s.space})',
      kind,
      if (s.alertAt != null) hhmmss(s.alertAt!),
      if (saved != null) '#${saved.n}',
      s.folder,
    ].join(', ');
    for (final kind in ['lockLost', 'spaceGone']) {
      if (!s.alerts.contains(kind)) continue;
      final lost = kind == 'lockLost';
      out.add(
        MsAlert(
          tone: MsAlertTone.err,
          icon: const MsIcon(MsIcons.lock),
          title: lost ? t.lockLostTitle(s.name) : t.spaceGoneTitle(s.name),
          text:
              '${lost ? t.lockLostText(s.name) : t.spaceGoneText(s.name)}\n\n'
              '${facts(lost ? t.lockLostTodo : '')}',
          actions: [
            MsButton(
              label: t.details,
              semanticLabel: t.detailsLabel,
              size: MsButtonSize.sm,
              variant: MsButtonVariant.ghost,
              icon: const MsIcon(MsIcons.copy),
              onPressed: () => _copy(details(kind)),
            ),
          ],
        ),
      );
    }
    if (s.alerts.contains('hubDiskFull')) {
      out.add(
        MsAlert(
          tone: MsAlertTone.warn,
          icon: const MsIcon(MsIcons.disk),
          title: t.hubFullTitle,
          text: t.hubFullText,
        ),
      );
    }
    if (s.hubUnreachable && s.active) {
      out.add(
        MsAlert(
          tone: MsAlertTone.warn,
          icon: const MsIcon(MsIcons.signal),
          title: t.hubLostTitle,
          text: '${t.hubLostText}\n${t.hubLostKeepOpen}',
        ),
      );
    }
    final e = s.error;
    if (s.phase == SessionPhase.failed && e != null && s.alerts.isEmpty) {
      out.add(
        MsAlert(
          tone: MsAlertTone.err,
          icon: const MsIcon(MsIcons.warn),
          title: t.headFailed(s.name),
          text: switch (e) {
            JavaMissing(:final required) => d.javaText(s.name, required),
            NoLaunchFound() => d.noLaunchText,
            EulaDeclined() => d.eulaDeclinedText,
            GuardMissing() => d.guardMissingText,
            _ => d.describeError(context.s.common, e),
          },
          actions: [
            MsButton(
              label: t.retry,
              size: MsButtonSize.sm,
              icon: const MsIcon(MsIcons.refresh),
              onPressed: () => _playAgain(app),
            ),
          ],
        ),
      );
    }
    if (s.phase == SessionPhase.conflict) {
      out.add(
        MsAlert(
          tone: MsAlertTone.warn,
          icon: const MsIcon(MsIcons.warn),
          title: t.headConflict,
          text: t.subConflict,
        ),
      );
    }
    return out;
  }

  List<Widget> _side(BuildContext context, AppState app, SessionController s) {
    final t = context.s.session;
    final now = s.now();
    final saved = s.lastSaved;
    final up = s.upload;
    final next = s.nextSaveAt;
    final after = s.config.emptyStopAfter?.inMinutes ?? 30;
    final info = s.launchInfo;
    final port = info?.port ?? 25565;
    final g = PixelScope.of(context);

    Widget cell(String term, String value) => MsStack(
      gap: 2,
      children: [
        MsText.small(term, tone: MsTextTone.secondary),
        MsText(value, weight: 600, tabular: true),
      ],
    );

    final uploading = up != null && s.active;
    final sessionPanel = MsPanel(
      title: t.panelSession,
      child: MsStack(
        gap: 16,
        children: [
          Table(
            children: [
              TableRow(
                children: [
                  Padding(
                    padding: EdgeInsets.only(right: g.d(16), bottom: g.d(14)),
                    child: cell(
                      t.onHub,
                      uploading
                          ? t.uploadingValue((up.fraction * 100).round())
                          : saved == null
                          ? t.nothingYet
                          : t.onHubValue(t.ago(now.difference(saved.at)), hhmm(saved.at)),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.only(bottom: g.d(14)),
                    child: cell(
                      t.nextSave,
                      next == null ? '—' : t.inTime(mmss(next.difference(now))),
                    ),
                  ),
                ],
              ),
              TableRow(
                children: [
                  Padding(
                    padding: EdgeInsets.only(right: g.d(16)),
                    child: cell(
                      t.autostopTerm,
                      s.autostop ? t.autostopValue(after) : t.autostopOff,
                    ),
                  ),
                  const SizedBox.shrink(),
                ],
              ),
            ],
          ),
          if (uploading)
            MsStack(
              gap: 4,
              children: [
                MsProgress(value: up.fraction, semanticLabel: t.uploadProgress),
                MsProgressMeta(
                  start: MsText.small(
                    t.uploadMeta(
                      context.s.common.sizeBytes(up.done),
                      context.s.common.sizeBytes(up.total),
                      context.s.common.sizeBytes(up.bytesPerSecond),
                    ),
                    tabular: true,
                  ),
                  end: up.secondsLeft == null ? null : MsText.small(t.secondsLeft(up.secondsLeft!)),
                ),
              ],
            ),
          if (s.lagMs != null)
            MsAlert(
              tone: MsAlertTone.warn,
              icon: const MsIcon(MsIcons.warn),
              title: t.lagTitle,
              text: t.lagText(s.lagMs! / 1000),
            ),
        ],
      ),
    );

    // indirizzo fisso dell'hub (DNS) se c'è, poi l'IP diretto visto
    // dall'hub; senza hub le interfacce di questo PC
    final sp = app.space(s.space);
    final mine = sp?.lock != null && sp!.lock!.memberId == app.me?.id ? sp.lock : null;
    // il lock di un altro (sessione finita, server forzato) non dice niente
    // su questo PC
    final ip = [
      mine?.ip,
      ...s.addresses,
    ].firstWhere((a) => a != null && a.isNotEmpty, orElse: () => null);
    final JoinAddresses ja = (
      fixed: s.active && sp?.dnsName != null && sp!.dnsName!.isNotEmpty ? sp.dnsName : null,
      direct: ip == null ? null : '$ip:$port',
    );
    final main = ja.fixed ?? ja.direct;
    final check = s.active ? mine?.portCheck : null;
    final addressPanel = MsPanel(
      title: t.panelAddress,
      child: main == null
          ? MsText.small(t.noAddress, tone: MsTextTone.secondary)
          : MsStack(
              gap: 10,
              children: [
                // l'indirizzo non si spezza a metà: se non c'è spazio il
                // pulsante va sotto
                MsSlot(
                  child: MsRow(
                    children: [
                      MsText.mono(main, weight: 700),
                      MsButton(
                        label: t.copy,
                        size: MsButtonSize.sm,
                        icon: const MsIcon(MsIcons.copy),
                        semanticLabel: t.copyAddress(main),
                        onPressed: () => _copy(main),
                      ),
                    ],
                  ),
                ),
                if (ja.fixed != null && ja.direct != null)
                  MsRow(
                    gap: 8,
                    children: [
                      MsText.small(t.directIp, tone: MsTextTone.secondary),
                      MsCode(ja.direct!),
                      MsButton.icon(
                        icon: const MsIcon(MsIcons.copy),
                        semanticLabel: t.copyDirectIp,
                        size: MsButtonSize.sm,
                        variant: MsButtonVariant.ghost,
                        onPressed: () => _copy(ja.direct!),
                      ),
                    ],
                  ),
                if (check != null) _PortCheckRow(space: s.space, check: check),
              ],
            ),
    );

    final players = s.players.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
    final onlinePanel = MsPanel(
      title: t.panelOnline,
      actions: [MsText.small(t.playersCount(players.length, info?.maxPlayers), tabular: true)],
      padding: MsPanelPadding.tight,
      child: players.isEmpty
          ? MsText.small(t.nobodyYet, tone: MsTextTone.secondary)
          : MsList(
              flat: true,
              children: [
                for (final p in players)
                  MsListRow(
                    title: p.key,
                    meta: listMeta([
                      if (p.key == s.me) context.s.server.you,
                      t.since(t.duration(now.difference(p.value))),
                    ]),
                    lead: MsAvatar(
                      p.key,
                      size: MsAvatarSize.small,
                      semanticLabel: t.avatarOf(p.key),
                    ),
                  ),
              ],
            ),
    );

    final serverPanel = MsPanel(
      title: t.panelServer,
      child: MsFacts([
        MsFact(t.launchTerm, info?.label ?? '—'),
        MsFact(t.javaTerm, info == null ? '—' : (info.javaVersion ?? t.javaFromScript)),
        MsFact(
          t.memoryTerm,
          info == null
              ? '—'
              : info.xmxMiB == null
              ? t.memoryFromScript
              : t.gib(info.xmxMiB! / 1024),
        ),
        MsFact(t.portTerm, '$port'),
        MsFact(t.folderTerm, s.folder, child: MsText.mono(s.folder)),
      ]),
    );
    return [sessionPanel, addressPanel, onlinePanel, serverPanel];
  }

  Widget _console(BuildContext context, SessionController s) {
    final t = context.s.session;
    final q = _search.text.trim().toLowerCase();
    final lines = <MsConsoleLine>[];
    var matches = 0;
    var warn = 0;
    var err = 0;
    for (final e in s.console) {
      if (e.kind == ConsoleKind.err) err++;
      if (e.isWarnOrErr) warn++;
      final keep = switch (_filter) {
        _Filter.all => true,
        _Filter.warn => e.isWarnOrErr,
        _Filter.err => e.kind == ConsoleKind.err,
      };
      if (!keep) continue;
      final text = e.note == null ? e.text : t.note(e.note!.name, e.args);
      final match = q.isNotEmpty && text.toLowerCase().contains(q);
      if (match) matches++;
      lines.add(
        MsConsoleLine(
          text,
          time: hhmmss(e.at),
          level: e.level,
          match: match,
          kind: switch (e.kind) {
            ConsoleKind.info => MsLineKind.info,
            ConsoleKind.dim => MsLineKind.dim,
            ConsoleKind.warn => MsLineKind.warn,
            ConsoleKind.err => MsLineKind.err,
            ConsoleKind.join => MsLineKind.join,
            ConsoleKind.ok => MsLineKind.ok,
            ConsoleKind.cmd => MsLineKind.cmd,
          },
        ),
      );
    }
    final c = MsTheme.colorsOf(context);
    final running = s.phase == SessionPhase.running || s.phase == SessionPhase.saving;
    void fill(String cmd) {
      _command.value = TextEditingValue(
        text: cmd,
        selection: TextSelection.collapsed(offset: cmd.length),
      );
      _commandFocus.requestFocus();
    }

    return MsConsole(
      lines: lines,
      semanticLabel: t.consoleLabel,
      liveLabel: t.liveLabel,
      liveIcon: const MsIcon(MsIcons.arrowDown),
      toolbar: MsRow(
        wrap: false,
        gap: 8,
        children: [
          MsSegmented<_Filter>(
            semanticLabel: t.filterLabel,
            value: _filter,
            onChanged: (f) => setState(() => _filter = f),
            segments: [
              MsSegment(value: _Filter.all, label: t.filterAll),
              MsSegment(value: _Filter.warn, label: '${t.filterWarn} $warn'),
              MsSegment(value: _Filter.err, label: '${t.filterErr} $err'),
            ],
          ),
          Expanded(
            child: MsTextInput(
              controller: _search,
              focusNode: _searchFocus,
              mono: true,
              dense: true,
              placeholder: t.searchHint,
              semanticLabel: t.searchLabel,
              onChanged: (_) => setState(() {}),
            ),
          ),
          if (q.isNotEmpty) MsText.small(t.results(matches), tabular: true),
          MsButton.icon(
            icon: const MsIcon(MsIcons.copy),
            semanticLabel: t.copyLog,
            variant: MsButtonVariant.ghost,
            onPressed: () => _copy(MsConsole.plainText(lines)),
          ),
        ],
      ),
      input: MsRow(
        wrap: false,
        gap: 8,
        children: [
          Expanded(
            child: MsTextInput(
              controller: _command,
              focusNode: _commandFocus,
              mono: true,
              enabled: running,
              placeholder: t.commandHint,
              semanticLabel: t.commandLabel,
              onSubmitted: (_) => _send(),
            ),
          ),
          // alto quanto il campo del comando accanto
          MsButton(
            label: t.send,
            variant: MsButtonVariant.primary,
            onPressed: running ? _send : null,
          ),
        ],
      ),
      footer: MsRow(
        gap: 6,
        children: [
          MsText.small(t.quick, color: c.conDim),
          for (final cmd in const ['list', 'say ', 'time set day', 'weather clear'])
            MsChip(cmd == 'say ' ? 'say …' : cmd, onTap: running ? () => fill(cmd) : null),
        ],
      ),
    );
  }
}

// --- pannello di stato ------------------------------------------------------------------

/// Come appare la sessione: pillola, titolo, sottotitolo, fase corrente.
enum _Look {
  syncing,
  conflict,
  starting,
  playing,
  saving,
  uploading,
  stopping,
  finalPush,
  stopped,
  ended,
  failed,
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.session,
    required this.onSave,
    required this.onStop,
    required this.onBack,
  });

  final SessionController session;
  final VoidCallback onSave;
  final VoidCallback onStop;
  final VoidCallback onBack;

  _Look _look() {
    final s = session;
    if (s.alerts.contains('lockLost') || s.alerts.contains('spaceGone')) return _Look.stopped;
    return switch (s.phase) {
      SessionPhase.syncing => _Look.syncing,
      SessionPhase.conflict => _Look.conflict,
      SessionPhase.starting => _Look.starting,
      SessionPhase.running when s.upload != null => _Look.uploading,
      SessionPhase.running => _Look.playing,
      SessionPhase.saving => _Look.saving,
      SessionPhase.stopping => _Look.stopping,
      SessionPhase.finalPush => _Look.finalPush,
      SessionPhase.ended => _Look.ended,
      SessionPhase.failed || SessionPhase.cancelled => _Look.failed,
    };
  }

  @override
  Widget build(BuildContext context) {
    final t = context.s.session;
    final s = session;
    final look = _look();
    final pct = ((s.upload?.fraction ?? 0) * 100).round();
    final (tone, pill, head, sub) = switch (look) {
      _Look.syncing => (MsStatusTone.info, t.pillSyncing, t.headSyncing(s.name), t.subSyncing),
      _Look.conflict => (MsStatusTone.warn, t.pillSyncing, t.headConflict, t.subConflict),
      _Look.starting => (MsStatusTone.info, t.pillStarting, t.headStarting(s.name), t.subStarting),
      _Look.playing => (MsStatusTone.ok, t.pillRunning, t.headRunning(s.name), t.subRunning),
      _Look.saving => (MsStatusTone.info, t.pillSaving, t.headSaving, t.subSaving),
      _Look.uploading => (MsStatusTone.info, t.pillUploading(pct), t.headUploading, t.subUploading),
      _Look.stopping => (MsStatusTone.warn, t.pillStopping, t.headStopping(s.name), t.subStopping),
      _Look.finalPush => (
        MsStatusTone.warn,
        t.pillFinalPush,
        t.headStopping(s.name),
        t.subStopping,
      ),
      _Look.stopped => (MsStatusTone.err, t.pillStopped, t.headStopped, t.subStopped(s.name)),
      _Look.ended => (MsStatusTone.neutral, t.pillEnded, t.headEnded(s.name), t.subEnded),
      _Look.failed => (MsStatusTone.err, t.pillFailed, t.headFailed(s.name), ''),
    };
    final step = switch (look) {
      _Look.syncing || _Look.conflict => 0,
      _Look.starting => 1,
      _Look.playing || _Look.stopped => 2,
      _Look.saving => 3,
      _Look.uploading => 4,
      _Look.stopping || _Look.finalPush => 5,
      _Look.ended => 6,
      _Look.failed => s.runningSince == null ? 1 : 2,
    };
    final now = s.now();
    final since = s.runningSince ?? s.startedAt;
    final canSave = look == _Look.playing;
    final stopping = look == _Look.stopping || look == _Look.finalPush;
    final live = s.active;

    final buttons = MsRow(
      children: [
        if (live) ...[
          // Ctrl+S resta come scorciatoia, senza suggerimento a vista
          MsTooltip(
            message: t.saveNowTip,
            child: MsButton(
              label: t.saveNow,
              icon: const MsIcon(MsIcons.save),
              onPressed: canSave ? onSave : null,
            ),
          ),
          MsTooltip(
            message: t.stopAndSaveTip,
            child: MsButton(
              label: stopping ? t.stopping : t.stopAndSave,
              variant: MsButtonVariant.danger,
              icon: const MsIcon(MsIcons.stop),
              loading: stopping,
              onPressed: stopping || look == _Look.syncing ? null : onStop,
            ),
          ),
        ] else
          MsButton(label: t.backToServer, variant: MsButtonVariant.primary, onPressed: onBack),
      ],
    );

    return MsPanel(
      raised: true,
      semanticLabel: t.statusLabel,
      child: MsStack(
        gap: 18,
        children: [
          _HeadRow(
            buttons: buttons,
            text: MsStack(
              gap: 6,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MsRow(
                  children: [
                    Semantics(liveRegion: true, child: MsPill(pill, tone: tone, solid: true)),
                    if (since != null && live)
                      MsText.small(
                        t.sinceStarted(t.duration(now.difference(since)), hhmm(since)),
                        tone: MsTextTone.secondary,
                      ),
                  ],
                ),
                MsText(head, kind: MsTextKind.h2),
                if (sub.isNotEmpty) MsText(sub, tone: MsTextTone.secondary),
              ],
            ),
          ),
          _Steps(current: step),
        ],
      ),
    );
  }
}

/// Testo a sinistra e pulsanti a destra; sotto, se lo spazio non basta.
class _HeadRow extends StatelessWidget {
  const _HeadRow({required this.text, required this.buttons});
  final Widget text;
  final Widget buttons;

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    return LayoutBuilder(
      builder: (context, box) => box.maxWidth < g.d(820)
          ? MsStack(
              gap: 16,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [text, buttons],
            )
          : Row(
              children: [
                Expanded(child: text),
                SizedBox(width: g.d(20)),
                buttons,
              ],
            ),
    );
  }
}

/// Le sei fasi della sessione, con lo stesso indicatore dei passi del
/// wizard: fatte con la spunta, quella in corso piena, le future attenuate.
class _Steps extends StatelessWidget {
  const _Steps({required this.current});

  final int current;

  @override
  Widget build(BuildContext context) {
    final t = context.s.session;
    return MsSteps(
      semanticLabel: t.stepsLabel,
      current: current,
      steps: [
        for (final l in [t.stepSync, t.stepStart, t.stepPlay, t.stepSave, t.stepHub, t.stepStop])
          MsStep(l),
      ],
    );
  }
}

// --- avvisi recenti ---------------------------------------------------------------------

class _NoticesPanel extends StatelessWidget {
  const _NoticesPanel({required this.session});
  final SessionController session;

  @override
  Widget build(BuildContext context) {
    final t = context.s.session;
    final c = MsTheme.colorsOf(context);
    final list = session.notices.take(6).toList();
    // senza note il pannello non serve (le righe WARN sono nella console)
    if (list.isEmpty) return const SizedBox.shrink();
    return MsPanel(
      title: t.panelNotices,
      child: MsStack(
        gap: 8,
        children: [
          for (final n in list)
            MsRow(
              wrap: false,
              gap: 8,
              children: [
                MsIcon(
                  _info(n.code) ? MsIcons.info : MsIcons.warn,
                  color: _info(n.code) ? c.info : c.warn,
                ),
                Expanded(
                  child: MsText.rich([
                    MsSpan(hhmm(n.at), strong: true),
                    MsSpan('  ${t.noticeText(n.code, n.paths, context.s.common)}'),
                  ], kind: MsTextKind.small),
                ),
              ],
            ),
        ],
      ),
    );
  }

  static bool _info(String code) => code == 'keptMine' || code == 'autostop';
}

/// Avviso per un "Riprova" della porta rifiutato: i rifiuti previsti
/// dell'hub (troppo presto, nessun lock, prova spenta) sono avvisi gentili,
/// il resto è un errore.
(String, MsToastTone) portRetryNotice(AppStrings s, Object e) {
  final t = s.session;
  if (e is ApiError) {
    switch (e.code) {
      case ErrorCode.rateLimited:
        return (t.portTooSoon, MsToastTone.warn);
      case ErrorCode.notLocked:
        return (t.portNotLocked, MsToastTone.warn);
      case ErrorCode.featureOff:
        return (t.portFeatureOff, MsToastTone.warn);
      default:
        break;
    }
  }
  return (errorText(s, e), MsToastTone.err);
}

/// Esito della prova della porta fatta dall'hub verso questo PC, con
/// "Riprova". Si aggiorna da solo con l'evento `port`.
class _PortCheckRow extends StatefulWidget {
  const _PortCheckRow({required this.space, required this.check});
  final String space;
  final PortCheck check;

  @override
  State<_PortCheckRow> createState() => _PortCheckRowState();
}

class _PortCheckRowState extends State<_PortCheckRow> {
  var _busy = false;

  Future<void> _retry() async {
    final app = AppStateScope.read(context);
    final s = context.s;
    final toasts = ToastScope.of(context);
    setState(() => _busy = true);
    try {
      await app.retryPortCheck(widget.space);
      toasts.show(MsToastData(title: s.session.portRetrying, tone: MsToastTone.ok));
    } on Object catch (e) {
      final (msg, tone) = portRetryNotice(s, e);
      toasts.show(MsToastData(title: msg, tone: tone));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final t = context.s.session;
    final c = widget.check;
    final port = c.port ?? defaultMcPort;
    final at = c.checkedAt;
    final (tone, meta) = switch (c.state) {
      PortState.reachable => (
        MsStatusTone.ok,
        at == null ? null : t.portChecked(t.ago(app.now().difference(app.localTime(at)))),
      ),
      PortState.blocked => (
        MsStatusTone.err,
        at == null ? null : t.portChecked(t.ago(app.now().difference(app.localTime(at)))),
      ),
      PortState.pending => (MsStatusTone.neutral, t.portPendingMeta(port)),
      PortState.off => (MsStatusTone.neutral, t.portOffMeta),
    };
    return MsStack(
      gap: 6,
      children: [
        MsRow(
          gap: 8,
          children: [
            MsPill(t.portState(c.state.name), tone: tone),
            if (meta != null) MsText.small(meta, tone: MsTextTone.secondary),
            if (c.state != PortState.off)
              MsTooltip(
                message: t.portRetryTip,
                child: MsButton(
                  label: t.portRetry,
                  size: MsButtonSize.sm,
                  variant: MsButtonVariant.ghost,
                  icon: const MsIcon(MsIcons.refresh),
                  loading: _busy,
                  // durante la prova l'hub riprova già da solo
                  onPressed: _busy || c.state == PortState.pending ? null : _retry,
                ),
              ),
          ],
        ),
        if (c.state == PortState.blocked)
          MsText.small(t.portBlockedHint(port), tone: MsTextTone.secondary),
      ],
    );
  }
}
