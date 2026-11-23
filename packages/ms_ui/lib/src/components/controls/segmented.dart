// Gruppo segmentato (.ms-seg): scelta singola tra poche opzioni (IT/EN,
// tipo di server). Gruppo radio con focus "a rotazione" e frecce.
import 'dart:ui' show SemanticsRole;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../pixel/render.dart';
import '../../pixel/text.dart';
import '../../theme.dart';
import 'core.dart';

/// One option of an [MsSegmented].
@immutable
final class MsSegment<T> {
  const MsSegment({required this.value, required this.label, this.icon, this.semanticLabel});

  final T value;
  final String label;
  final Widget? icon;
  final String? semanticLabel;
}

/// Segmented single-choice group (`.ms-seg`, `role="radiogroup"`).
///
/// Only the selected segment is a Tab stop; arrow keys move the selection,
/// Home/End jump to the ends. Disabled when [onChanged] is null.
class MsSegmented<T> extends StatefulWidget {
  const MsSegmented({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
    this.forcedStates = const {},
  });

  final List<MsSegment<T>> segments;
  final T value;
  final ValueChanged<T>? onChanged;

  /// Group name for screen readers (`aria-label`).
  final String? semanticLabel;

  /// Forced look per segment index (galleries).
  final Map<int, MsStates> forcedStates;

  @override
  State<MsSegmented<T>> createState() => _MsSegmentedState<T>();
}

class _MsSegmentedState<T> extends State<MsSegmented<T>> {
  final List<FocusNode> _nodes = [];

  void _syncNodes() {
    while (_nodes.length < widget.segments.length) {
      _nodes.add(FocusNode(debugLabel: 'MsSegment ${_nodes.length}'));
    }
    while (_nodes.length > widget.segments.length) {
      _nodes.removeLast().dispose();
    }
  }

  @override
  void dispose() {
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  int get _selected => widget.segments.indexWhere((s) => s.value == widget.value);

  void _move(int to) {
    final n = widget.segments.length;
    final i = (to % n + n) % n;
    widget.onChanged?.call(widget.segments[i].value);
    _nodes[i].requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    _syncNodes();
    final c = msColors(context);
    final sel = _selected;
    final enabled = widget.onChanged != null;
    final cur = sel < 0 ? 0 : sel;
    return Semantics(
      role: SemanticsRole.radioGroup,
      label: widget.semanticLabel,
      container: true,
      child: PixelFrame(
        outset: const EdgeInsets.all(2),
        padding: const EdgeInsets.all(2),
        repaintKey: (c.inset, c.pxOutline, c.pxLight, c.pxShadow),
        painter: (p, w, h) {
          p.ring(0, 0, w, h, c.pxOutline);
          p.rect(0, 0, w, h, c.inset);
          p.bevel(w, h, c.pxLight, c.pxShadow, inverted: true);
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < widget.segments.length; i++)
              _segment(context, i, i == sel, enabled, skip: i != cur),
          ],
        ),
      ),
    );
  }

  Widget _segment(BuildContext context, int i, bool selected, bool enabled, {required bool skip}) {
    final s = widget.segments[i];
    _nodes[i].skipTraversal = skip;
    final n = widget.segments.length;
    return MergeSemantics(
      child: Semantics(
        inMutuallyExclusiveGroup: true,
        checked: selected,
        enabled: enabled,
        label: s.semanticLabel ?? s.label,
        onTap: enabled ? () => widget.onChanged!(s.value) : null,
        child: MsPressable(
          enabled: enabled,
          focusNode: _nodes[i],
          forced: widget.forcedStates[i],
          onPressed: () => widget.onChanged?.call(s.value),
          shortcuts: {
            ...msActivateShortcuts,
            const SingleActivator(LogicalKeyboardKey.arrowRight): _MoveIntent(i + 1),
            const SingleActivator(LogicalKeyboardKey.arrowDown): _MoveIntent(i + 1),
            const SingleActivator(LogicalKeyboardKey.arrowLeft): _MoveIntent(i - 1),
            const SingleActivator(LogicalKeyboardKey.arrowUp): _MoveIntent(i - 1),
            const SingleActivator(LogicalKeyboardKey.home): const _MoveIntent(0),
            const SingleActivator(LogicalKeyboardKey.end): _MoveIntent(n - 1),
          },
          actions: {_MoveIntent: CallbackAction<_MoveIntent>(onInvoke: (m) => _move(m.to))},
          builder: (context, st, _) => _look(context, s, st, selected, enabled),
        ),
      ),
    );
  }

  Widget _look(BuildContext context, MsSegment<T> s, MsStates st, bool selected, bool enabled) {
    final c = msColors(context);
    final hover = st.hovered && enabled && !selected;
    final fg = !enabled ? c.text3 : (selected || hover ? c.text : c.text2);
    final bg = selected ? c.panelHi : (hover ? c.panel : null);
    final focus = st.focused;
    return PixelFrame(
      // con il bordo interno di 2 px la faccia è alta 36, come un pulsante
      // piccolo: messi in fila hanno la stessa altezza
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      minWidth: 44,
      minHeight: 32,
      centerX: true,
      centerY: true,
      repaintKey: (bg, selected, focus, c.accent, c.focus),
      painter: (p, w, h) {
        if (bg != null) p.rect(0, 0, w, h, bg);
        if (selected) {
          p.rect(0, h - 4, w, 4, c.accent);
          p.bevel(w, h, c.pxLight, c.pxShadow);
        }
        if (focus) p.outline(-2, -2, w + 4, h + 4, c.focus);
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (s.icon != null) ...[
            ExcludeSemantics(child: msIconSlot(context, s.icon!, fg)),
            const PixelGap(6, 0),
          ],
          PixelText(s.label, style: msText(context, MsTextRole.sm, fg, weight: 600)),
        ],
      ),
    );
  }
}

class _MoveIntent extends Intent {
  const _MoveIntent(this.to);
  final int to;
}
