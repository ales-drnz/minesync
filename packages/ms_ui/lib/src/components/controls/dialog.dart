// Dialoghi (.ms-dialog, --danger) sopra lo scrim (.ms-scrim), apertura
// con l'animazione "pop" e i due schemi di conferma decisi nel design:
// doppia conferma a pulsante e "scrivi il nome per confermare" (solo per
// le eliminazioni irreversibili). Esc equivale sempre ad Annulla; il
// pulsante a fuoco all'apertura è quello sicuro.
import 'dart:ui' show SemanticsRole;
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../pixel/grid.dart';
import '../../pixel/render.dart';
import '../../pixel/text.dart';
import '../../theme.dart';
import '../../tokens.g.dart';
import 'button.dart';
import 'core.dart';
import 'field.dart';

/// Tone of an [MsDialog].
enum MsDialogTone {
  /// Plain dialog (`role="dialog"`).
  normal,

  /// `--danger`: red head band, error icon (`role="alertdialog"`).
  danger,

  /// Warning (conflicts): warn outline and head (`role="alertdialog"`).
  warn,
}

/// Full-area scrim (`.ms-scrim`) centring [child] with 24 px of margin.
class MsScrim extends StatelessWidget {
  const MsScrim({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = msColors(context);
    return ColoredBox(
      color: c.scrim,
      child: Padding(
        padding: EdgeInsets.all(PixelScope.of(context).d(24)),
        child: Center(child: child),
      ),
    );
  }
}

/// Dialog window (`.ms-dialog`): head with [icon] and [title], [body]
/// (with the optional red [step] eyebrow, `.ms-dialog__step`), footer with
/// [actions] aligned to the end (or stacked full width with
/// [stackedActions]) and the optional [leadingActions] at the start, e.g. a
/// destructive "Remove…" kept apart from "Close". Max 560 px wide.
///
/// Escape calls [onDismiss] (or pops the route). Show it with
/// [showMsDialog].
class MsDialog extends StatelessWidget {
  const MsDialog({
    super.key,
    required this.title,
    required this.body,
    required this.actions,
    this.icon,
    this.tone = MsDialogTone.normal,
    this.step,
    this.stackedActions = false,
    this.leadingActions = const [],
    this.onDismiss,
  });

  final String title;
  final Widget body;
  final List<Widget> actions;
  final Widget? icon;
  final MsDialogTone tone;

  /// Eyebrow above the body, e.g. "Conferma 1 di 2" / "Ultima chiamata · 2 di 2".
  final String? step;
  final bool stackedActions;

  /// Actions at the start of the footer, apart from [actions] (at the end).
  /// In a narrow dialog everything wraps, [actions] still at the end.
  /// Ignored with [stackedActions].
  final List<Widget> leadingActions;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final c = msColors(context);
    final g = PixelScope.of(context);
    final ring = tone == MsDialogTone.warn ? c.warn : c.pxOutline;
    final headBg = switch (tone) {
      MsDialogTone.normal => c.panelHi,
      MsDialogTone.danger => c.errBg,
      MsDialogTone.warn => c.warnBg,
    };
    final iconColor = switch (tone) {
      MsDialogTone.normal => c.text,
      MsDialogTone.danger => c.err,
      MsDialogTone.warn => c.warn,
    };
    final danger = tone == MsDialogTone.danger;

    final head = PixelFrame(
      padding: EdgeInsets.fromLTRB(20, danger ? 18 : 14, 20, 14),
      repaintKey: (headBg, danger, c.err),
      painter: (p, w, h) {
        p.rect(0, 0, w, h, headBg);
        if (danger) {
          p.rect(0, 0, w, 6, c.err);
        } else {
          p.rect(0, 0, w, 2, c.pxLight);
          p.rect(0, 0, 2, h, c.pxLight);
        }
        p.rect(0, h - 2, w, 2, c.pxShadow);
      },
      child: Row(
        children: [
          if (icon != null) ...[
            ExcludeSemantics(child: msIconSlot(context, icon!, iconColor, size: 24)),
            const PixelGap(12, 0),
          ],
          Expanded(
            child: Semantics(
              header: true,
              child: MsWrapText(title, style: msText(context, MsTextRole.h3, c.text, weight: 600)),
            ),
          ),
        ],
      ),
    );

    final bodyBox = Padding(
      padding: EdgeInsets.all(g.d(20)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (step != null) ...[
            PixelText(
              msSentenceCase(step!),
              style: msText(context, MsTextRole.label, c.err).copyWith(size: 14, lineHeight: 20),
            ),
            const PixelGap(0, 16),
          ],
          DefaultTextStyle.merge(
            style: msText(context, MsTextRole.md, c.text).toTextStyle(g),
            child: body,
          ),
        ],
      ),
    );

    final foot = PixelFrame(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      repaintKey: c.pxShadow,
      painter: (p, w, h) => p.rect(0, 0, w, 2, c.pxShadow),
      child: stackedActions
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < actions.length; i++) ...[
                  if (i > 0) const PixelGap(0, 4),
                  actions[i],
                ],
              ],
            )
          : leadingActions.isEmpty
          ? Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: g.d(12),
                runSpacing: g.d(4),
                children: actions,
              ),
            )
          : _SplitFoot(leading: leadingActions, trailing: actions),
    );

    return Semantics(
      role: tone == MsDialogTone.normal ? SemanticsRole.dialog : SemanticsRole.alertDialog,
      label: title,
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      child: Shortcuts(
        shortcuts: const {SingleActivator(LogicalKeyboardKey.escape): DismissIntent()},
        child: Actions(
          actions: {
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (_) {
                if (onDismiss != null) {
                  onDismiss!();
                } else {
                  Navigator.maybeOf(context)?.maybePop();
                }
                return null;
              },
            ),
          },
          child: FocusTraversalGroup(
            child: LayoutBuilder(
              builder: (context, cons) {
                final max = g.d(560 + 12);
                final w = cons.hasBoundedWidth ? math.min(cons.maxWidth, max) : max;
                return SizedBox(
                  width: w,
                  child: PixelFrame(
                    outset: const EdgeInsets.fromLTRB(2, 2, 10, 10),
                    repaintKey: (ring, c.panel, c.drop),
                    painter: (p, w, h) {
                      p.rect(8, 8, w, h, c.drop);
                      p.ring(0, 0, w, h, ring);
                      p.rect(0, 0, w, h, c.panel);
                      p.bevel(w, h, c.pxLight, c.pxShadow);
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [head, bodyBox, foot],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Piede con azioni a sinistra e a destra. Largo: una riga, a sinistra le
/// [leading] (che vanno a capo tra loro se serve) e a destra le [trailing];
/// stretto (sotto 360 px): un Wrap allineato a destra, prima le [leading].
class _SplitFoot extends StatelessWidget {
  const _SplitFoot({required this.leading, required this.trailing});

  final List<Widget> leading;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    Wrap group(List<Widget> children, {WrapAlignment alignment = WrapAlignment.start}) => Wrap(
      alignment: alignment,
      spacing: g.d(12),
      runSpacing: g.d(4),
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
    return LayoutBuilder(
      builder: (context, cons) {
        if (cons.maxWidth < g.d(360)) {
          return Align(
            alignment: Alignment.centerRight,
            child: group([...leading, ...trailing], alignment: WrapAlignment.end),
          );
        }
        return Row(
          children: [
            // fa da Spacer: spinge le azioni principali a destra
            Expanded(
              child: Align(alignment: Alignment.centerLeft, child: group(leading)),
            ),
            SizedBox(width: g.d(12)),
            group(trailing, alignment: WrapAlignment.end),
          ],
        );
      },
    );
  }
}

/// Pushes a dialog route: scrim ([MsColors.scrim]), focus trapped in the
/// dialog, entry animation `ms-pop` (8 px up + fade, [MsDuration.d3],
/// none with reduced motion). The tap on the scrim closes only when
/// [barrierDismissible]; Escape is handled by [MsDialog].
Future<T?> showMsDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = false,
  String? barrierLabel,
}) {
  final reduced = MsTheme.reducedMotionOf(context);
  final theme = MsTheme.of(context);
  final c = theme.colors;
  return Navigator.of(context).push<T>(
    RawDialogRoute<T>(
      barrierColor: c.scrim,
      barrierDismissible: barrierDismissible,
      barrierLabel: barrierLabel,
      transitionDuration: reduced ? Duration.zero : MsDuration.d3,
      pageBuilder: (context, _, _) => MsTheme(
        data: theme,
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.all(PixelScope.of(context).d(24)),
            child: Center(child: Builder(builder: builder)),
          ),
        ),
      ),
      transitionBuilder: (context, anim, _, child) {
        if (reduced) return child;
        final t = msEaseOut.transform(anim.value);
        final g = PixelScope.of(context);
        // 8 px verso l'alto a scatti di unità intere
        final dy = g.roundToUnit(g.d(8) * (1 - t));
        return Opacity(
          opacity: t,
          child: Transform.translate(offset: Offset(0, dy), child: child),
        );
      },
    ),
  );
}

/// Content of one confirmation step.
@immutable
final class MsConfirmStep {
  const MsConfirmStep({
    required this.title,
    required this.body,
    required this.cancelLabel,
    required this.confirmLabel,
    this.step,
    this.icon,
    this.confirmIcon,
  });

  final String title;
  final Widget body;
  final String cancelLabel;
  final String confirmLabel;

  /// Eyebrow, e.g. "Conferma 1 di 2" / "Ultima chiamata · 2 di 2".
  final String? step;
  final Widget? icon;
  final Widget? confirmIcon;
}

/// Two-step confirmation: [first] asks, its confirm button ("Continua…")
/// shows [second] with the concrete summary; only the second confirm calls
/// [onConfirm]. Cancel (or Escape) calls [onCancel]; on the second step it
/// goes back to the first when [secondCancelGoesBack]. The cancel button
/// has the initial focus (Enter never triggers the risky action by
/// accident).
class MsTwoStepConfirm extends StatefulWidget {
  const MsTwoStepConfirm({
    super.key,
    required this.first,
    required this.second,
    required this.onConfirm,
    required this.onCancel,
    this.tone = MsDialogTone.danger,
    this.secondCancelGoesBack = false,
  });

  final MsConfirmStep first;
  final MsConfirmStep second;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;
  final MsDialogTone tone;
  final bool secondCancelGoesBack;

  @override
  State<MsTwoStepConfirm> createState() => _MsTwoStepConfirmState();
}

class _MsTwoStepConfirmState extends State<MsTwoStepConfirm> {
  bool _second = false;

  void _cancel() {
    if (_second && widget.secondCancelGoesBack) {
      setState(() => _second = false);
    } else {
      widget.onCancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _second ? widget.second : widget.first;
    return MsDialog(
      key: ValueKey(_second),
      title: s.title,
      icon: s.icon,
      step: s.step,
      tone: widget.tone,
      body: s.body,
      onDismiss: _cancel,
      actions: [
        MsButton(label: s.cancelLabel, autofocus: true, onPressed: _cancel),
        MsButton(
          label: s.confirmLabel,
          icon: s.confirmIcon,
          variant: widget.tone == MsDialogTone.normal
              ? MsButtonVariant.primary
              : MsButtonVariant.danger,
          onPressed: _second ? widget.onConfirm : () => setState(() => _second = true),
        ),
      ],
    );
  }
}

/// Shows an [MsTwoStepConfirm]; completes with true only after the second
/// confirmation.
Future<bool> showMsTwoStepConfirm({
  required BuildContext context,
  required MsConfirmStep first,
  required MsConfirmStep second,
  MsDialogTone tone = MsDialogTone.danger,
  bool secondCancelGoesBack = false,
}) async {
  final r = await showMsDialog<bool>(
    context: context,
    builder: (ctx) => MsTwoStepConfirm(
      first: first,
      second: second,
      tone: tone,
      secondCancelGoesBack: secondCancelGoesBack,
      onConfirm: () => Navigator.of(ctx).pop(true),
      onCancel: () => Navigator.of(ctx).pop(false),
    ),
  );
  return r ?? false;
}

/// "Type the name to confirm" dialog, reserved for irreversible deletes.
///
/// The field label reads [promptBefore] `expected` [promptAfter] (the name
/// in a code chip, e.g. "Scrivi `Survival` per confermare"); the danger
/// button is enabled only when the typed text equals [expected] exactly.
/// The field has the initial focus; Enter confirms only when it matches.
class MsTypeToConfirmDialog extends StatefulWidget {
  const MsTypeToConfirmDialog({
    super.key,
    required this.title,
    required this.body,
    required this.expected,
    required this.promptBefore,
    required this.promptAfter,
    required this.cancelLabel,
    required this.confirmLabel,
    required this.onConfirm,
    required this.onCancel,
    this.step,
    this.help,
    this.icon,
    this.confirmIcon,
    this.initialText = '',
  });

  final String title;
  final Widget body;
  final String expected;
  final String promptBefore;
  final String promptAfter;
  final String cancelLabel;
  final String confirmLabel;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;
  final String? step;

  /// Hint under the field, e.g. "Il pulsante si attiva quando il nome coincide."
  final String? help;
  final Widget? icon;
  final Widget? confirmIcon;

  /// Pre-filled text (galleries).
  final String initialText;

  @override
  State<MsTypeToConfirmDialog> createState() => _MsTypeToConfirmDialogState();
}

class _MsTypeToConfirmDialogState extends State<MsTypeToConfirmDialog> {
  late final _ctl = TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  bool get _match => _ctl.text == widget.expected;

  @override
  Widget build(BuildContext context) {
    final c = msColors(context);
    final prompt = '${widget.promptBefore}${widget.expected}${widget.promptAfter}';
    return MsDialog(
      title: widget.title,
      icon: widget.icon,
      step: widget.step,
      tone: MsDialogTone.danger,
      onDismiss: widget.onCancel,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          widget.body,
          const PixelGap(0, 16),
          ExcludeSemantics(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (widget.promptBefore.isNotEmpty)
                  PixelText(
                    widget.promptBefore,
                    style: msText(context, MsTextRole.md, c.text, weight: 600),
                  ),
                _Code(widget.expected),
                if (widget.promptAfter.isNotEmpty)
                  PixelText(
                    widget.promptAfter,
                    style: msText(context, MsTextRole.md, c.text, weight: 600),
                  ),
              ],
            ),
          ),
          const PixelGap(0, 6),
          MsTextInput(
            controller: _ctl,
            autofocus: true,
            semanticLabel: prompt,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (_match) widget.onConfirm();
            },
          ),
          if (widget.help != null) ...[
            const PixelGap(0, 6),
            MsWrapText(widget.help!, style: msText(context, MsTextRole.sm, c.text2)),
          ],
        ],
      ),
      actions: [
        MsButton(label: widget.cancelLabel, onPressed: widget.onCancel),
        MsButton(
          label: widget.confirmLabel,
          icon: widget.confirmIcon,
          variant: MsButtonVariant.danger,
          onPressed: _match ? widget.onConfirm : null,
        ),
      ],
    );
  }
}

/// Shows an [MsTypeToConfirmDialog]; completes with true when confirmed.
Future<bool> showMsTypeToConfirm({
  required BuildContext context,
  required String title,
  required Widget body,
  required String expected,
  required String promptBefore,
  required String promptAfter,
  required String cancelLabel,
  required String confirmLabel,
  String? step,
  String? help,
  Widget? icon,
  Widget? confirmIcon,
}) async {
  final r = await showMsDialog<bool>(
    context: context,
    builder: (ctx) => MsTypeToConfirmDialog(
      title: title,
      body: body,
      expected: expected,
      promptBefore: promptBefore,
      promptAfter: promptAfter,
      cancelLabel: cancelLabel,
      confirmLabel: confirmLabel,
      step: step,
      help: help,
      icon: icon,
      confirmIcon: confirmIcon,
      onConfirm: () => Navigator.of(ctx).pop(true),
      onCancel: () => Navigator.of(ctx).pop(false),
    ),
  );
  return r ?? false;
}

/// Codice in linea (.ms-code) per il nome da digitare.
class _Code extends StatelessWidget {
  const _Code(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = msColors(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: PixelScope.of(context).d(6)),
      child: PixelFrame(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        repaintKey: c.inset,
        painter: (p, w, h) {
          p.rect(0, 0, w, h, c.inset);
          p.bevel(w, h, c.pxLight, c.pxShadow, inverted: true);
        },
        child: PixelText(
          text,
          style: PixelTextStyle(
            font: PixelFont.mono,
            size: 14,
            lineHeight: 20,
            color: c.text,
            weight: 500,
          ),
        ),
      ),
    );
  }
}
