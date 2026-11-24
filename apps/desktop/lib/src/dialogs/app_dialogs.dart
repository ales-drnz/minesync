// Dialoghi critici dell'app (canvas "AppDialogs"): ogni messaggio dice cosa
// è successo, cosa è al sicuro e cosa fare. Il pulsante a fuoco all'apertura
// è quello sicuro; Esc equivale ad Annulla.
import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:ms_core/ms_core.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../l10n/l10n.dart';
import '../state/app_state.dart';

/// Paragrafo del corpo di un dialogo.
Widget _p(String text, {MsTextTone tone = MsTextTone.primary, bool small = false}) =>
    small ? MsText.small(text, tone: tone) : MsText(text, tone: tone);

// --- 1 · conflitto ---------------------------------------------------------------

/// Dati del conflitto mostrati nel dialogo.
@immutable
final class ConflictFacts {
  const ConflictFacts({
    required this.server,
    required this.folder,
    required this.changed,
    required this.removed,
    required this.base,
    required this.head,
    this.lastAuthor,
  });

  factory ConflictFacts.of(SessionController s, {String? lastAuthor}) => ConflictFacts(
    server: s.name,
    folder: s.folder,
    changed: s.conflict?.changed.length ?? 0,
    removed: s.conflict?.removed.length ?? 0,
    base: s.conflict?.base,
    head: s.conflict?.head ?? 0,
    lastAuthor: lastAuthor,
  );

  final String server;
  final String folder;
  final int changed;
  final int removed;
  final int? base;
  final int head;

  /// Chi ha caricato l'ultima versione dell'hub (e quando), se noto.
  final String? lastAuthor;
}

/// Modifiche locali mai arrivate sull'hub, con l'hub andato avanti: tre
/// scelte. "Le mie come nuova versione" chiede una seconda conferma.
class ConflictDialog extends StatefulWidget {
  const ConflictDialog({super.key, required this.facts, required this.onChoice});

  final ConflictFacts facts;
  final ValueChanged<ConflictChoice> onChoice;

  @override
  State<ConflictDialog> createState() => _ConflictDialogState();
}

class _ConflictDialogState extends State<ConflictDialog> {
  bool _second = false;

  @override
  Widget build(BuildContext context) {
    final t = context.s.dialogs;
    final f = widget.facts;
    if (_second) {
      return MsDialog(
        key: const ValueKey('conflict2'),
        title: t.conflict2Title,
        step: t.conflict2Step,
        tone: MsDialogTone.danger,
        icon: const MsIcon(MsIcons.upload),
        onDismiss: () => setState(() => _second = false),
        body: MsStack(
          gap: 12,
          children: [
            _p(t.conflict2Text),
            MsFacts([
              MsFact(t.uploading, t.uploadingValue(f.changed, f.removed)),
              MsFact(t.replaced, t.replacedValue(f.lastAuthor)),
              MsFact(t.goBack, t.goBackValue),
            ]),
            _p(t.conflict2Hint, tone: MsTextTone.secondary, small: true),
          ],
        ),
        actions: [
          MsButton(
            label: t.noGoBack,
            autofocus: true,
            onPressed: () => setState(() => _second = false),
          ),
          MsButton(
            label: t.confirmKeepMine,
            variant: MsButtonVariant.danger,
            onPressed: () => widget.onChoice(ConflictChoice.keepMine),
          ),
        ],
      );
    }
    return MsDialog(
      key: const ValueKey('conflict1'),
      title: t.conflictTitle,
      tone: MsDialogTone.warn,
      icon: const MsIcon(MsIcons.warn),
      stackedActions: true,
      onDismiss: () => widget.onChoice(ConflictChoice.cancel),
      body: MsStack(
        gap: 12,
        children: [
          _p(t.conflictText(f.server)),
          MsFacts([MsFact(t.changedFiles, '${f.changed}'), MsFact(t.removedFiles, '${f.removed}')]),
        ],
      ),
      actions: [
        MsButton(
          label: t.useHub,
          variant: MsButtonVariant.primary,
          block: true,
          autofocus: true,
          onPressed: () => widget.onChoice(ConflictChoice.useHub),
        ),
        MsButton(
          label: t.keepMine,
          variant: MsButtonVariant.danger,
          block: true,
          onPressed: () => setState(() => _second = true),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: MsButton(label: t.cancel, onPressed: () => widget.onChoice(ConflictChoice.cancel)),
        ),
      ],
    );
  }
}

/// Mostra il dialogo del conflitto; Esc o Annulla danno [ConflictChoice.cancel].
Future<ConflictChoice> showConflictDialog(BuildContext context, ConflictFacts facts) async {
  final r = await showMsDialog<ConflictChoice>(
    context: context,
    builder: (ctx) => ConflictDialog(facts: facts, onChoice: (c) => Navigator.of(ctx).pop(c)),
  );
  return r ?? ConflictChoice.cancel;
}

// --- 3-4 · forza e gioca -------------------------------------------------------------

/// Doppia conferma per prendere il lock di un altro (senza scrivere il nome).
/// Vero solo dopo la seconda conferma.
Future<bool> showForceDialog(
  BuildContext context, {
  required String server,
  required LockHolder lock,
  GenerationSummary? head,
  DateTime? now,
}) {
  final t = context.s.dialogs;
  final ss = context.s.session;
  final friends = lock.info.players.where((p) => p != lock.name).length;
  final at = now ?? DateTime.now();
  final headAt = head == null ? null : DateTime.fromMillisecondsSinceEpoch(head.ts);
  final f = context.s.fmt;
  final ago = headAt == null || f.otherDay(headAt, at) ? null : ss.ago(at.difference(headAt));
  return showMsTwoStepConfirm(
    context: context,
    secondCancelGoesBack: false,
    first: MsConfirmStep(
      step: lock.stale ? t.forceStep1Stale : t.forceStep1,
      title: t.forceTitle(server),
      icon: const MsIcon(MsIcons.unlock),
      cancelLabel: t.cancel,
      confirmLabel: t.continueLabel,
      body: MsStack(
        gap: 12,
        children: [
          MsRow(
            wrap: false,
            children: [
              MsAvatar(lock.name, semanticLabel: ss.avatarOf(lock.name)),
              Expanded(
                child: _p(
                  lock.stale ? t.forceTextStale(lock.name) : t.forceText(lock.name, friends),
                ),
              ),
            ],
          ),
          MsFacts([
            if (headAt != null) MsFact(t.lastSafe, t.lastSafeValue(ago, f.clockOn(headAt, at))),
            MsFact(t.risk, t.riskValue(lock.name)),
          ]),
          if (!lock.stale) _p(t.forceHint, tone: MsTextTone.secondary, small: true),
        ],
      ),
    ),
    second: MsConfirmStep(
      step: t.forceStep2,
      title: t.forceTitle2,
      icon: const MsIcon(MsIcons.warn),
      cancelLabel: t.noWait,
      confirmLabel: t.yesForce,
      confirmIcon: const MsIcon(MsIcons.play),
      body: MsStack(
        gap: 12,
        children: [
          _p(t.forceText2),
          MsFacts([
            MsFact(lock.name, t.disconnected(friends)),
            MsFact(t.mayLose, t.mayLoseValue),
            if (headAt != null && ago != null) MsFact(t.lastHubSave, '${hhmm(headAt)} ($ago)'),
            if (head != null) MsFact(t.then, t.thenValue(server)),
          ]),
        ],
      ),
    ),
  );
}

// --- 5 · chiusura con sessione attiva ---------------------------------------------

/// Chiusura dell'app durante una sessione: l'arresto pulito parte da solo
/// (fino a 60 s) e il dialogo si chiude alla fine.
class QuitDialog extends StatefulWidget {
  const QuitDialog({
    super.key,
    required this.session,
    required this.onDone,
    required this.onBackground,
    this.max = const Duration(seconds: 60),
    this.autoStop = true,
  });

  final SessionController session;

  /// Sessione finita (o tempo scaduto): l'app può chiudersi.
  final VoidCallback onDone;

  /// "Continua in background": la finestra si nasconde, l'arresto prosegue.
  final VoidCallback onBackground;
  final Duration max;

  /// Avvia l'arresto all'apertura (falso nelle anteprime).
  final bool autoStop;

  @override
  State<QuitDialog> createState() => _QuitDialogState();
}

class _QuitDialogState extends State<QuitDialog> {
  @override
  void initState() {
    super.initState();
    if (widget.autoStop) {
      // dopo il primo fotogramma: l'arresto notifica subito lo stato
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(
          widget.session.stopAndWait(max: widget.max).then((_) {
            if (mounted) widget.onDone();
          }),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.s.dialogs;
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        final s = widget.session;
        final c = MsTheme.colorsOf(context);
        // fasi: avviso (subito), salvataggio (server in arresto), caricamento, rilascio
        final step = switch (s.phase) {
          SessionPhase.stopping => 1,
          SessionPhase.finalPush => 2,
          SessionPhase.ended || SessionPhase.failed || SessionPhase.cancelled => 4,
          _ => 1,
        };
        final up = s.upload;
        Widget row(int i, String label) {
          final done = i < step;
          final now = i == step;
          return MsRow(
            wrap: false,
            gap: 12,
            children: [
              SizedBox(
                width: PixelScope.of(context).d(16),
                child: done
                    ? MsIcon(MsIcons.check, color: c.ok)
                    : now
                    ? MsSpinner(color: c.accent)
                    : MsIcon(MsIcons.stop, color: c.text3),
              ),
              Expanded(
                child: MsText(label, tone: done || now ? MsTextTone.primary : MsTextTone.tertiary),
              ),
              if (now && i == 2 && up != null)
                MsText.small('${(up.fraction * 100).round()}%', tabular: true),
            ],
          );
        }

        return MsDialog(
          title: t.quitTitle,
          icon: const MsIcon(MsIcons.save),
          onDismiss: () {},
          body: MsStack(
            gap: 12,
            children: [
              _p(t.quitText(s.name)),
              Semantics(
                container: true,
                liveRegion: true,
                child: MsStack(
                  gap: 4,
                  children: [
                    row(0, t.quitStepPlayers),
                    row(1, t.quitStepSave),
                    row(2, t.quitStepUpload),
                    row(3, t.quitStepRelease),
                  ],
                ),
              ),
              if (up != null)
                MsProgress(value: up.fraction, semanticLabel: t.quitProgress)
              else
                MsProgress.indeterminate(semanticLabel: t.quitProgress),
              _p(t.quitHint, tone: MsTextTone.secondary, small: true),
            ],
          ),
          actions: [
            MsButton(
              label: t.quitBackground,
              variant: MsButtonVariant.ghost,
              onPressed: widget.onBackground,
            ),
          ],
        );
      },
    );
  }
}

/// Da collegare a `PlatformServices.window.onCloseRequested`: senza
/// sessione attiva restituisce subito vero; con una sessione mostra
/// l'arresto in corso e restituisce vero quando il mondo è sull'hub (o dopo
/// 60 s: il guard ferma comunque il server in modo pulito). "Continua in
/// background" nasconde la finestra e restituisce falso; l'app si chiude da
/// sola quando la sessione finisce se [onFinishedInBackground] lo fa.
Future<bool> confirmQuit(
  BuildContext context, {
  Duration max = const Duration(seconds: 60),
  VoidCallback? onFinishedInBackground,
}) async {
  final app = AppStateScope.read(context);
  final s = app.session;
  if (s == null || !s.active) return true;
  final r = await showMsDialog<bool>(
    context: context,
    builder: (ctx) => QuitDialog(
      session: s,
      max: max,
      onDone: () => Navigator.of(ctx).pop(true),
      onBackground: () {
        Navigator.of(ctx).pop(false);
        unawaited(app.deps.platform.window.hide());
        if (onFinishedInBackground != null) unawaited(s.done.then((_) => onFinishedInBackground()));
      },
    ),
  );
  return r ?? false;
}

// --- 2 · aggiornamento pronto ---------------------------------------------------------

class UpdateReadyDialog extends StatelessWidget {
  const UpdateReadyDialog({
    super.key,
    required this.version,
    required this.notes,
    required this.onRestart,
    required this.onLater,
  });

  final String version;
  final List<String> notes;
  final VoidCallback onRestart;
  final VoidCallback onLater;

  @override
  Widget build(BuildContext context) {
    final t = context.s.dialogs;
    return MsDialog(
      title: t.updateTitle(version),
      icon: const MsIcon(MsIcons.download),
      onDismiss: onLater,
      body: MsStack(
        gap: 12,
        children: [
          _p(t.updateText),
          if (notes.isNotEmpty)
            Semantics(
              label: t.updateNotes,
              container: true,
              child: MsStack(gap: 6, children: [for (final n in notes) MsText(n)]),
            ),
          _p(t.updateHint(version), tone: MsTextTone.secondary, small: true),
        ],
      ),
      actions: [
        MsButton(label: t.notNow, onPressed: onLater),
        MsButton(
          label: t.restartNow,
          variant: MsButtonVariant.primary,
          autofocus: true,
          onPressed: onRestart,
        ),
      ],
    );
  }
}

/// "Riavvia / Non ora". Mai durante una sessione: con un server acceso
/// restituisce falso senza mostrare niente (resta il chip nella barra).
Future<bool> showUpdateReady(
  BuildContext context, {
  required String version,
  List<String> notes = const [],
}) async {
  if (AppStateScope.read(context).hosting) return false;
  final r = await showMsDialog<bool>(
    context: context,
    builder: (ctx) => UpdateReadyDialog(
      version: version,
      notes: notes,
      onRestart: () => Navigator.of(ctx).pop(true),
      onLater: () => Navigator.of(ctx).pop(false),
    ),
  );
  return r ?? false;
}

// --- 9 · EULA ---------------------------------------------------------------------------

/// Indirizzo dell'EULA di Minecraft.
const minecraftEulaUrl = 'https://aka.ms/MinecraftEULA';

class EulaDialog extends StatelessWidget {
  const EulaDialog({super.key, required this.server, required this.onAnswer});

  final String server;
  final ValueChanged<bool> onAnswer;

  @override
  Widget build(BuildContext context) {
    final t = context.s.dialogs;
    return MsDialog(
      title: t.eulaTitle,
      icon: const MsIcon(MsIcons.shield),
      onDismiss: () => onAnswer(false),
      body: MsStack(
        gap: 12,
        children: [
          _p(t.eulaText(server)),
          MsRow(gap: 8, children: [MsText(t.eulaRead), const MsCode(minecraftEulaUrl)]),
          _p(t.eulaHint, tone: MsTextTone.secondary, small: true),
        ],
      ),
      actions: [
        MsButton(label: t.cancel, onPressed: () => onAnswer(false)),
        MsButton(
          label: t.eulaAccept,
          variant: MsButtonVariant.primary,
          autofocus: true,
          onPressed: () => onAnswer(true),
        ),
      ],
    );
  }
}

/// Chiede di accettare l'EULA; vero se accettata (l'app scrive eula=true).
Future<bool> showEulaDialog(BuildContext context, {required String server}) async {
  final r = await showMsDialog<bool>(
    context: context,
    builder: (ctx) => EulaDialog(server: server, onAnswer: (v) => Navigator.of(ctx).pop(v)),
  );
  return r ?? false;
}

// --- errori di avvio (Java mancante…) ------------------------------------------------

/// Cosa fare dopo un errore di avvio.
enum StartErrorAction { retry, settings, close }

class StartErrorDialog extends StatelessWidget {
  const StartErrorDialog({
    super.key,
    required this.server,
    required this.error,
    required this.onAction,
  });

  final String server;
  final Object error;
  final ValueChanged<StartErrorAction> onAction;

  @override
  Widget build(BuildContext context) {
    final t = context.s.dialogs;
    final e = error;
    final java = e is JavaMissing ? e.required : null;
    final text = switch (e) {
      JavaMissing(:final required) => t.javaText(server, required),
      NoLaunchFound() => t.noLaunchText,
      EulaDeclined() => t.eulaDeclinedText,
      GuardMissing() => t.guardMissingText,
      _ => t.describeError(context.s.common, e),
    };
    final disk = e is SyncException && e.kind == SyncErrorKind.localDiskFull;
    return MsDialog(
      title: java != null ? t.javaTitle(java) : t.startErrorTitle(server),
      tone: MsDialogTone.normal,
      icon: MsIcon(java != null ? MsIcons.java : (disk ? MsIcons.disk : MsIcons.warn)),
      onDismiss: () => onAction(StartErrorAction.close),
      body: MsStack(
        gap: 12,
        children: [
          _p(text),
          MsAlert(
            tone: MsAlertTone.ok,
            icon: const MsIcon(MsIcons.check),
            title: t.nothingTouched,
            text: t.nothingTouchedText,
          ),
          if (java != null) _p(t.javaHint(java), tone: MsTextTone.secondary, small: true),
        ],
      ),
      actions: [
        if (java != null)
          MsButton(
            label: t.openSettings,
            variant: MsButtonVariant.ghost,
            icon: const MsIcon(MsIcons.gear),
            onPressed: () => onAction(StartErrorAction.settings),
          ),
        MsButton(label: t.close, onPressed: () => onAction(StartErrorAction.close)),
        MsButton(
          label: t.retry,
          variant: MsButtonVariant.primary,
          icon: const MsIcon(MsIcons.refresh),
          autofocus: true,
          onPressed: () => onAction(StartErrorAction.retry),
        ),
      ],
    );
  }
}

Future<StartErrorAction> showStartError(
  BuildContext context, {
  required String server,
  required Object error,
}) async {
  final r = await showMsDialog<StartErrorAction>(
    context: context,
    builder: (ctx) =>
        StartErrorDialog(server: server, error: error, onAction: (a) => Navigator.of(ctx).pop(a)),
  );
  return r ?? StartErrorAction.close;
}

// --- 8 · crash con riavvio -------------------------------------------------------------

enum CrashAction { console, dontRestart, close }

class CrashDialog extends StatelessWidget {
  const CrashDialog({super.key, required this.server, required this.crash, required this.onAction});

  final String server;
  final CrashInfo crash;
  final ValueChanged<CrashAction> onAction;

  @override
  Widget build(BuildContext context) {
    final t = context.s.dialogs;
    final r = crash.restarting;
    return MsDialog(
      title: t.crashTitle,
      icon: const MsIcon(MsIcons.skull),
      tone: r ? MsDialogTone.normal : MsDialogTone.danger,
      onDismiss: () => onAction(CrashAction.close),
      body: MsStack(
        gap: 12,
        children: [
          _p(t.crashText(server, hhmm(crash.at), crash.savedN, r)),
          if (r)
            MsStack(
              gap: 4,
              children: [
                MsProgressMeta(
                  start: MsText.rich([
                    MsSpan(t.crashRestarting, strong: true),
                    MsSpan(' (${t.attempt(crash.attempt, crash.maxAttempts)})'),
                  ], kind: MsTextKind.small),
                ),
                MsProgress.indeterminate(
                  tone: MsProgressTone.warn,
                  semanticLabel: t.crashRestarting,
                ),
              ],
            ),
          if (crash.lastErrors.isNotEmpty)
            SizedBox(
              height: PixelScope.of(context).d(40 + 20.0 * crash.lastErrors.length),
              child: MsConsole(
                announce: false,
                wrap: false,
                liveLabel: (_) => '',
                lines: [
                  for (final l in crash.lastErrors)
                    MsConsoleLine(l, time: hhmmss(crash.at), level: 'ERR', kind: MsLineKind.err),
                ],
              ),
            ),
          if (!r) _p(t.crashConfig(server), tone: MsTextTone.secondary, small: true),
          if (crash.outOfMemory) _p(t.crashOom, tone: MsTextTone.secondary, small: true),
          if (r) _p(t.crashFriends, tone: MsTextTone.secondary, small: true),
        ],
      ),
      actions: [
        MsButton(
          label: t.console,
          variant: MsButtonVariant.ghost,
          icon: const MsIcon(MsIcons.terminal),
          onPressed: () => onAction(CrashAction.console),
        ),
        if (r)
          MsButton(label: t.dontRestart, onPressed: () => onAction(CrashAction.dontRestart))
        else
          MsButton(label: t.close, autofocus: true, onPressed: () => onAction(CrashAction.close)),
      ],
    );
  }
}

Future<CrashAction> showCrashDialog(
  BuildContext context, {
  required String server,
  required CrashInfo crash,
  ValueListenable<CrashInfo?>? latest,
}) async {
  // con [latest] il dialogo mostra sempre l'ultimo crash: un crash nuovo
  // mentre è aperto lo aggiorna invece di aprirne un altro sopra
  Widget dialog(BuildContext ctx, CrashInfo c) =>
      CrashDialog(server: server, crash: c, onAction: (a) => Navigator.of(ctx).pop(a));
  final r = await showMsDialog<CrashAction>(
    context: context,
    builder: (ctx) => latest == null
        ? dialog(ctx, crash)
        : ValueListenableBuilder<CrashInfo?>(
            valueListenable: latest,
            builder: (ctx, c, _) => dialog(ctx, c ?? crash),
          ),
  );
  return r ?? CrashAction.close;
}

// --- 10 · sessione terminata -------------------------------------------------------------

class SessionEndedDialog extends StatelessWidget {
  const SessionEndedDialog({
    super.key,
    required this.session,
    required this.onPlayAgain,
    required this.onClose,
  });

  final SessionController session;
  final VoidCallback onPlayAgain;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = context.s.dialogs;
    final ss = context.s.session;
    final s = session;
    final start = s.startedAt;
    final end = s.endedAt ?? s.now();
    final saved = s.lastSaved;
    return MsDialog(
      title: t.endedTitle,
      icon: const MsIcon(MsIcons.check),
      onDismiss: onClose,
      body: MsStack(
        gap: 12,
        children: [
          _p(t.endedText(s.name)),
          MsFacts([
            if (start != null) MsFact(t.endedDuration, ss.duration(end.difference(start))),
            if (s.seenPlayers.isNotEmpty) MsFact(t.endedPlayers, s.seenPlayers.join(', ')),
            MsFact(t.endedLastSave, saved == null ? t.endedNoSave : hhmm(saved.at)),
          ]),
        ],
      ),
      actions: [
        MsButton(label: t.close, autofocus: true, onPressed: onClose),
        MsButton(
          label: t.playAgain,
          variant: MsButtonVariant.primary,
          icon: const MsIcon(MsIcons.play),
          onPressed: onPlayAgain,
        ),
      ],
    );
  }
}

/// Esito della sessione; vero se l'utente vuole giocare ancora.
Future<bool> showSessionEnded(BuildContext context, SessionController session) async {
  final r = await showMsDialog<bool>(
    context: context,
    builder: (ctx) => SessionEndedDialog(
      session: session,
      onPlayAgain: () => Navigator.of(ctx).pop(true),
      onClose: () => Navigator.of(ctx).pop(false),
    ),
  );
  return r ?? false;
}
