// Menu a tendina (.ms-select): campo incassato con freccia a gradini; il
// menu si apre nell'Overlay sopra la pagina (livello MsZ.dropdown) e si
// usa anche da tastiera.
import 'dart:ui' show SemanticsRole;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../pixel/grid.dart';
import '../../pixel/render.dart';
import '../../pixel/text.dart';
import '../../theme.dart';
import 'core.dart';
import 'field.dart';

/// One option of an [MsSelect].
@immutable
final class MsSelectOption<T> {
  const MsSelectOption({required this.value, required this.label, this.enabled = true});

  final T value;
  final String label;
  final bool enabled;
}

/// Dropdown select (`.ms-select`).
///
/// Closed: Enter, Space, Alt+Down, Up or Down open the menu. Open: Up/Down
/// (and Home/End) move the highlight, typing a letter jumps to the next
/// option starting with it, Enter/Space choose, Escape or Tab close. The menu
/// is shown in the nearest [Overlay], above the page (`MsZ.dropdown`), with
/// the selected option highlighted. Disabled when [onChanged] is null.
class MsSelect<T> extends StatefulWidget {
  const MsSelect({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.placeholder,
    this.semanticLabel,
    this.focusNode,
    this.autofocus = false,
    this.forcedStates,
  });

  final List<MsSelectOption<T>> options;
  final T? value;
  final ValueChanged<T>? onChanged;

  /// Shown when [value] matches no option.
  final String? placeholder;
  final String? semanticLabel;
  final FocusNode? focusNode;
  final bool autofocus;
  final MsStates? forcedStates;

  @override
  State<MsSelect<T>> createState() => _MsSelectState<T>();
}

class _MsSelectState<T> extends State<MsSelect<T>> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  FocusNode? _ownFocus;
  int _highlight = -1;
  bool _hover = false;
  bool _focused = false;

  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode(debugLabel: 'MsSelect'));

  bool get _enabled => widget.onChanged != null;
  int get _selected => widget.options.indexWhere((o) => o.value == widget.value);

  @override
  void dispose() {
    _ownFocus?.dispose();
    super.dispose();
  }

  void _open() {
    if (!_enabled || _portal.isShowing) return;
    setState(() => _highlight = _selected >= 0 ? _selected : _next(-1, 1));
    _portal.show();
  }

  void _close() {
    if (!_portal.isShowing) return;
    _portal.hide();
    setState(() {});
  }

  void _choose(int i) {
    if (i < 0 || !widget.options[i].enabled) return;
    _close();
    widget.onChanged?.call(widget.options[i].value);
  }

  int _next(int from, int dir) {
    final n = widget.options.length;
    for (var k = 1; k <= n; k++) {
      final i = from + dir * k;
      if (i < 0 || i >= n) break;
      if (widget.options[i].enabled) return i;
    }
    return from;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final open = _portal.isShowing;
    if (!open) {
      if (k == LogicalKeyboardKey.enter ||
          k == LogicalKeyboardKey.numpadEnter ||
          k == LogicalKeyboardKey.space ||
          k == LogicalKeyboardKey.arrowDown ||
          k == LogicalKeyboardKey.arrowUp) {
        _open();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    void hl(int i) => setState(() => _highlight = i);
    if (k == LogicalKeyboardKey.arrowDown) {
      hl(_next(_highlight, 1));
    } else if (k == LogicalKeyboardKey.arrowUp) {
      hl(_next(_highlight, -1));
    } else if (k == LogicalKeyboardKey.home) {
      hl(_next(-1, 1));
    } else if (k == LogicalKeyboardKey.end) {
      hl(_next(widget.options.length, -1));
    } else if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.space) {
      _choose(_highlight);
    } else if (k == LogicalKeyboardKey.escape) {
      _close();
    } else if (k == LogicalKeyboardKey.tab) {
      _close();
      return KeyEventResult.ignored;
    } else if (e.character != null && e.character!.trim().isNotEmpty) {
      final ch = e.character!.toLowerCase();
      final n = widget.options.length;
      for (var d = 1; d <= n; d++) {
        final i = (_highlight + d) % n;
        final o = widget.options[i];
        if (o.enabled && o.label.toLowerCase().startsWith(ch)) {
          hl(i);
          break;
        }
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final c = msColors(context);
    final g = PixelScope.of(context);
    final scope = MsFieldScope.maybeOf(context);
    final f = widget.forcedStates;
    final enabled = _enabled;
    final focus = enabled && (f?.focused ?? _focused);
    final hover = enabled && (f?.hovered ?? _hover);
    final error = scope?.error != null;
    final sel = _selected;
    final text = sel >= 0 ? widget.options[sel].label : (widget.placeholder ?? '');
    final fg = !enabled ? c.text3 : (sel >= 0 ? c.text : c.text3);
    final open = _portal.isShowing;

    final field = PixelFrame(
      outset: const EdgeInsets.all(2),
      padding: const EdgeInsets.fromLTRB(12, 10, 44, 10),
      minHeight: 44,
      minWidth: 88,
      repaintKey: (hover, focus, error, enabled, fg, c.inset),
      painter: (p, w, h) {
        msPaintInset(p, w, h, c, hover: hover, focus: focus, error: error, disabled: !enabled);
        // freccia a gradini 10x6 a 16 px dal bordo destro
        final ax = w - 16 - 10;
        final ay = (h / 2 - 3).roundToDouble();
        final ay2 = ay % 2 == 1 ? ay + 1 : ay;
        final col = enabled ? c.text : c.text3;
        p.rect(ax, ay2, 10, 2, col);
        p.rect(ax + 2, ay2 + 2, 6, 2, col);
        p.rect(ax + 4, ay2 + 4, 2, 2, col);
      },
      child: PixelText(text, style: msText(context, MsTextRole.md, fg)),
    );

    return Semantics(
      button: true,
      enabled: enabled,
      expanded: open,
      label: widget.semanticLabel ?? scope?.label,
      value: text,
      onTap: enabled ? (open ? _close : _open) : null,
      child: CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _portal,
          overlayChildBuilder: (context) => _menu(context, g),
          child: Focus(
            focusNode: _focus,
            autofocus: widget.autofocus,
            canRequestFocus: enabled,
            onKeyEvent: _onKey,
            onFocusChange: (v) {
              setState(() => _focused = v);
              if (!v) _close();
            },
            child: MouseRegion(
              cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
              onEnter: (_) => setState(() => _hover = true),
              onExit: (_) => setState(() => _hover = false),
              child: GestureDetector(
                onTap: enabled
                    ? () {
                        _focus.requestFocus();
                        open ? _close() : _open();
                      }
                    : null,
                child: LayoutBuilder(
                  builder: (context, cons) =>
                      cons.hasBoundedWidth ? SizedBox(width: double.infinity, child: field) : field,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _menu(BuildContext context, PixelGrid g) {
    final box = this.context.findRenderObject() as RenderBox?;
    final width = box != null && box.hasSize ? box.size.width : g.d(240);
    return Stack(
      children: [
        // clic fuori: chiude
        Positioned.fill(
          child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: _close),
        ),
        CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          targetAnchor: Alignment.bottomLeft,
          offset: Offset(0, g.d(4)),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: _MsSelectMenu(
                options: widget.options,
                selected: _selected,
                highlight: _highlight,
                onHover: (i) => setState(() => _highlight = i),
                onChoose: _choose,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Menu delle opzioni: pannello con rilievo, contorno e ombra netta; riga
/// evidenziata panel-hi, opzione scelta con la barra d'accento.
class _MsSelectMenu<T> extends StatelessWidget {
  const _MsSelectMenu({
    required this.options,
    required this.selected,
    required this.highlight,
    required this.onHover,
    required this.onChoose,
  });

  final List<MsSelectOption<T>> options;
  final int selected;
  final int highlight;
  final ValueChanged<int> onHover;
  final ValueChanged<int> onChoose;

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
          children: [for (var i = 0; i < options.length; i++) _row(context, i)],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, int i) {
    final c = msColors(context);
    final o = options[i];
    final sel = i == selected;
    final hl = i == highlight && o.enabled;
    final fg = !o.enabled ? c.text3 : (sel ? c.selText : c.text);
    final bg = sel ? c.sel : (hl ? c.panelHi : null);
    return Semantics(
      role: SemanticsRole.menuItem,
      container: true,
      selected: sel,
      enabled: o.enabled,
      label: o.label,
      onTap: o.enabled ? () => onChoose(i) : null,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: o.enabled ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
        onEnter: (_) => onHover(i),
        child: GestureDetector(
          onTap: () => onChoose(i),
          child: PixelFrame(
            padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
            minHeight: 44,
            repaintKey: (bg, sel, hl, c.accent),
            painter: (p, w, h) {
              if (bg != null) p.rect(0, 0, w, h, bg);
              if (sel) p.rect(0, 0, 6, h, c.accent);
              if (hl && sel) p.outline(2, 2, w - 4, h - 4, c.focus);
            },
            child: PixelText(o.label, style: msText(context, MsTextRole.md, fg)),
          ),
        ),
      ),
    );
  }
}
