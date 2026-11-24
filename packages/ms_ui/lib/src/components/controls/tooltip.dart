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
  const MsTooltipBubble({
    super.key,
    required this.message,
    this.shortcut,
    this.tailRight = false,
    this.tailUp = false,
    this.tailCenter,
  });

  /// Distanza in px di design del centro della punta dal lato da cui parte
  /// la nuvoletta (il centro del controllo); di default 20.
  final double? tailCenter;

  final String message;
  final String? shortcut;

  /// Punta verso destra (nuvoletta allineata al bordo destro del controllo).
  final bool tailRight;

  /// Punta in alto (nuvoletta sotto il controllo).
  final bool tailUp;

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
          outset: EdgeInsets.fromLTRB(2, tailUp ? 6 : 2, 6, 8),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          repaintKey: (c.text, c.drop, tailRight, tailUp),
          painter: (p, w, h) {
            // ombra netta 4/6 px (traslucida, come --ms-drop)
            p.rect(6, h + 2, w, 6, c.drop);
            p.rect(w + 2, 8, 4, h - 6, c.drop);
            p.ring(0, 0, w, h, c.text);
            p.rect(0, 0, w, h, c.text);
            // punta a gradini a 16 px dal lato da cui parte la nuvoletta,
            // sotto o sopra secondo dove sta il controllo
            // punta larga 8: si centra su [tailCenter], misurato dal bordo
            // della nuvoletta senza l'ombra
            final at = (((tailCenter ?? 20) - 4) / 2).roundToDouble() * 2;
            final x = (tailRight ? w - at - 8 : at).clamp(4.0, w - 12);
            if (tailUp) {
              p.rect(x, -4, 8, 2, c.text);
              p.rect(x + 2, -6, 4, 2, c.text);
            } else {
              p.rect(x, h + 2, 8, 2, c.text);
              p.rect(x + 2, h + 4, 4, 2, c.text);
            }
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
          overlayChildBuilder: (overlay) {
            // dentro la finestra: nella metà destra si allinea al bordo destro
            // del pulsante e si apre verso sinistra; senza spazio sopra va sotto
            final box = context.findRenderObject() as RenderBox?;
            final screen = MediaQuery.sizeOf(overlay);
            final pos = box != null && box.hasSize ? box.localToGlobal(Offset.zero) : Offset.zero;
            final right = box != null && pos.dx + box.size.width / 2 > screen.width / 2;
            final below = pos.dy < g.d(48);
            final x = right ? 1.0 : -1.0;
            // centro del controllo misurato dal bordo della nuvoletta: a
            // destra c'è l'ombra (6), a sinistra il bordo (2)
            final tw = box != null && box.hasSize ? box.size.width / g.d(1) : 40.0;
            final center = tw / 2 - (right ? 6 : 2);
            return CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              targetAnchor: Alignment(x, below ? 1 : -1),
              followerAnchor: Alignment(x, below ? -1 : 1),
              offset: Offset(0, below ? g.d(4) : -g.d(4)),
              child: Align(
                alignment: Alignment(x, below ? -1 : 1),
                child: IgnorePointer(
                  child: MsTooltipBubble(
                    message: widget.message,
                    shortcut: widget.shortcut,
                    tailRight: right,
                    tailUp: below,
                    tailCenter: center,
                  ),
                ),
              ),
            );
          },
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
