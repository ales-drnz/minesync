// Componenti di ms.css resi con le primitive pixel: GIOCA, pannello, slot,
// barra a lingotti, console. Misure in px di design copiate dal CSS.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../pixel/grid.dart';
import '../pixel/render.dart';
import '../pixel/text.dart';
import 'icons.dart';
import 'tokens.dart';

// ---------------------------------------------------------------- testo
abstract final class MsText {
  static const label = PixelTextStyle(
      font: PixelFont.silkscreen, size: 16, lineHeight: 24, color: Ms.text, uppercase: true);
  static const body = PixelTextStyle(
      font: PixelFont.pixelify, size: 16, lineHeight: 24, color: Ms.text);
  static const mono = PixelTextStyle(
      font: PixelFont.mono, size: 14, lineHeight: 20, color: Ms.conText);
}

// ---------------------------------------------------------------- GIOCA
/// Stato visivo forzato (per i mockup e i golden).
@immutable
class BtnLook {
  const BtnLook({this.hover = false, this.pressed = false, this.focus = false});
  final bool hover;
  final bool pressed;
  final bool focus;
}

/// Pulsante GIOCA: "blocco estruso" con faccia, filo di luce, frangia d'erba,
/// lato inferiore di 6 px che diventa 4 px premuto (la faccia scende di 2 px).
/// L'animazione di pressione avanza a scatti di pixel FISICI interi.
class MsPlayButton extends StatefulWidget {
  const MsPlayButton({super.key, this.label = 'Gioca', this.onPressed, this.forced});
  final String label;
  final VoidCallback? onPressed;
  final BtnLook? forced;

  @override
  State<MsPlayButton> createState() => _MsPlayButtonState();
}

class _MsPlayButtonState extends State<MsPlayButton> with SingleTickerProviderStateMixin {
  late final AnimationController _press = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 80));
  bool _hover = false;
  bool _down = false;
  bool _focus = false;

  @override
  void initState() {
    super.initState();
    if (widget.forced?.pressed ?? false) _press.value = 1;
  }

  @override
  void didUpdateWidget(MsPlayButton old) {
    super.didUpdateWidget(old);
    if (widget.forced != null) _press.value = widget.forced!.pressed ? 1 : 0;
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  void _setDown(bool v) {
    if (_down == v) return;
    setState(() => _down = v);
    if (v) {
      _press.animateTo(1, curve: const Cubic(.2, .8, .2, 1));
    } else {
      _press.animateBack(0, curve: const Cubic(.2, .8, .2, 1));
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.forced;
    final hover = f?.hover ?? _hover;
    final focus = f?.focus ?? _focus;
    final pressed = f?.pressed ?? _down;
    final g = PixelScope.of(context);
    return FocusableActionDetector(
      onShowFocusHighlight: (v) => setState(() => _focus = v),
      onShowHoverHighlight: (v) => setState(() => _hover = v),
      mouseCursor: SystemMouseCursors.click,
      shortcuts: const {SingleActivator(LogicalKeyboardKey.enter): ActivateIntent()},
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onPressed?.call();
          return null;
        }),
      },
      child: GestureDetector(
        onTapDown: (_) => _setDown(true),
        onTapUp: (_) {
          _setDown(false);
          widget.onPressed?.call();
        },
        onTapCancel: () => _setDown(false),
        child: AnimatedBuilder(
          animation: _press,
          builder: (context, child) {
            // 2 px di design = 1 unità = unitPx pixel fisici: si arrotonda
            // al pixel fisico, quindi nessuna posizione frazionaria.
            final shift = (_press.value * g.unitPx).round();
            return PixelFrame(
              minWidth: 240,
              minHeight: 72,
              padding: const EdgeInsets.fromLTRB(32, 16, 40, 16),
              outset: const EdgeInsets.fromLTRB(6, 6, 6, 8),
              childShiftPhys: shift,
              repaintKey: (shift, hover, focus, pressed),
              painter: (c, w, h) => _paintPlay(c, w, h, shift,
                  hover: hover || pressed, focus: focus, pressed: pressed),
              child: child,
            );
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const PixelIcon(MsIcons.play, size: 32, color: Ms.onAccent),
              const PixelGap(16, 0),
              PixelText(widget.label,
                  style: const PixelTextStyle(
                      font: PixelFont.silkscreen,
                      size: 32,
                      lineHeight: 40,
                      weight: 700,
                      color: Ms.onAccent,
                      uppercase: true)),
            ],
          ),
        ),
      ),
    );
  }
}

void _paintPlay(PixelCanvas c0, double w, double h, int shift,
    {required bool hover, required bool focus, required bool pressed}) {
  final g = c0.g;
  final u = g.unitPx;
  final face = hover ? Ms.accentHover : Ms.accent;
  final c = c0.shiftPhys(0, shift);
  // lato: 6 px di design (3 unità) che si accorcia di quanto scende la faccia
  final sidePhys = 3 * u - shift;
  final wP = (g.d(w) * g.dpr).round();
  final hP = (g.d(h) * g.dpr).round();
  // contorno della faccia (angoli smussati) e del lato
  c.rect(-2, 0, 2, h, Ms.pxOutline); // sinistra
  c.rect(w, 0, 2, h, Ms.pxOutline); // destra
  c.rect(0, -2, w, 2, Ms.pxOutline); // sopra
  c.rectPhys(-u, hP, u, sidePhys, Ms.pxOutline);
  c.rectPhys(wP, hP, u, sidePhys, Ms.pxOutline);
  c.rectPhys(0, hP + sidePhys, wP, u, Ms.pxOutline);
  c.rectPhys(0, hP, wP, sidePhys, Ms.accentLo); // lato
  c.rect(0, 0, w, h, face); // faccia
  c.rect(0, 0, w, 2, Ms.accentHi); // filo di luce
  // frangia d'erba (::before, opacità .9 / .5 premuto) già composta sulla faccia
  final grass = Ms.blend(Ms.accentHi, face, pressed ? .5 : .9);
  void row(double y, List<List<int>> segs) {
    for (var x0 = 0; x0 < w; x0 += 32) {
      for (final s in segs) {
        final a = x0 + s[0];
        final b = (x0 + s[1]).clamp(0, w);
        if (b > a) c.rect(a, y, b - a, 2, grass);
      }
    }
  }

  row(4, const [[0, 6], [10, 12], [22, 26]]);
  row(6, const [[2, 4], [22, 24]]);
  if (focus) c.outline(-4, -4, w + 8, h + 8, Ms.focus);
}

// ---------------------------------------------------------------- pannello
class MsPanel extends StatelessWidget {
  const MsPanel({super.key, required this.title, required this.child, this.raised = false});
  final String title;
  final Widget child;
  final bool raised;

  @override
  Widget build(BuildContext context) {
    return PixelFrame(
      outset: raised
          ? const EdgeInsets.fromLTRB(2, 2, 6, 6)
          : const EdgeInsets.all(2),
      repaintKey: raised,
      painter: (c, w, h) {
        if (raised) c.rect(6, 6, w, h, Ms.drop);
        c.ring(0, 0, w, h, Ms.pxOutline);
        c.rect(0, 0, w, h, Ms.panel);
        c.bevel(w, h, Ms.pxLight, Ms.pxShadow);
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PixelFrame(
            minHeight: 48,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            centerY: true,
            painter: (c, w, h) {
              c.rect(0, 0, w, h, Ms.panelHi);
              c.rect(0, h - 2, w, 2, Ms.pxShadow);
              c.rect(w - 2, 0, 2, h, Ms.pxShadow);
              c.rect(0, 0, w, 2, Ms.pxLight);
              c.rect(0, 0, 2, h, Ms.pxLight);
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PixelBox(
                  width: 8,
                  height: 8,
                  painter: (c, w, h) {
                    c.rect(2, 2, 8, 8, Ms.accentLo);
                    c.rect(0, 0, 8, 8, Ms.accent);
                  },
                ),
                const PixelGap(10, 0),
                PixelText(title, style: MsText.label),
              ],
            ),
          ),
          PixelFrame(
            padding: const EdgeInsets.all(20),
            painter: (c, w, h) {},
            child: child,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- slot
class MsSlot extends StatelessWidget {
  const MsSlot({super.key, required this.child, this.square = false});
  final Widget child;
  final bool square;

  @override
  Widget build(BuildContext context) {
    return PixelFrame(
      padding: EdgeInsets.all(square ? 4 : 12),
      minWidth: square ? 56 : 0,
      minHeight: square ? 56 : 0,
      centerX: square,
      centerY: square,
      painter: (c, w, h) {
        c.rect(0, 0, w, h, Ms.inset);
        c.bevel(w, h, Ms.pxLight, Ms.pxShadow, inverted: true);
      },
      child: child,
    );
  }
}

// ---------------------------------------------------------------- barra a lingotti
class MsProgress extends StatelessWidget {
  const MsProgress({super.key, required this.value, this.width = 320});
  final double value; // 0..1
  final double width; // px di design

  @override
  Widget build(BuildContext context) {
    return PixelBox(
      width: width + 4,
      height: 28,
      repaintKey: value,
      painter: (c0, w0, h0) {
        final c = c0.shiftPhys(c0.g.unitPx, c0.g.unitPx); // margine 2 per il ring
        final w = width;
        const h = 24.0;
        c.ring(0, 0, w, h, Ms.pxOutline);
        c.rect(0, 0, w, h, Ms.inset);
        c.bevel(w, h, Ms.pxLight, Ms.pxShadow, inverted: true);
        // lingotti 10 + 2, riempimento arrotondato all'unità (2 px)
        final inner = w - 8;
        final fill = ((inner * value.clamp(0, 1)) / 2).round() * 2.0;
        for (double x = 0; x < fill; x += 12) {
          final sw = (fill - x).clamp(0.0, 10.0);
          c.rect(4 + x, 4, sw, 16, Ms.accent);
          c.rect(4 + x, 4, sw, 4, Ms.accentHi);
        }
      },
    );
  }
}

// ---------------------------------------------------------------- console
enum LineKind { info, ok, join, warn, err, cmd, dim }

@immutable
class ConsoleLine {
  const ConsoleLine(this.time, this.kind, this.text);
  final String time;
  final LineKind kind;
  final String text;
}

class MsConsole extends StatelessWidget {
  const MsConsole({super.key, required this.lines, this.height = 400, this.controller});
  final List<ConsoleLine> lines;
  final double height; // px di design
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    return PixelFrame(
      outset: const EdgeInsets.all(2),
      padding: const EdgeInsets.all(2),
      painter: (c, w, h) {
        c.ring(0, 0, w, h, Ms.pxOutline);
        c.rect(0, 0, w, h, Ms.conBg);
        c.bevel(w, h, Ms.pxLight, Ms.pxShadow, inverted: true);
      },
      child: SizedBox(
        height: g.d(height),
        child: ListView.builder(
          key: const Key('console-list'),
          controller: controller,
          padding: EdgeInsets.symmetric(vertical: g.d(12)),
          itemExtent: g.d(20),
          itemCount: lines.length,
          itemBuilder: (context, i) => _LineView(lines[i]),
        ),
      ),
    );
  }
}

class _LineView extends StatelessWidget {
  const _LineView(this.line);
  final ConsoleLine line;

  @override
  Widget build(BuildContext context) {
    final (Color fg, Color lvl, Color? bg, String tag) = switch (line.kind) {
      LineKind.info => (Ms.conText, Ms.conInfo, null, 'INFO'),
      LineKind.ok => (Ms.conOk, Ms.conDim, null, 'OK'),
      LineKind.join => (Ms.conJoin, Ms.conDim, null, 'JOIN'),
      LineKind.warn => (Ms.conWarn, Ms.conWarn, Ms.conWarnBg, 'WARN'),
      LineKind.err => (Ms.conErr, Ms.conErr, Ms.conErrBg, 'ERR'),
      LineKind.cmd => (Ms.conCmd, Ms.conCmd, null, 'CMD'),
      LineKind.dim => (Ms.conDim, Ms.conDim, null, 'DBG'),
    };
    final bar = bg == null ? null : lvl;
    return PixelFrame(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      repaintKey: line,
      painter: (c, w, h) {
        if (bg != null) c.rect(0, 0, w, h, bg);
        if (bar != null) c.rect(0, 0, 4, h, bar);
      },
      child: Row(
        children: [
          SizedBox(
              width: PixelScope.of(context).d(76),
              child: PixelText(line.time, style: MsText.mono.copyWith(color: Ms.conDim))),
          const PixelGap(12, 0),
          SizedBox(
              width: PixelScope.of(context).d(56),
              child: PixelText(tag, style: MsText.mono.copyWith(color: lvl, weight: 700))),
          const PixelGap(12, 0),
          Expanded(
              child: PixelText(line.text,
                  style: MsText.mono.copyWith(
                      color: fg, weight: line.kind == LineKind.cmd ? 700 : 400))),
        ],
      ),
    );
  }
}

/// 2000 righe deterministiche (nessun dato reale).
List<ConsoleLine> demoLines(int n) {
  const msgs = <(LineKind, String)>[
    (LineKind.info, 'Preparazione area di spawn: {p}%'),
    (LineKind.info, 'Caricamento regione r.{a}.{b}.mca'),
    (LineKind.join, 'Giocatore_{a} è entrato nel mondo'),
    (LineKind.ok, 'Salvataggio completato in {p} ms'),
    (LineKind.warn, 'Il server è in ritardo di {p}0 ms (tick saltati: {a})'),
    (LineKind.err, 'Errore nel chunk [{a}, {b}]: dati corrotti, rigenerato'),
    (LineKind.cmd, '> /time set day'),
    (LineKind.dim, 'GC: liberati {p} MB in {a} ms'),
    (LineKind.info, 'Mod caricata: esempio-mod-{a} v1.{b}.0'),
    (LineKind.join, 'Giocatore_{b} ha lasciato il mondo'),
  ];
  var seed = 12345;
  int rnd(int m) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed % m;
  }

  return List.generate(n, (i) {
    final (k, m) = msgs[rnd(msgs.length)];
    final s = i * 7;
    final t = '${(12 + s ~/ 3600 % 12).toString().padLeft(2, '0')}:'
        '${(s ~/ 60 % 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
    return ConsoleLine(
        t,
        k,
        m
            .replaceAll('{p}', '${rnd(100)}')
            .replaceAll('{a}', '${rnd(64)}')
            .replaceAll('{b}', '${rnd(64)}'));
  });
}
