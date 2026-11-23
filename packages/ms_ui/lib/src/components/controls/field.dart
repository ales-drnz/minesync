// Campo (.ms-field) con etichetta, aiuto ed errore; casella di testo
// (.ms-input, --mono) e gruppo input + pulsanti (.ms-input-group).
import 'dart:ui' show SemanticsRole, SemanticsValidationResult;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../pixel/grid.dart';
import '../../pixel/render.dart';
import '../../pixel/text.dart';
import '../../theme.dart';
import '../../tokens.g.dart';
import 'core.dart';

/// Dati del campo che lo contiene, letti dai controlli (etichetta per i
/// lettori di schermo, stato di errore).
class MsFieldScope extends InheritedWidget {
  const MsFieldScope({super.key, required this.label, required this.error, required super.child});

  final String? label;
  final String? error;

  static MsFieldScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MsFieldScope>();

  @override
  bool updateShouldNotify(MsFieldScope old) => old.label != label || old.error != error;
}

/// Form field (`.ms-field`): [label] above, [child] control, then either the
/// [error] (with the pixel cross, announced as an alert) or the [help] text.
///
/// Controls inside ([MsTextInput], [MsSelect]) take the label as their
/// semantic label and show the error look when [error] is set.
class MsField extends StatelessWidget {
  const MsField({
    super.key,
    required this.label,
    required this.child,
    this.help,
    this.error,
    this.trailingLabel,
  });

  final String label;
  final Widget child;

  /// `.ms-field__hint`.
  final String? help;

  /// `.ms-field__error`; replaces [help] when set.
  final String? error;

  /// Widget at the end of the label row (e.g. a counter "7 / 40").
  final Widget? trailingLabel;

  @override
  Widget build(BuildContext context) {
    final c = msColors(context);
    return MsFieldScope(
      label: label,
      error: error,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExcludeSemantics(
            child: Row(
              children: [
                Flexible(
                  child: PixelText(
                    label,
                    style: msText(context, MsTextRole.md, c.text, weight: 600),
                  ),
                ),
                if (trailingLabel != null) ...[const Spacer(), trailingLabel!],
              ],
            ),
          ),
          const PixelGap(0, 6),
          child,
          if (error != null) ...[
            const PixelGap(0, 6),
            MsFieldError(error!),
          ] else if (help != null) ...[
            const PixelGap(0, 6),
            MsWrapText(help!, style: msText(context, MsTextRole.sm, c.text2)),
          ],
        ],
      ),
    );
  }
}

/// Error message of a field (`.ms-field__error`), announced as an alert.
class MsFieldError extends StatelessWidget {
  const MsFieldError(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final c = msColors(context);
    final g = PixelScope.of(context);
    return Semantics(
      role: SemanticsRole.alert,
      container: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: g.d(20),
            child: Center(child: MsGlyph(MsGlyphs.errorX, color: c.err, size: 8)),
          ),
          const PixelGap(6, 0),
          Expanded(
            child: MsWrapText(message, style: msText(context, MsTextRole.sm, c.err, weight: 600)),
          ),
        ],
      ),
    );
  }
}

/// Aspetto dei campi incassati (input, select): fondo incassato, rilievo
/// interno, contorno; hover, focus con alone, errore, disattivato.
void msPaintInset(
  PixelCanvas p,
  double w,
  double h,
  MsColors c, {
  required bool hover,
  required bool focus,
  required bool error,
  required bool disabled,
}) {
  if (disabled) {
    p.ring(0, 0, w, h, c.pxOutline);
    p.rect(0, 0, w, h, c.panelHi);
    return;
  }
  if (focus) {
    p.outline(-2, -2, w + 4, h + 4, c.focusHalo);
    p.outline(0, 0, w, h, c.focusHalo, t: 2);
  }
  final ring = focus ? c.focus : (error ? c.err : (hover ? c.text3 : c.pxOutline));
  p.ring(0, 0, w, h, ring);
  p.rect(0, 0, w, h, c.inset);
  if (error && !focus) p.rect(0, h - 4, w, 4, c.errBg);
  if (focus || error) {
    // solo l'ombra interna in alto a sinistra
    p.rect(0, 0, w, 2, c.pxShadow);
    p.rect(0, 0, 2, h, c.pxShadow);
  } else {
    p.bevel(w, h, c.pxLight, c.pxShadow, inverted: true);
  }
}

/// Single-line text input (`.ms-input`, `--mono` with [mono]).
///
/// Takes the available width. Inside an [MsField] it uses the field label as
/// semantic label and the error look when the field has an error.
class MsTextInput extends StatefulWidget {
  const MsTextInput({
    super.key,
    this.controller,
    this.focusNode,
    this.placeholder,
    this.mono = false,
    this.enabled = true,
    this.error = false,
    this.obscure = false,
    this.autofocus = false,
    this.maxLength,
    this.keyboardType,
    this.onChanged,
    this.onSubmitted,
    this.semanticLabel,
    this.forcedStates,
    this.dense = false,
  });

  /// Basso come un segmentato o un pulsante piccolo (faccia 36 px), per le
  /// barre di strumenti: ricerca accanto ai filtri.
  final bool dense;

  final TextEditingController? controller;
  final FocusNode? focusNode;

  /// Placeholder shown when empty (`::placeholder`, text-3).
  final String? placeholder;
  final bool mono;
  final bool enabled;

  /// Error look (`.is-error`); also implied by the enclosing [MsField].
  final bool error;
  final bool obscure;
  final bool autofocus;
  final int? maxLength;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final String? semanticLabel;

  /// Forced look for galleries (hover / focus).
  final MsStates? forcedStates;

  @override
  State<MsTextInput> createState() => _MsTextInputState();
}

class _MsTextInputState extends State<MsTextInput> {
  TextEditingController? _ownController;
  FocusNode? _ownFocus;
  bool _hover = false;

  TextEditingController get _controller =>
      widget.controller ?? (_ownController ??= TextEditingController());
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode(debugLabel: 'MsTextInput'));

  @override
  void initState() {
    super.initState();
    _focus.addListener(_changed);
    _controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(MsTextInput old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      (old.focusNode ?? _ownFocus)?.removeListener(_changed);
      _focus.addListener(_changed);
    }
    if (old.controller != widget.controller) {
      (old.controller ?? _ownController)?.removeListener(_changed);
      _controller.addListener(_changed);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _focus.removeListener(_changed);
    _controller.removeListener(_changed);
    _ownController?.dispose();
    _ownFocus?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = msColors(context);
    final g = PixelScope.of(context);
    final scope = MsFieldScope.maybeOf(context);
    final f = widget.forcedStates;
    final enabled = widget.enabled;
    final focus = enabled && (f?.focused ?? _focus.hasFocus);
    final hover = enabled && (f?.hovered ?? _hover);
    final error = widget.error || scope?.error != null;
    final fg = enabled ? c.text : c.text3;
    final style = widget.mono
        ? PixelTextStyle(font: PixelFont.mono, size: 14, lineHeight: 24, color: fg)
        : msText(context, MsTextRole.md, fg);
    final ts = style.toTextStyle(g);

    final field = EditableText(
      controller: _controller,
      focusNode: _focus,
      readOnly: !enabled,
      autofocus: widget.autofocus,
      obscureText: widget.obscure,
      style: ts,
      cursorColor: c.text,
      cursorWidth: g.d(2),
      backgroundCursorColor: c.text3,
      selectionColor: c.sel,
      keyboardType: widget.keyboardType,
      maxLines: 1,
      inputFormatters: [
        if (widget.maxLength != null) LengthLimitingTextInputFormatter(widget.maxLength),
      ],
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      rendererIgnoresPointer: false,
    );

    final showPlaceholder = widget.placeholder != null && _controller.text.isEmpty;
    final inner = SizedBox(
      height: g.d(24),
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          if (showPlaceholder)
            ExcludeSemantics(
              child: PixelText(
                widget.placeholder!,
                style: widget.mono
                    ? style.copyWith(color: c.text3)
                    : msText(context, MsTextRole.md, c.text3),
              ),
            ),
          field,
        ],
      ),
    );

    return Semantics(
      label: widget.semanticLabel ?? scope?.label,
      hint: showPlaceholder ? widget.placeholder : null,
      validationResult: error ? SemanticsValidationResult.invalid : SemanticsValidationResult.none,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.text : SystemMouseCursors.forbidden,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: enabled ? _focus.requestFocus : null,
          child: LayoutBuilder(
            builder: (context, cons) {
              final frame = PixelFrame(
                outset: const EdgeInsets.all(2),
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: widget.dense ? 6 : 10),
                minHeight: widget.dense ? 36 : 44,
                minWidth: 88,
                repaintKey: (hover, focus, error, enabled, c.inset),
                painter: (p, w, h) => msPaintInset(
                  p,
                  w,
                  h,
                  c,
                  hover: hover,
                  focus: focus,
                  error: error,
                  disabled: !enabled,
                ),
                child: inner,
              );
              return cons.hasBoundedWidth
                  ? SizedBox(width: double.infinity, child: frame)
                  : SizedBox(width: g.d(324), child: frame);
            },
          ),
        ),
      ),
    );
  }
}

/// Input with buttons next to it (`.ms-input-group`): the input stretches,
/// the [actions] keep their size, 8 px apart, aligned to the top.
class MsInputGroup extends StatelessWidget {
  const MsInputGroup({super.key, required this.input, required this.actions});

  final Widget input;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: input),
        for (final a in actions) ...[const PixelGap(8, 0), a],
      ],
    );
  }
}
