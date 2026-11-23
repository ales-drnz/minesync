// Menu di azioni (.ms-menu): un pulsante che apre, nell'Overlay sopra la
// pagina, un elenco di azioni con icona. Stesso pannello del menu di
// MsSelect; si usa anche da tastiera.
import 'dart:ui' show SemanticsRole;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../icons/icons.dart';
import '../../pixel/grid.dart';
import '../../pixel/render.dart';
import '../../pixel/text.dart';
import '../../theme.dart';
import 'button.dart';
import 'core.dart';

/// One action of an [MsMenuButton]; disabled when [onSelected] is null.
@immutable
final class MsMenuItem {
  const MsMenuItem({required this.label, this.icon, this.onSelected, this.danger = false});

  final String label;
  final Widget? icon;
  final VoidCallback? onSelected;

  /// Destructive action (error colour).
  final bool danger;

  bool get enabled => onSelected != null;
}

/// Button that opens a menu of actions (`.ms-menu`).
///
/// The trigger is an [MsButton] ([label], [icon], [variant], [size]). Open:
/// Up/Down (Home/End) move the highlight, Enter/Space run the highlighted
/// action, Escape or Tab close. The menu is aligned to the trigger's right
/// edge ([alignEnd]) or left edge.
class MsMenuButton extends StatefulWidget {
  const MsMenuButton({
    super.key,
    required this.label,
    required this.items,
    this.icon,
    this.variant = MsButtonVariant.secondary,
    this.size = MsButtonSize.sm,
    this.alignEnd = true,
    this.menuWidth = 260,
    this.semanticLabel,
  });

  final String label;
  final List<MsMenuItem> items;
  final Widget? icon;
  final MsButtonVariant variant;
  final MsButtonSize size;
  final bool alignEnd;

  /// Width of the menu in design px.
  final double menuWidth;
  final String? semanticLabel;

  @override
  State<MsMenuButton> createState() => _MsMenuButtonState();
}

class _MsMenuButtonState extends State<MsMenuButton> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  // il menu aperto prende il focus: frecce, Invio ed Esc arrivano qui anche
  // se il pulsante non l'aveva
  final _menuFocus = FocusNode(debugLabel: 'MsMenuButton menu');
  int _highlight = -1;

  @override
  void dispose() {
    _menuFocus.dispose();
    super.dispose();
  }

  bool get _open => _portal.isShowing;

  int _next(int from, int dir) {
    final n = widget.items.length;
    for (var k = 1; k <= n; k++) {
      final i = from + dir * k;
      if (i < 0 || i >= n) break;
      if (widget.items[i].enabled) return i;
    }
    return from;
  }

  void _show() {
    if (_open || widget.items.every((i) => !i.enabled)) return;
    setState(() => _highlight = _next(-1, 1));
    _portal.show();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_open) _menuFocus.requestFocus();
    });
  }

  void _hide() {
    if (!_open) return;
    _portal.hide();
    setState(() {});
  }

  void _run(int i) {
    if (i < 0 || i >= widget.items.length || !widget.items[i].enabled) return;
    _hide();
    widget.items[i].onSelected!();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (!_open || (e is! KeyDownEvent && e is! KeyRepeatEvent)) return KeyEventResult.ignored;
    final k = e.logicalKey;
    void hl(int i) => setState(() => _highlight = i);
    if (k == LogicalKeyboardKey.arrowDown) {
      hl(_next(_highlight, 1));
    } else if (k == LogicalKeyboardKey.arrowUp) {
      hl(_next(_highlight, -1));
    } else if (k == LogicalKeyboardKey.home) {
      hl(_next(-1, 1));
    } else if (k == LogicalKeyboardKey.end) {
      hl(_next(widget.items.length, -1));
    } else if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.space) {
      _run(_highlight);
    } else if (k == LogicalKeyboardKey.escape) {
      _hide();
    } else if (k == LogicalKeyboardKey.tab) {
      _hide();
      return KeyEventResult.ignored;
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: Semantics(
        expanded: _open,
        child: CompositedTransformTarget(
          link: _link,
          child: OverlayPortal(
            controller: _portal,
            overlayChildBuilder: (context) => Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: _hide),
                ),
                Focus(
                  focusNode: _menuFocus,
                  onKeyEvent: _onKey,
                  onFocusChange: (v) {
                    if (!v) _hide();
                  },
                  child: CompositedTransformFollower(
                    link: _link,
                    showWhenUnlinked: false,
                    targetAnchor: widget.alignEnd ? Alignment.bottomRight : Alignment.bottomLeft,
                    followerAnchor: widget.alignEnd ? Alignment.topRight : Alignment.topLeft,
                    offset: Offset(0, g.d(12)),
                    child: SizedBox(
                      width: g.d(widget.menuWidth),
                      child: _Menu(
                        items: widget.items,
                        highlight: _highlight,
                        onHover: (i) => setState(() => _highlight = i),
                        onRun: _run,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            child: MsButton(
              label: widget.label,
              icon: widget.icon,
              variant: widget.variant,
              size: widget.size,
              semanticLabel: widget.semanticLabel,
              trailing: const MsIcon(MsIcons.chevDown),
              onPressed: widget.items.any((i) => i.enabled) ? (_open ? _hide : _show) : null,
            ),
          ),
        ),
      ),
    );
  }
}

class _Menu extends StatelessWidget {
  const _Menu({
    required this.items,
    required this.highlight,
    required this.onHover,
    required this.onRun,
  });

  final List<MsMenuItem> items;
  final int highlight;
  final ValueChanged<int> onHover;
  final ValueChanged<int> onRun;

  @override
  Widget build(BuildContext context) {
    final c = msColors(context);
    return Semantics(
      role: SemanticsRole.menu,
      container: true,
      child: PixelFrame(
        outset: const EdgeInsets.fromLTRB(2, 2, 8, 8),
        padding: const EdgeInsets.all(4),
        repaintKey: (c.panel, c.drop),
        painter: (p, w, h) {
          p.rect(6, 6, w, h, c.drop);
          p.ring(0, 0, w, h, c.pxOutline);
          p.rect(0, 0, w, h, c.panel);
          p.bevel(w, h, c.pxLight, c.pxShadow);
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [for (var i = 0; i < items.length; i++) _row(context, i)],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, int i) {
    final c = msColors(context);
    final g = PixelScope.of(context);
    final it = items[i];
    final hl = i == highlight && it.enabled;
    final fg = !it.enabled ? c.text3 : (it.danger ? c.err : c.text);
    return Semantics(
      role: SemanticsRole.menuItem,
      container: true,
      enabled: it.enabled,
      label: it.label,
      onTap: it.enabled ? () => onRun(i) : null,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: it.enabled ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
        onEnter: (_) => onHover(i),
        child: GestureDetector(
          onTap: () => onRun(i),
          child: PixelFrame(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            minHeight: 44,
            repaintKey: (hl, c.panelHi),
            painter: (p, w, h) {
              if (hl) p.rect(0, 0, w, h, c.panelHi);
            },
            child: Row(
              children: [
                if (it.icon != null) ...[
                  IconTheme(
                    data: IconThemeData(color: fg),
                    child: it.icon!,
                  ),
                  SizedBox(width: g.d(10)),
                ],
                Expanded(child: PixelText(it.label, style: msText(context, MsTextRole.md, fg))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
