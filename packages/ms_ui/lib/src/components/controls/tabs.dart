// Schede (.ms-tabs / .ms-tab): linguette incassate su una linea di base;
// quella scelta sale di 2 px, diventa pannello e prende l'accento in alto.
import 'dart:ui' show SemanticsRole;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../pixel/grid.dart';
import '../../pixel/render.dart';
import '../../pixel/text.dart';
import '../../theme.dart';
import 'core.dart';

/// One tab of an [MsTabs].
@immutable
final class MsTab<T> {
  const MsTab({
    required this.value,
    required this.label,
    this.count,
    this.icon,
    this.enabled = true,
  });

  final T value;
  final String label;

  /// Small counter after the label (`.ms-tab__count`), e.g. "214".
  final String? count;
  final Widget? icon;
  final bool enabled;
}

/// Tab bar (`.ms-tabs`, `role="tablist"`); takes the available width.
///
/// Only the selected tab is a Tab stop; Left/Right (Home/End) move the
/// selection, skipping disabled tabs.
class MsTabs<T> extends StatefulWidget {
  const MsTabs({
    super.key,
    required this.tabs,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
    this.forcedStates = const {},
  });

  final List<MsTab<T>> tabs;
  final T value;
  final ValueChanged<T> onChanged;
  final String? semanticLabel;
  final Map<int, MsStates> forcedStates;

  @override
  State<MsTabs<T>> createState() => _MsTabsState<T>();
}

class _MsTabsState<T> extends State<MsTabs<T>> {
  final List<FocusNode> _nodes = [];

  @override
  void dispose() {
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  void _move(int from, int dir, {bool absolute = false}) {
    final n = widget.tabs.length;
    for (var k = absolute ? 0 : 1; k <= n; k++) {
      final i = from + dir * k;
      final j = absolute ? i : ((i % n) + n) % n;
      if (j < 0 || j >= n) return;
      if (widget.tabs[j].enabled) {
        widget.onChanged(widget.tabs[j].value);
        _nodes[j].requestFocus();
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    while (_nodes.length < widget.tabs.length) {
      _nodes.add(FocusNode(debugLabel: 'MsTab ${_nodes.length}'));
    }
    final c = msColors(context);
    final sel = widget.tabs.indexWhere((t) => t.value == widget.value);
    final n = widget.tabs.length;
    return Semantics(
      role: SemanticsRole.tabBar,
      label: widget.semanticLabel,
      container: true,
      explicitChildNodes: true,
      child: LayoutBuilder(
        builder: (context, cons) {
          final bar = PixelFrame(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            repaintKey: c.pxOutline,
            painter: (p, w, h) => p.rect(0, h - 2, w, 2, c.pxOutline),
            child: Wrap(
              spacing: PixelScope.of(context).d(4),
              crossAxisAlignment: WrapCrossAlignment.end,
              children: [
                for (var i = 0; i < n; i++)
                  _tab(context, i, i == sel, skip: i != (sel < 0 ? 0 : sel)),
              ],
            ),
          );
          return cons.hasBoundedWidth ? SizedBox(width: double.infinity, child: bar) : bar;
        },
      ),
    );
  }

  Widget _tab(BuildContext context, int i, bool selected, {required bool skip}) {
    final t = widget.tabs[i];
    _nodes[i].skipTraversal = skip;
    final n = widget.tabs.length;
    return MergeSemantics(
      child: Semantics(
        role: SemanticsRole.tab,
        selected: selected,
        enabled: t.enabled,
        label: t.count == null ? t.label : '${t.label} (${t.count})',
        onTap: t.enabled ? () => widget.onChanged(t.value) : null,
        child: MsPressable(
          enabled: t.enabled,
          focusNode: _nodes[i],
          forced: widget.forcedStates[i],
          onPressed: () => widget.onChanged(t.value),
          shortcuts: {
            ...msActivateShortcuts,
            const SingleActivator(LogicalKeyboardKey.arrowRight): const _TabMove(1),
            const SingleActivator(LogicalKeyboardKey.arrowLeft): const _TabMove(-1),
            const SingleActivator(LogicalKeyboardKey.home): const _TabMove(0, to: 0),
            const SingleActivator(LogicalKeyboardKey.end): _TabMove(0, to: n - 1),
          },
          actions: {
            _TabMove: CallbackAction<_TabMove>(
              onInvoke: (m) =>
                  m.to == null ? _move(i, m.dir) : _move(m.to!, m.to == 0 ? 1 : -1, absolute: true),
            ),
          },
          builder: (context, s, _) => _look(context, t, s, selected),
        ),
      ),
    );
  }

  Widget _look(BuildContext context, MsTab<T> t, MsStates s, bool selected) {
    final c = msColors(context);
    final g = PixelScope.of(context);
    final hover = s.hovered && t.enabled && !selected;
    final fg = !t.enabled ? c.text3 : (selected || hover ? c.text : c.text2);
    final face = selected || hover ? c.panel : c.inset;
    // le linguette non scelte stanno 2 px più in basso (translateY(2px))
    final shift = selected ? 0 : g.unitPx;
    return PixelFrame(
      outset: const EdgeInsets.fromLTRB(2, 2, 2, 0),
      padding: EdgeInsets.fromLTRB(16, 10, 16, selected ? 12 : 10),
      minHeight: selected ? 46 : 44,
      centerY: true,
      childShiftPhys: shift,
      repaintKey: (face, selected, s.focused, c.accent, c.focus),
      painter: (p0, w, h) {
        final p = p0.shiftPhys(0, shift);
        p.rect(-2, 0, 2, h, c.pxOutline);
        p.rect(w, 0, 2, h, c.pxOutline);
        p.rect(0, -2, w, 2, c.pxOutline);
        p.rect(0, 0, w, h, face);
        if (selected) {
          p.rect(0, 0, 2, h, c.pxLight);
          p.rect(0, 0, w, 4, c.accent);
        } else {
          p.rect(0, 0, w, 2, c.pxShadow);
          p.rect(0, 0, 2, h, c.pxShadow);
        }
        if (s.focused) p.outline(-2, -2, w + 4, h + 4, c.focus);
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (t.icon != null) ...[
            ExcludeSemantics(child: msIconSlot(context, t.icon!, fg)),
            const PixelGap(8, 0),
          ],
          PixelText(t.label, style: msText(context, MsTextRole.md, fg, weight: 600)),
          if (t.count != null) ...[
            const PixelGap(8, 0),
            PixelText(
              t.count!,
              // stessa misura dell'etichetta (stessa linea di base), colore attenuato
              style: msText(context, MsTextRole.md, c.text3, weight: 400),
            ),
          ],
        ],
      ),
    );
  }
}

class _TabMove extends Intent {
  const _TabMove(this.dir, {this.to});
  final int dir;
  final int? to;
}
