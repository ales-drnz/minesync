// Dialoghi delle schermate dei server: forza e gioca
// con doppia conferma, scelta di Java, impostazioni del server su questo PC.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:ms_minecraft/ms_minecraft.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../l10n/l10n.dart';
import '../state/app_state.dart';
import '../state/space_state.dart';
import 'common.dart';

// --- forza e gioca ------------------------------------------------------------------

/// Doppia conferma per togliere il lock a chi lo tiene (vivo: solo admin;
/// stale: chiunque). Se confermata libera il server e porta alla sessione.
Future<void> showForceDialog(BuildContext context, String id) async {
  final app = AppStateScope.read(context);
  final strings = context.s;
  final s = strings.server;
  final d = strings.dialogs;
  final f = strings.fmt;
  final sp = app.space(id);
  final l = sp?.lock;
  if (sp == null || l == null) return;
  final now = app.now();
  final head = sp.head;
  final friends = (l.info.players.where((p) => p != l.name).length);
  // la versione si indica con l'ora, non con il numero
  final headAt = head == null ? null : app.localTime(head.ts);
  final saved = headAt == null ? null : f.ago(headAt, now);
  final safe = headAt == null || saved == null ? null : d.lastSafeValue(saved, hhmm(headAt));
  final first = MsConfirmStep(
    title: l.stale ? s.releaseTitle(sp.name) : s.forceTitle(sp.name),
    step: l.stale ? s.forceStep : s.forceStepAdmin,
    icon: const MsIcon(MsIcons.warn),
    cancelLabel: s.cancel,
    confirmLabel: s.continueLabel,
    body: MsStack(
      children: [
        MsRow(
          wrap: false,
          children: [
            MsAvatar(l.name),
            Expanded(
              child: RichLine(
                l.stale
                    ? s.releaseBody(l.name, f.duration(now.difference(app.localTime(l.lastBeat))))
                    : s.forceBody(l.name, friends),
              ),
            ),
          ],
        ),
        MsFacts([if (safe != null) MsFact(s.safeOnHub, safe), MsFact(s.risk, s.riskValue(l.name))]),
        MsText.small(l.stale ? s.releaseAdvice(l.name) : s.forceAdvice, tone: MsTextTone.secondary),
      ],
    ),
  );
  final second = MsConfirmStep(
    title: s.sureTitle,
    step: d.forceStep2,
    icon: const MsIcon(MsIcons.warn),
    cancelLabel: s.noWait,
    confirmLabel: s.yesForce,
    confirmIcon: const MsIcon(MsIcons.unlock),
    body: MsStack(
      children: [
        RichLine(s.sureBody),
        MsFacts([
          MsFact(l.name, s.disconnected(friends)),
          MsFact(s.mayLose, s.mayLoseValue),
          if (headAt != null && saved != null) MsFact(s.lastOnHub, '${hhmm(headAt)} ($saved)'),
          if (head != null) MsFact(s.then, d.thenValue(sp.name)),
        ]),
      ],
    ),
  );
  final ok = await showMsTwoStepConfirm(context: context, first: first, second: second);
  if (!ok || !context.mounted) return;
  try {
    await startPlay(app, id, force: true);
  } on Object catch (e) {
    if (context.mounted) {
      toast(context, s.forceFailed, text: errorText(strings, e), tone: MsToastTone.err);
    }
  }
}

// --- Java ---------------------------------------------------------------------------

/// Scelta del Java da usare per un server.
Future<void> showJavaDialog(BuildContext context, SpaceState ss) {
  unawaited(ss.ensureJava());
  return showMsDialog<void>(
    context: context,
    builder: (_) => JavaDialog(state: ss),
  );
}

class JavaDialog extends StatelessWidget {
  const JavaDialog({super.key, required this.state});

  final SpaceState state;

  @override
  Widget build(BuildContext context) {
    final s = context.s.server;
    final app = AppStateScope.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final list = state.javas;
        final chosen = state.java;
        final best = list == null ? null : pickJava(list, state.requiredJava);
        return MsDialog(
          title: s.javaTitle(app.space(state.id)?.name ?? state.id),
          icon: const MsIcon(MsIcons.java),
          onDismiss: () => Navigator.of(context).pop(),
          body: MsStack(
            children: [
              MsText(s.javaNeeds(state.requiredJava)),
              if (list == null)
                MsRow(children: [const MsSpinner(), MsText.small(s.javaSearching)])
              else if (list.isEmpty)
                MsAlert(
                  title: s.javaNone,
                  text: state.requiredJava > 0 ? s.javaNoneText(state.requiredJava) : null,
                  tone: MsAlertTone.warn,
                )
              else
                MsRadioGroup<String>(
                  semanticLabel: s.java,
                  value: chosen?.path ?? '',
                  options: [
                    for (final j in list)
                      MsRadioOption(
                        value: j.path,
                        title: s.javaOption(j.major),
                        description: _withNotes(app.displayPath(j.path), [
                          if (j.insideServer) s.javaInPack,
                          if (identical(j, best)) s.javaRecommended,
                        ]),
                      ),
                  ],
                  onChanged: (path) {
                    final j = list.firstWhere((j) => j.path == path);
                    state.useJava(j);
                  },
                ),
            ],
          ),
          actions: [
            MsButton(
              label: s.javaRescan,
              variant: MsButtonVariant.ghost,
              icon: const MsIcon(MsIcons.refresh),
              onPressed: state.javaLoading ? null : () => state.ensureJava(force: true),
            ),
            MsButton(
              label: s.close,
              variant: MsButtonVariant.primary,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        );
      },
    );
  }
}

// --- impostazioni del server --------------------------------------------------------

/// Cartella del server su questo PC.
Future<void> showServerSettingsDialog(BuildContext context, SpaceState ss) {
  return showMsDialog<void>(
    context: context,
    builder: (_) => ServerSettingsDialog(state: ss),
  );
}

class ServerSettingsDialog extends StatefulWidget {
  const ServerSettingsDialog({super.key, required this.state});

  final SpaceState state;

  @override
  State<ServerSettingsDialog> createState() => _ServerSettingsDialogState();
}

class _ServerSettingsDialogState extends State<ServerSettingsDialog> {
  late final _folder = TextEditingController(
    text: widget.state.folder ?? widget.state.suggestedFolder,
  );
  String? _error;

  @override
  void dispose() {
    _folder.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final path = _folder.text.trim();
    if (path.isEmpty) return;
    try {
      await widget.state.linkTo(path);
      if (mounted) Navigator.of(context).pop();
    } on Object catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s.server;
    final app = AppStateScope.of(context);
    return MsDialog(
      title: s.settingsTitle(app.space(widget.state.id)?.name ?? widget.state.id),
      icon: const MsIcon(MsIcons.gear),
      onDismiss: () => Navigator.of(context).pop(),
      body: MsField(
        label: s.folderLabel,
        help: s.folderHint,
        error: _error,
        child: MsTextInput(
          controller: _folder,
          mono: true,
          autofocus: true,
          error: _error != null,
          onSubmitted: (_) => _save(),
        ),
      ),
      actions: [
        MsButton(label: s.cancel, onPressed: () => Navigator.of(context).pop()),
        MsButton(label: s.save, variant: MsButtonVariant.primary, onPressed: _save),
      ],
    );
  }
}

// --- pulizia dell'hub (admin) ------------------------------------------------------

/// Versioni tenute per server di default, come la pulizia manuale di
/// Admin › Storia.
const gcKeepDefault = 20;

/// Scelte del dialogo (versioni da tenere per server).
const gcKeepChoices = [5, 10, 20, 50];

/// "Fai pulizia…" (admin): anteprima di cosa si toglie, conferma, pulizia e
/// notifica con il risultato.
Future<void> showGcDialog(BuildContext context) async {
  final app = AppStateScope.read(context);
  final s = context.s;
  final r = await showMsDialog<GcReport>(
    context: context,
    builder: (_) => GcDialog(preview: app.gcPreview, run: app.runGc),
  );
  if (r != null && context.mounted) {
    toast(context, s.home.gcDone(r.generations, s.fmt.size(r.bytes)));
  }
}

class GcDialog extends StatefulWidget {
  const GcDialog({super.key, required this.preview, required this.run});

  final Future<GcPreview> Function(int keep) preview;
  final Future<GcReport> Function(int keep) run;

  @override
  State<GcDialog> createState() => _GcDialogState();
}

class _GcDialogState extends State<GcDialog> {
  var _keep = gcKeepDefault;
  GcPreview? _preview;
  Object? _error;
  var _running = false;

  /// Richiesta più recente: una risposta vecchia non sovrascrive la nuova.
  var _ask = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final ask = ++_ask;
    setState(() {
      _preview = null;
      _error = null;
    });
    try {
      final p = await widget.preview(_keep);
      if (mounted && ask == _ask) setState(() => _preview = p);
    } on Object catch (e) {
      if (mounted && ask == _ask) setState(() => _error = e);
    }
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final r = await widget.run(_keep);
      if (mounted) Navigator.of(context).pop(r);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _running = false;
          _error = e;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = context.s;
    final s = strings.home;
    final f = strings.fmt;
    final p = _preview;
    final nothing = p != null && p.now == p.after;
    return MsDialog(
      title: s.gcTitle,
      icon: const MsIcon(MsIcons.trash),
      onDismiss: _running ? null : () => Navigator.of(context).pop(),
      body: MsStack(
        children: [
          MsText(s.gcText, tone: MsTextTone.secondary),
          MsField(
            label: s.gcKeep,
            child: MsSegmented<int>(
              semanticLabel: s.gcKeep,
              value: _keep,
              segments: [for (final n in gcKeepChoices) MsSegment(value: n, label: s.gcKeepN(n))],
              onChanged: _running
                  ? null
                  : (n) {
                      setState(() => _keep = n);
                      unawaited(_load());
                    },
            ),
          ),
          if (p == null && _error == null)
            MsRow(
              gap: 8,
              children: [
                const MsSpinner(),
                MsText.small(s.gcLoading, tone: MsTextTone.secondary),
              ],
            ),
          if (p != null) ...[
            MsFacts([
              MsFact(s.gcVersions, s.gcVersionsValue(p.now, p.after)),
              MsFact(s.gcFreed, f.size(p.bytes)),
              for (final r in p.spaces.where((r) => r.now != r.after || r.ownRules))
                _metaFact(r.name, [
                  s.gcVersionsValue(r.now, r.after),
                  f.size(r.bytes),
                  if (r.ownRules) s.gcOwnRules,
                ]),
            ]),
            MsText.small(nothing ? s.gcNothing : s.gcForever, tone: MsTextTone.secondary),
          ],
          if (_error != null)
            MsAlert(
              tone: MsAlertTone.err,
              icon: const MsIcon(MsIcons.warn),
              title: s.gcFailed,
              text: errorText(strings, _error!),
            ),
        ],
      ),
      actions: [
        MsButton(label: s.gcCancel, onPressed: _running ? null : () => Navigator.of(context).pop()),
        MsButton(
          label: s.gcRun,
          variant: MsButtonVariant.danger,
          icon: const MsIcon(MsIcons.trash),
          loading: _running,
          onPressed: p == null || nothing || _running ? null : _run,
        ),
      ],
    );
  }
}

/// «testo (nota, nota)»: le note tra parentesi, se ci sono.
String _withNotes(String text, List<String> notes) =>
    notes.isEmpty ? text : '$text (${notes.join(', ')})';

/// Voce di [MsFacts] con più dati brevi come etichette.
MsFact _metaFact(String term, List<String> items) =>
    MsFact(term, items.join(', '), child: MsMeta(items));
