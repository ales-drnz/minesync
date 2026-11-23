// Base comune dei controlli: stati visivi (hover, premuto, focus), gestione
// di puntatore e tastiera, animazione di pressione a scatti di pixel fisici,
// piccoli glifi pixel e scorciatoie per stili e colori del tema.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../pixel/grid.dart';
import '../../pixel/render.dart';
import '../../pixel/text.dart';
import '../../theme.dart';
import '../../tokens.g.dart';

/// Visual interaction states of a control.
///
/// Passed as `forcedStates` to force a look, like the `.is-hover`,
/// `.is-pressed` and `.is-focus` classes of the design canvas (galleries,
/// mockups and goldens). A forced state replaces the live one.
@immutable
final class MsStates {
  const MsStates({this.hovered = false, this.pressed = false, this.focused = false});

  /// `.is-hover`.
  static const hover = MsStates(hovered: true);

  /// `.is-pressed`.
  static const press = MsStates(pressed: true);

  /// `.is-focus` (focus-visible ring).
  static const focus = MsStates(focused: true);

  final bool hovered;
  final bool pressed;
  final bool focused;

  @override
  bool operator ==(Object other) =>
      other is MsStates &&
      other.hovered == hovered &&
      other.pressed == pressed &&
      other.focused == focused;

  @override
  int get hashCode => Object.hash(hovered, pressed, focused);

  @override
  String toString() => 'MsStates(hover: $hovered, pressed: $pressed, focus: $focused)';
}

/// --ms-ease-out.
const Curve msEaseOut = Cubic(.2, .8, .2, 1);

/// Scorciatoie di attivazione dei pulsanti (Invio e Spazio).
const Map<ShortcutActivator, Intent> msActivateShortcuts = {
  SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
  SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
  SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
};

typedef MsPressableBuilder = Widget Function(BuildContext context, MsStates states, double press);

/// Controllo premibile: focus da tastiera (anello solo con focus-visible),
/// hover, pressione con animazione [MsDuration.d1] (o immediata con le
/// animazioni ridotte), Invio/Spazio. [builder] riceve gli stati e
/// l'avanzamento della pressione (0..1).
class MsPressable extends StatefulWidget {
  const MsPressable({
    super.key,
    required this.enabled,
    required this.onPressed,
    required this.builder,
    this.focusNode,
    this.autofocus = false,
    this.forced,
    this.cursor = SystemMouseCursors.click,
    this.disabledCursor = SystemMouseCursors.forbidden,
    this.onFocusChange,
    this.onHoverChange,
    this.shortcuts,
    this.actions,
    this.skipTraversal = false,
  });

  /// Raggiungibile con il focus e sensibile all'hover.
  final bool enabled;

  /// Null: si può mettere a fuoco ma non attivare (es. caricamento).
  final VoidCallback? onPressed;
  final MsPressableBuilder builder;
  final FocusNode? focusNode;
  final bool autofocus;
  final MsStates? forced;
  final MouseCursor cursor;
  final MouseCursor disabledCursor;
  final ValueChanged<bool>? onFocusChange;
  final ValueChanged<bool>? onHoverChange;
  final Map<ShortcutActivator, Intent>? shortcuts;
  final Map<Type, Action<Intent>>? actions;
  final bool skipTraversal;

  @override
  State<MsPressable> createState() => _MsPressableState();
}

class _MsPressableState extends State<MsPressable> with SingleTickerProviderStateMixin {
  late final AnimationController _press = AnimationController(vsync: this, duration: MsDuration.d1);
  bool _hover = false;
  bool _focus = false;
  bool _down = false;

  bool get _active => widget.enabled && widget.onPressed != null;

  @override
  void didUpdateWidget(MsPressable old) {
    super.didUpdateWidget(old);
    if (!_active && (_down || _press.value != 0)) {
      _down = false;
      _press.value = 0;
    }
    if (!widget.enabled) {
      _hover = false;
      _focus = false;
    }
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  void _animate(bool down) {
    if (MsTheme.reducedMotionOf(context)) {
      _press.value = down ? 1 : 0;
    } else if (down) {
      _press.animateTo(1, curve: msEaseOut);
    } else {
      _press.animateBack(0, curve: msEaseOut);
    }
  }

  void _setDown(bool v) {
    if (_down == v) return;
    setState(() => _down = v);
    _animate(v);
  }

  void _keyActivate() {
    if (!_active) return;
    // Breve pressione visibile anche da tastiera.
    if (!MsTheme.reducedMotionOf(context)) {
      _press.animateTo(1, curve: msEaseOut).then((_) {
        if (mounted && !_down) _press.animateBack(0, curve: msEaseOut);
      });
    }
    widget.onPressed!();
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.forced;
    final states = MsStates(
      hovered: f?.hovered ?? _hover,
      pressed: f?.pressed ?? _down,
      focused: f?.focused ?? _focus,
    );
    final forcedPress = f != null && f.pressed;
    return FocusableActionDetector(
      enabled: widget.enabled,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      mouseCursor: widget.enabled ? widget.cursor : widget.disabledCursor,
      onShowFocusHighlight: (v) {
        if (_focus != v) setState(() => _focus = v);
      },
      onShowHoverHighlight: (v) {
        if (_hover != v) setState(() => _hover = v);
        widget.onHoverChange?.call(v);
      },
      onFocusChange: widget.onFocusChange,
      shortcuts: widget.shortcuts ?? msActivateShortcuts,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _keyActivate();
            return null;
          },
        ),
        ...?widget.actions,
      },
      descendantsAreFocusable: false,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _active ? (_) => _setDown(true) : null,
        onTapUp: _active
            ? (_) {
                _setDown(false);
                widget.onPressed?.call();
              }
            : null,
        onTapCancel: _active ? () => _setDown(false) : null,
        child: AnimatedBuilder(
          animation: _press,
          builder: (context, _) =>
              widget.builder(context, states, forcedPress ? 1.0 : _press.value),
        ),
      ),
    );
  }
}

/// Avanzamento (0..1) di uno spostamento di [designPx] px di design, in
/// pixel fisici interi.
int msPressPhys(PixelGrid g, double press, double designPx) =>
    (press * designPx / 2 * g.unitPx).round();

/// Colore pieno ottenuto componendo [fg] con opacità [alpha] su [bg], in
/// aritmetica a 8 bit: il risultato è un colore intero, quindi il motore lo
/// disegna identico (nessun pixel sfumato).
Color msBlend(Color fg, double alpha, Color bg) {
  final a = (alpha * 255).round();
  int ch(double f, double b) =>
      ((f * 255).round() * a + (b * 255).round() * (255 - a) + 127) ~/ 255;
  return Color.fromARGB(255, ch(fg.r, bg.r), ch(fg.g, bg.g), ch(fg.b, bg.b));
}

/// Stile di testo del tema per [role].
PixelTextStyle msText(BuildContext context, MsTextRole role, Color color, {int? weight}) =>
    MsTheme.typographyOf(context).style(role, color, weight: weight);

/// Ospita un'icona fornita dall'app: colore e dimensione passano da
/// [IconTheme] (l'icona li legge come `currentColor` nel CSS).
Widget msIconSlot(BuildContext context, Widget icon, Color color, {double size = 16}) {
  final g = PixelScope.of(context);
  return IconTheme.merge(
    data: IconThemeData(color: color, size: g.d(size)),
    child: SizedBox(
      width: g.d(size),
      height: g.d(size),
      child: Center(child: icon),
    ),
  );
}

/// Testo su più righe (paragrafi, aiuti, messaggi): stesso stile del
/// [PixelText] ma con a capo automatico.
class MsWrapText extends StatelessWidget {
  const MsWrapText(this.text, {super.key, required this.style, this.textAlign = TextAlign.start});

  final String text;
  final PixelTextStyle style;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    if (debugHideText) return const SizedBox.shrink();
    return Text(
      text,
      style: style.toTextStyle(g),
      textAlign: textAlign,
      textDirection: TextDirection.ltr,
    );
  }
}

/// Disegna un glifo pixel: ogni riga di [rows] è una stringa in cui `#`
/// accende una cella di [cell] px di design.
void msPaintBits(PixelCanvas c, num x, num y, List<String> rows, Color color, {num cell = 2}) {
  for (var r = 0; r < rows.length; r++) {
    final row = rows[r];
    var i = 0;
    while (i < row.length) {
      if (row.codeUnitAt(i) != 0x23) {
        i++;
        continue;
      }
      final s = i;
      while (i < row.length && row.codeUnitAt(i) == 0x23) {
        i++;
      }
      c.rect(x + s * cell, y + r * cell, (i - s) * cell, cell, color);
    }
  }
}

/// Glifi interni dei controlli (8x8 celle, mostrati a 16 px).
abstract final class MsGlyphs {
  /// Croce (chiudi).
  static const close = [
    '        ',
    ' ##  ## ',
    '  ####  ',
    '   ##   ',
    '  ####  ',
    ' ##  ## ',
    '        ',
    '        ',
  ];

  /// Riduci a icona.
  static const minimize = [
    '        ',
    '        ',
    '        ',
    '        ',
    '        ',
    ' ###### ',
    '        ',
    '        ',
  ];

  /// Ingrandisci.
  static const maximize = [
    '        ',
    ' ###### ',
    ' #    # ',
    ' #    # ',
    ' #    # ',
    ' ###### ',
    '        ',
    '        ',
  ];

  /// Ripristina (finestra ingrandita).
  static const restore = [
    '        ',
    '   #### ',
    '      # ',
    ' ####   ',
    ' #  # # ',
    ' #  #   ',
    ' ####   ',
    '        ',
  ];

  /// Freccia a destra (separatore del percorso).
  static const chevron = [
    '        ',
    '  #     ',
    '   #    ',
    '    #   ',
    '   #    ',
    '  #     ',
    '        ',
    '        ',
  ];

  /// Croce dell'errore di un campo (4x4 celle, 8 px).
  static const errorX = ['#  #', ' ## ', ' ## ', '#  #'];
}

/// Glifo pixel come foglia di [size] px di design (8 celle).
class MsGlyph extends StatelessWidget {
  const MsGlyph(this.rows, {super.key, required this.color, this.size = 16});

  final List<String> rows;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cell = size / rows.length;
    return PixelBox(
      width: size,
      height: size,
      repaintKey: (rows, color, size),
      painter: (c, w, h) => msPaintBits(c, 0, 0, rows, color, cell: cell),
    );
  }
}

/// Spinner a blocchi (`.ms-spin`): quattro blocchi 6x6 attenuati e uno
/// pieno che gira a scatti ogni 200 ms; fermo con le animazioni ridotte.
class MsSpinGlyph extends StatefulWidget {
  const MsSpinGlyph({super.key, required this.color, required this.background});

  final Color color;

  /// Colore pieno sotto lo spinner (per comporre l'opacità .35 senza
  /// pixel sfumati).
  final Color background;

  @override
  State<MsSpinGlyph> createState() => _MsSpinGlyphState();
}

class _MsSpinGlyphState extends State<MsSpinGlyph> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MsTheme.reducedMotionOf(context)) {
      _c.stop();
      _c.value = 0;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dim = msBlend(widget.color, .35, widget.background);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final step = (_c.value * 4).floor() % 4;
        return PixelBox(
          width: 16,
          height: 16,
          repaintKey: (step, widget.color, dim),
          painter: (c, w, h) {
            const pos = [(0, 0), (10, 0), (10, 10), (0, 10)];
            for (final (x, y) in pos) {
              c.rect(x, y, 6, 6, dim);
            }
            final (x, y) = pos[step];
            c.rect(x, y, 6, 6, widget.color);
          },
        );
      },
    );
  }
}

/// Colori dello schema corrente.
MsColors msColors(BuildContext context) => MsTheme.colorsOf(context);
