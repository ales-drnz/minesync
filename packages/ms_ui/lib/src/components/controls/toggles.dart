// Checkbox (.ms-check), interruttore (.ms-switch), riga con etichetta
// cliccabile alta 44 px (.ms-choice) e schede radio (lista selezionabile
// con indicatore, come nelle impostazioni dell'app).
import 'dart:ui' show SemanticsRole;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../pixel/grid.dart';
import '../../pixel/render.dart';
import '../../pixel/text.dart';
import '../../theme.dart';
import '../../tokens.g.dart';
import 'core.dart';

/// Pixel checkbox (`.ms-check`, 24x24).
///
/// With [label] (and optional [description]) it becomes an `.ms-choice` row:
/// the whole 44-px-high row is clickable. Disabled when [onChanged] is null.
class MsCheckbox extends StatelessWidget {
  const MsCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
    this.description,
    this.semanticLabel,
    this.focusNode,
    this.autofocus = false,
    this.forcedStates,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? label;
  final String? description;
  final String? semanticLabel;
  final FocusNode? focusNode;
  final bool autofocus;
  final MsStates? forcedStates;

  @override
  Widget build(BuildContext context) => _Toggle(
    value: value,
    onChanged: onChanged,
    label: label,
    description: description,
    semanticLabel: semanticLabel,
    focusNode: focusNode,
    autofocus: autofocus,
    forced: forcedStates,
    isSwitch: false,
  );
}

/// Pixel switch (`.ms-switch`, 60x32): knob on the left with an "O" when
/// off, on the right with an "I" when on (never colour alone).
///
/// With [label] it becomes an `.ms-choice` row. Disabled when [onChanged]
/// is null. The knob moves in four pixel steps ([MsDuration.d2]).
class MsSwitch extends StatelessWidget {
  const MsSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
    this.description,
    this.semanticLabel,
    this.focusNode,
    this.autofocus = false,
    this.forcedStates,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? label;
  final String? description;
  final String? semanticLabel;
  final FocusNode? focusNode;
  final bool autofocus;
  final MsStates? forcedStates;

  @override
  Widget build(BuildContext context) => _Toggle(
    value: value,
    onChanged: onChanged,
    label: label,
    description: description,
    semanticLabel: semanticLabel,
    focusNode: focusNode,
    autofocus: autofocus,
    forced: forcedStates,
    isSwitch: true,
  );
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.value,
    required this.onChanged,
    required this.label,
    required this.description,
    required this.semanticLabel,
    required this.focusNode,
    required this.autofocus,
    required this.forced,
    required this.isSwitch,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? label;
  final String? description;
  final String? semanticLabel;
  final FocusNode? focusNode;
  final bool autofocus;
  final MsStates? forced;
  final bool isSwitch;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return MergeSemantics(
      child: Semantics(
        checked: isSwitch ? null : value,
        toggled: isSwitch ? value : null,
        enabled: enabled,
        label: semanticLabel ?? [label, description].whereType<String>().join(', '),
        onTap: enabled ? () => onChanged!(!value) : null,
        child: MsPressable(
          enabled: enabled,
          focusNode: focusNode,
          autofocus: autofocus,
          forced: forced,
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          },
          onPressed: enabled ? () => onChanged!(!value) : null,
          builder: (context, s, _) {
            final box = isSwitch
                ? _SwitchBox(value: value, enabled: enabled, focus: s.focused)
                : _checkBox(context, value, enabled, s.focused);
            if (label == null) return box;
            return MsChoiceRow(
              control: box,
              label: label!,
              description: description,
              enabled: enabled,
            );
          },
        ),
      ),
    );
  }
}

/// Riga `.ms-choice`: controllo + testo, alta almeno 44 px.
class MsChoiceRow extends StatelessWidget {
  const MsChoiceRow({
    super.key,
    required this.control,
    required this.label,
    this.description,
    this.enabled = true,
  });

  final Widget control;
  final String label;
  final String? description;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = msColors(context);
    final g = PixelScope.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: g.d(44)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          control,
          const PixelGap(12, 0),
          Flexible(
            child: ExcludeSemantics(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MsWrapText(
                    label,
                    style: msText(context, MsTextRole.md, enabled ? c.text : c.text3),
                  ),
                  if (description != null)
                    MsWrapText(
                      description!,
                      style: msText(context, MsTextRole.sm, enabled ? c.text2 : c.text3),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Widget _checkBox(BuildContext context, bool value, bool enabled, bool focus) {
  final c = msColors(context);
  return PixelBox(
    width: 28,
    height: 28,
    repaintKey: (value, enabled, focus, c.accent),
    painter: (p0, _, _) {
      final p = p0.shiftPhys(p0.g.unitPx, p0.g.unitPx);
      const w = 24.0, h = 24.0;
      p.ring(0, 0, w, h, c.pxOutline);
      if (!enabled) {
        p.rect(0, 0, w, h, c.panelHi);
      } else if (value) {
        p.rect(0, 0, w, h, c.accent);
        p.rect(0, 0, w, 2, c.accentHi);
        p.rect(0, h - 2, w, 2, c.accentLo);
      } else {
        p.rect(0, 0, w, h, c.inset);
        p.bevel(w, h, c.pxLight, c.pxShadow, inverted: true);
      }
      if (value) {
        final tick = enabled ? c.onAccent : c.text3;
        // spunta pixel a tratto doppio (celle 2x2 sulla griglia pari),
        // centrata nella casella: occupa x 4..20 e y 6..18
        const cells = [
          (4, 10), (6, 12), (8, 14), //
          (4, 12), (6, 14), (8, 16), //
          (10, 14), (12, 12), (14, 10), (16, 8), (18, 6), //
          (10, 16), (12, 14), (14, 12), (16, 10), (18, 8),
        ];
        for (final (x, y) in cells) {
          p.rect(x, y, 2, 2, tick);
        }
      }
      if (focus) p.outline(-4, -4, w + 8, h + 8, c.focus);
    },
  );
}

class _SwitchBox extends StatefulWidget {
  const _SwitchBox({required this.value, required this.enabled, required this.focus});

  final bool value;
  final bool enabled;
  final bool focus;

  @override
  State<_SwitchBox> createState() => _SwitchBoxState();
}

class _SwitchBoxState extends State<_SwitchBox> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: MsDuration.d2,
    value: widget.value ? 1 : 0,
  );

  @override
  void didUpdateWidget(_SwitchBox old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      if (MsTheme.reducedMotionOf(context)) {
        _c.value = widget.value ? 1 : 0;
      } else {
        widget.value ? _c.forward() : _c.reverse();
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = msColors(context);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        // steps(4, end): quattro scatti, ognuno arrotondato all'unità.
        final step = (_c.value * 4).floor().clamp(0, 4);
        final knobX = 4 + ((24 * step / 4) / 2).round() * 2.0;
        return PixelBox(
          width: 64,
          height: 40,
          repaintKey: (knobX, widget.value, widget.enabled, widget.focus, c.ok),
          painter: (p0, _, _) => _paintSwitch(
            p0.shiftPhys(p0.g.unitPx, p0.g.unitPx),
            c,
            knobX,
            widget.value,
            widget.enabled,
            widget.focus,
          ),
        );
      },
    );
  }
}

// faccia 60×36: alta come pulsanti piccoli e selettori, in fila stanno pari
void _paintSwitch(PixelCanvas p, MsColors c, double knobX, bool on, bool enabled, bool focus) {
  const w = 60.0, h = 36.0;
  p.ring(0, 0, w, h, c.pxOutline);
  if (!enabled) {
    p.rect(0, 0, w, h, c.panelHi);
  } else if (on) {
    p.rect(0, 0, w, h, c.ok);
    final shade = msBlend(const Color(0xff000000), .25, c.ok);
    p.rect(0, 0, w, 2, shade);
    p.rect(0, 0, 2, h, shade);
  } else {
    p.rect(0, 0, w, h, c.inset);
    p.bevel(w, h, c.pxLight, c.pxShadow, inverted: true);
  }
  // simbolo: "I" acceso, "O" spento
  final sym = enabled ? (on ? c.onOk : c.text2) : c.text3;
  if (on) {
    p.rect(16, 12, 2, 12, sym);
  } else {
    // anello 10x10 (il CSS lo mette a 11/9 px: arrotondato alla griglia)
    p.rect(40, 12, 10, 2, sym);
    p.rect(40, 20, 10, 2, sym);
    p.rect(40, 14, 2, 6, sym);
    p.rect(48, 14, 2, 6, sym);
  }
  // manopola
  final knob = !enabled ? c.text3 : (on ? c.panel : c.text2);
  p.rect(knobX, 4, 28, 28, knob);
  if (enabled) {
    p.rect(knobX, 4, 28, 2, msBlend(const Color(0xffffffff), .35, knob));
    p.rect(knobX, 28, 28, 4, msBlend(const Color(0xff000000), .30, knob));
  }
  if (focus) p.outline(-4, -4, w + 8, h + 8, c.focus);
}

/// One option of an [MsRadioGroup].
@immutable
final class MsRadioOption<T> {
  const MsRadioOption({
    required this.value,
    required this.title,
    this.description,
    this.trailing,
    this.enabled = true,
  });

  final T value;
  final String title;
  final String? description;

  /// Extra control on the row (e.g. a slider or an input for this option).
  final Widget? trailing;
  final bool enabled;
}

/// Radio cards: a sunken list (`.ms-list`) of selectable rows, each with a
/// square radio indicator, title and description. Only the selected row is
/// a Tab stop; arrows move the selection.
class MsRadioGroup<T> extends StatefulWidget {
  const MsRadioGroup({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
    this.forcedStates = const {},
  });

  final List<MsRadioOption<T>> options;
  final T? value;
  final ValueChanged<T>? onChanged;
  final String? semanticLabel;
  final Map<int, MsStates> forcedStates;

  @override
  State<MsRadioGroup<T>> createState() => _MsRadioGroupState<T>();
}

class _MsRadioGroupState<T> extends State<MsRadioGroup<T>> {
  final List<FocusNode> _nodes = [];

  @override
  void dispose() {
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  void _move(int from, int dir) {
    final n = widget.options.length;
    for (var k = 1; k <= n; k++) {
      final i = ((from + dir * k) % n + n) % n;
      if (widget.options[i].enabled) {
        widget.onChanged?.call(widget.options[i].value);
        _nodes[i].requestFocus();
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    while (_nodes.length < widget.options.length) {
      _nodes.add(FocusNode(debugLabel: 'MsRadio ${_nodes.length}'));
    }
    final c = msColors(context);
    final sel = widget.options.indexWhere((o) => o.value == widget.value);
    final stop = sel >= 0 ? sel : widget.options.indexWhere((o) => o.enabled);
    return Semantics(
      role: SemanticsRole.radioGroup,
      label: widget.semanticLabel,
      container: true,
      child: PixelFrame(
        outset: const EdgeInsets.all(2),
        padding: const EdgeInsets.all(4),
        repaintKey: (c.inset, c.pxOutline),
        painter: (p, w, h) {
          p.ring(0, 0, w, h, c.pxOutline);
          p.rect(0, 0, w, h, c.inset);
          p.bevel(w, h, c.pxLight, c.pxShadow, inverted: true);
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < widget.options.length; i++) ...[
              if (i > 0) const PixelGap(0, 2),
              _row(context, i, i == sel, skip: i != stop),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, int i, bool selected, {required bool skip}) {
    final o = widget.options[i];
    final enabled = widget.onChanged != null && o.enabled;
    _nodes[i].skipTraversal = skip;
    return MergeSemantics(
      child: Semantics(
        inMutuallyExclusiveGroup: true,
        checked: selected,
        enabled: enabled,
        label: [o.title, o.description].whereType<String>().join(', '),
        onTap: enabled ? () => widget.onChanged!(o.value) : null,
        child: MsPressable(
          enabled: enabled,
          focusNode: _nodes[i],
          forced: widget.forcedStates[i],
          onPressed: () => widget.onChanged?.call(o.value),
          shortcuts: {
            ...msActivateShortcuts,
            const SingleActivator(LogicalKeyboardKey.arrowDown): const _Step(1),
            const SingleActivator(LogicalKeyboardKey.arrowRight): const _Step(1),
            const SingleActivator(LogicalKeyboardKey.arrowUp): const _Step(-1),
            const SingleActivator(LogicalKeyboardKey.arrowLeft): const _Step(-1),
          },
          actions: {_Step: CallbackAction<_Step>(onInvoke: (s) => _move(i, s.dir))},
          builder: (context, st, _) => _look(context, o, st, selected, enabled),
        ),
      ),
    );
  }

  Widget _look(BuildContext context, MsRadioOption<T> o, MsStates st, bool sel, bool enabled) {
    final c = msColors(context);
    final hover = st.hovered && enabled && !sel;
    final bg = sel ? c.sel : (hover ? c.panelHi : c.panel);
    final title = !enabled ? c.text3 : (sel ? c.selText : c.text);
    final meta = !enabled ? c.text3 : (sel ? c.selText : c.text2);
    return PixelFrame(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      minHeight: 56,
      centerY: true,
      repaintKey: (bg, sel, st.focused, c.accent),
      painter: (p, w, h) {
        p.rect(0, 0, w, h, bg);
        p.rect(0, h - 2, w, 2, c.pxShadow);
        if (sel) p.rect(0, 0, 6, h, c.accent);
        if (st.focused) p.outline(6, 6, w - 12, h - 12, c.focus);
      },
      child: Row(
        children: [
          PixelBox(
            width: 24,
            height: 24,
            repaintKey: (sel, enabled, c.accent),
            painter: (p0, _, _) {
              final p = p0.shiftPhys(p0.g.unitPx, p0.g.unitPx);
              p.ring(0, 0, 20, 20, c.pxOutline);
              p.rect(0, 0, 20, 20, c.inset);
              p.bevel(20, 20, c.pxLight, c.pxShadow, inverted: true);
              if (sel) p.rect(6, 6, 8, 8, enabled ? c.accent : c.text3);
            },
          ),
          const PixelGap(14, 0),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PixelText(o.title, style: msText(context, MsTextRole.md, title, weight: 600)),
                if (o.description != null)
                  ExcludeSemantics(
                    child: MsWrapText(o.description!, style: msText(context, MsTextRole.sm, meta)),
                  ),
              ],
            ),
          ),
          if (o.trailing != null) ...[const PixelGap(14, 0), o.trailing!],
        ],
      ),
    );
  }
}

class _Step extends Intent {
  const _Step(this.dir);
  final int dir;
}
