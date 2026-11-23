// Aiuti interni ai componenti di visualizzazione: composizione dei colori
// semitrasparenti del CSS in colori pieni, contorni tratteggiati, larghezza
// arrotondata all'unità e gestione di hover/focus/pressione.
//
// Non esportato dal barrel: i componenti pubblici lo usano internamente.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../pixel/grid.dart';
import '../../pixel/render.dart';
import '../../theme.dart';

/// Compone [fg] (con opacità aggiuntiva [opacity]) su [bg] e restituisce un
/// colore pieno: il pixel look non ammette fusioni lasciate al motore.
Color msBlend(Color fg, Color bg, [double opacity = 1]) =>
    Color.alphaBlend(opacity >= 1 ? fg : fg.withValues(alpha: fg.a * opacity), bg);

/// Contorni aggiuntivi su [PixelCanvas].
extension MsPixelCanvasX on PixelCanvas {
  /// Contorno tratteggiato di spessore [t] ATTORNO al rettangolo dato
  /// (come `outline: 2px dashed`): trattini di [dash] px separati da [gap]
  /// px, angoli sempre pieni.
  void dashedOutline(
    num x,
    num y,
    num w,
    num h,
    Color color, {
    num t = 2,
    num dash = 4,
    num gap = 4,
  }) {
    void run(num from, num len, void Function(num p, num l) draw) {
      for (num p = 0; p < len; p += dash + gap) {
        final l = (len - p) < dash ? len - p : dash;
        draw(from + p, l);
      }
    }

    final ow = w + 2 * t;
    final oh = h + 2 * t;
    run(x - t, ow, (p, l) {
      rect(p, y - t, l, t, color);
      rect(p, y + h, l, t, color);
    });
    run(y - t, oh, (p, l) {
      rect(x - t, p, t, l, color);
      rect(x + w, p, t, l, color);
    });
    // angoli pieni
    rect(x + w, y - t, t, t, color);
    rect(x - t, y + h, t, t, color);
    rect(x + w, y + h, t, t, color);
  }

  /// Quadratino d'accento 8×8 con ombra 2,2 (::before di titoli ed eyebrow).
  void accentSquare(num x, num y, Color face, Color shadow) {
    rect(x + 2, y + 2, 8, 8, shadow);
    rect(x, y, 8, 8, face);
  }
}

/// Larghezza disponibile arrotondata per difetto all'unità della griglia:
/// i riquadri "a blocco" (pannelli, card, barre) riempiono il genitore senza
/// finire su mezze unità.
class MsUnitWidth extends StatelessWidget {
  const MsUnitWidth({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        if (!c.hasBoundedWidth) return child;
        final w = (c.maxWidth / g.unit + 1e-6).floorToDouble() * g.unit;
        return SizedBox(width: w, child: child);
      },
    );
  }
}

/// Stato visivo di un elemento interattivo.
@immutable
class MsPressState {
  const MsPressState({
    this.hovered = false,
    this.pressed = false,
    this.focused = false,
    this.enabled = true,
  });

  final bool hovered;
  final bool pressed;
  final bool focused;
  final bool enabled;

  @override
  bool operator ==(Object other) =>
      other is MsPressState &&
      other.hovered == hovered &&
      other.pressed == pressed &&
      other.focused == focused &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(hovered, pressed, focused, enabled);
}

/// Gestisce hover, focus da tastiera, pressione e attivazione (clic, Invio,
/// Spazio) e passa lo stato al [builder]. Gli stati `force*` lo impongono
/// (mockup e golden, come le classi `.is-hover` del canvas).
class MsPressable extends StatefulWidget {
  const MsPressable({
    super.key,
    required this.builder,
    this.onTap,
    this.enabled = true,
    this.forceHover = false,
    this.forcePressed = false,
    this.forceFocus = false,
    this.focusNode,
    this.autofocus = false,
  });

  final Widget Function(BuildContext context, MsPressState state) builder;
  final VoidCallback? onTap;
  final bool enabled;
  final bool forceHover;
  final bool forcePressed;
  final bool forceFocus;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<MsPressable> createState() => _MsPressableState();
}

class _MsPressableState extends State<MsPressable> {
  bool _hover = false;
  bool _down = false;
  bool _focus = false;

  bool get _active => widget.enabled && widget.onTap != null;

  void _activate() {
    if (_active) widget.onTap!();
  }

  @override
  Widget build(BuildContext context) {
    final state = MsPressState(
      hovered: widget.forceHover || (_active && _hover),
      pressed: widget.forcePressed || (_active && _down),
      focused: widget.forceFocus || (_active && _focus),
      enabled: widget.enabled,
    );
    final child = widget.builder(context, state);
    if (!_active) return child;
    return FocusableActionDetector(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      mouseCursor: SystemMouseCursors.click,
      onShowFocusHighlight: (v) => setState(() => _focus = v),
      onShowHoverHighlight: (v) => setState(() => _hover = v),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _activate();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: _activate,
        child: child,
      ),
    );
  }
}

/// Spostamento verticale animato a scatti di pixel fisici interi (hover e
/// pressione delle card): [target] in px di design, durata [duration],
/// immediato con le animazioni ridotte.
class MsPixelShift extends StatefulWidget {
  const MsPixelShift({
    super.key,
    required this.target,
    required this.duration,
    required this.builder,
  });

  final double target;
  final Duration duration;
  final Widget Function(BuildContext context, int shiftPhys) builder;

  @override
  State<MsPixelShift> createState() => _MsPixelShiftState();
}

class _MsPixelShiftState extends State<MsPixelShift> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.duration);
  double _from = 0;
  double _to = 0;

  @override
  void initState() {
    super.initState();
    _from = _to = widget.target;
  }

  @override
  void didUpdateWidget(MsPixelShift old) {
    super.didUpdateWidget(old);
    if (widget.target == _to) return;
    _from = _current;
    _to = widget.target;
    if (MsTheme.reducedMotionOf(context) || widget.duration == Duration.zero) {
      _from = _to;
      _c.value = 1;
    } else {
      _c
        ..duration = widget.duration
        ..forward(from: 0);
    }
  }

  double get _current => _from + (_to - _from) * const Cubic(.2, .8, .2, 1).transform(_c.value);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => widget.builder(context, (_current / 2 * g.unitPx).round()),
    );
  }
}

/// Decorazione di riga di tabella: linea inferiore di 2 px allineata ai
/// pixel fisici (`box-shadow: inset 0 -2px 0 0`).
class MsBottomLine extends Decoration {
  const MsBottomLine(this.color, this.grid);

  final Color color;
  final PixelGrid grid;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _BottomLinePainter(this);

  @override
  bool operator ==(Object other) =>
      other is MsBottomLine && other.color == color && other.grid == grid;

  @override
  int get hashCode => Object.hash(color, grid);
}

class _BottomLinePainter extends BoxPainter {
  _BottomLinePainter(this.d);
  final MsBottomLine d;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null) return;
    final g = d.grid;
    final l = g.snap(offset.dx);
    final r = g.snap(offset.dx + size.width);
    final b = g.snap(offset.dy + size.height);
    canvas.drawRect(
      Rect.fromLTRB(l, b - g.d(2), r, b),
      Paint()
        ..color = d.color
        ..isAntiAlias = false,
    );
  }
}

/// Lampeggio a due scatti (`ms-blink`: acceso, poi attenuato a metà
/// [period]). Un timer cambia [value] solo agli scatti: un
/// AnimationController chiederebbe un frame a ogni refresh dello schermo
/// per un disegno che cambia due volte per periodo.
final class MsBlink extends ChangeNotifier {
  MsBlink(this.period);

  final Duration period;
  Timer? _timer;

  /// 0 acceso, 0,75 attenuato (come il valore di un'animazione a metà).
  double value = 0;

  bool get isAnimating => _timer != null;

  void repeat() {
    _timer ??= Timer.periodic(period ~/ 2, (_) {
      value = value < .5 ? .75 : 0;
      notifyListeners();
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    if (value != 0) {
      value = 0;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
