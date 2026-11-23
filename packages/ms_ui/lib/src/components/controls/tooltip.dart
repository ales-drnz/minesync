// Tooltip (.ms-tooltip): fumetto in colori invertiti con punta a gradini,
// sopra al controllo; compare con l'hover (dopo una breve attesa) o con il
// focus da tastiera, sparisce con Esc.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../pixel/grid.dart';
import '../../pixel/render.dart';
import '../../pixel/text.dart';
import '../../theme.dart';
import '../../tokens.g.dart';
import 'core.dart';

/// The tooltip bubble alone (`.ms-tooltip`): inverted colours, stepped
/// pointer at the bottom-left, optional [shortcut] key (`.ms-kbd`).
class MsTooltipBubble extends StatelessWidget {
  const MsTooltipBubble({super.key, required this.message, this.shortcut});

  final String message;
  final String? shortcut;

  @override
  Widget build(BuildContext context) {
    final c = msColors(context);
    final g = PixelScope.of(context);
    return Semantics(
      container: true,
      label: shortcut == null ? message : '$message ($shortcut)',
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: g.d(284)),
        child: PixelFrame(
          outset: const EdgeInsets.fromLTRB(2, 2, 6, 8),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          repaintKey: (c.text, c.drop),
          painter: (p, w, h) {
            // ombra netta 4/6 px (traslucida, come --ms-drop)
            p.rect(6, h + 2, w, 6, c.drop);
            p.rect(w + 2, 8, 4, h - 6, c.drop);
            p.ring(0, 0, w, h, c.text);
            p.rect(0, 0, w, h, c.text);
            // punta a gradini sotto, a 16 px da sinistra
            p.rect(16, h + 2, 8, 2, c.text);
            p.rect(18, h + 4, 4, 2, c.text);
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: MsWrapText(
                  message,
                  style: msText(context, MsTextRole.sm, c.bg, weight: 600),
                ),
              ),
              if (shortcut != null) ...[const PixelGap(6, 0), _InvertedKbd(shortcut!)],
            ],
          ),
        ),
      ),
    );
  }
}

class _InvertedKbd extends StatelessWidget {
  const _InvertedKbd(this.keys);
  final String keys;

  @override
  Widget build(BuildContext context) {
    final c = msColors(context);
    return PixelFrame(
      outset: const EdgeInsets.all(2),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      minWidth: 24,
      minHeight: 20,
      centerX: true,
      repaintKey: c.panelHi,
      painter: (p, w, h) {
        p.ring(0, 0, w, h, c.pxOutline);
        p.rect(0, 0, w, h, c.panelHi);
        p.rect(0, h - 2, w, 2, c.pxShadow);
      },
      child: PixelText(
        keys,
        style: PixelTextStyle(
          font: PixelFont.mono,
          size: 14,
          lineHeight: 20,
          color: c.text,
          weight: 600,
        ),
      ),
    );
  }
}

/// Shows an [MsTooltipBubble] above [child] on hover (after [waitDuration])
/// and on keyboard focus; Escape hides it. The message is also exposed as
/// the child's semantic tooltip.
class MsTooltip extends StatefulWidget {
  const MsTooltip({
    super.key,
    required this.message,
    required this.child,
    this.shortcut,
    this.waitDuration = MsDuration.d4,
  });

  final String message;
  final String? shortcut;
  final Widget child;
  final Duration waitDuration;

  @override
  State<MsTooltip> createState() => _MsTooltipState();
}

class _MsTooltipState extends State<MsTooltip> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  Timer? _timer;
  bool _hover = false;
  bool _focus = false;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _update() {
    _timer?.cancel();
    final want = _hover || _focus;
    if (!want) {
      if (_portal.isShowing) _portal.hide();
      return;
    }
    if (_portal.isShowing) return;
    if (_focus) {
      _portal.show();
    } else {
      _timer = Timer(widget.waitDuration, () {
        if (mounted && (_hover || _focus)) _portal.show();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    return Semantics(
      tooltip: widget.message,
      child: CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _portal,
          overlayChildBuilder: (context) => CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            targetAnchor: Alignment.topLeft,
            followerAnchor: Alignment.bottomLeft,
            offset: Offset(0, -g.d(4)),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: IgnorePointer(
                child: MsTooltipBubble(message: widget.message, shortcut: widget.shortcut),
              ),
            ),
          ),
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: (v) {
              final highlight =
                  FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
              _focus = v && highlight;
              _update();
            },
            onKeyEvent: (node, e) {
              if (e is KeyDownEvent &&
                  e.logicalKey == LogicalKeyboardKey.escape &&
                  _portal.isShowing) {
                _hover = false;
                _focus = false;
                _update();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: MouseRegion(
              onEnter: (_) {
                _hover = true;
                _update();
              },
              onExit: (_) {
                _hover = false;
                _update();
              },
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
