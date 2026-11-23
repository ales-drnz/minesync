// Pulsante "blocco estruso" (.ms-btn) con tutte le varianti: secondario,
// primario, pericolo, fantasma, solo icona, piccolo/grande, a tutta
// larghezza e GIOCA con la frangia d'erba (o i cristalli in abisso).
import 'package:flutter/widgets.dart';

import '../../pixel/grid.dart';
import '../../pixel/render.dart';
import '../../pixel/text.dart';
import '../../theme.dart';
import '../../tokens.g.dart';
import 'core.dart';

/// Colour variant of an [MsButton] (`.ms-btn--*`).
enum MsButtonVariant {
  /// Plain `.ms-btn` (secondary action).
  secondary,

  /// `--primary`: accent block.
  primary,

  /// `--danger`: error block.
  danger,

  /// `--ghost`: no block, outline on hover.
  ghost,
}

/// Size of an [MsButton]: `--sm` (36), default (44), `--lg` (56).
enum MsButtonSize { sm, md, lg }

enum _Kind { text, icon, play }

/// Extruded-block button (`.ms-btn`).
///
/// * [MsButton.new]: text button with optional leading [icon] and [trailing]
///   widget (e.g. an [MsKbd]).
/// * [MsButton.icon]: square icon-only button (`--icon`), [semanticLabel]
///   is required.
/// * [MsButton.play]: the big GIOCA button (`--play`) with the grass fringe
///   (crystals in the abisso palette) and an optional [subtitle] (`__sub`).
///
/// Disabled when [onPressed] is null: the block sinks and loses its side.
/// With [loading] the icon becomes a block spinner and the button stays
/// focusable but cannot be activated.
///
/// Icons receive their colour and size through [IconTheme].
class MsButton extends StatelessWidget {
  const MsButton({
    super.key,
    required String this.label,
    required this.onPressed,
    this.variant = MsButtonVariant.secondary,
    this.size = MsButtonSize.md,
    this.icon,
    this.trailing,
    this.block = false,
    this.alignStart = false,
    this.loading = false,
    this.semanticLabel,
    this.focusNode,
    this.autofocus = false,
    this.forcedStates,
  }) : subtitle = null,
       _kind = _Kind.text;

  const MsButton.icon({
    super.key,
    required Widget this.icon,
    required String this.semanticLabel,
    required this.onPressed,
    this.variant = MsButtonVariant.secondary,
    this.size = MsButtonSize.md,
    this.loading = false,
    this.focusNode,
    this.autofocus = false,
    this.forcedStates,
  }) : label = null,
       subtitle = null,
       trailing = null,
       block = false,
       alignStart = false,
       _kind = _Kind.icon;

  const MsButton.play({
    super.key,
    required String this.label,
    required this.onPressed,
    this.icon,
    this.subtitle,
    this.loading = false,
    this.block = false,
    this.semanticLabel,
    this.focusNode,
    this.autofocus = false,
    this.forcedStates,
  }) : variant = MsButtonVariant.primary,
       size = MsButtonSize.lg,
       trailing = null,
       alignStart = false,
       _kind = _Kind.play;

  final String? label;

  /// Second line (`.ms-btn__sub`), play button only.
  final String? subtitle;
  final VoidCallback? onPressed;
  final MsButtonVariant variant;
  final MsButtonSize size;
  final Widget? icon;
  final Widget? trailing;

  /// Full width (`--block`); needs a bounded width.
  final bool block;

  /// Content aligned to the start instead of centred (block buttons with a
  /// trailing shortcut, as in the app's action lists).
  final bool alignStart;
  final bool loading;

  /// Screen-reader label; defaults to [label] (+ [subtitle]).
  final String? semanticLabel;
  final FocusNode? focusNode;
  final bool autofocus;

  /// Forced look for galleries (see [MsStates]).
  final MsStates? forcedStates;
  final _Kind _kind;

  bool get _enabled => onPressed != null;

  @override
  Widget build(BuildContext context) {
    final sem = semanticLabel ?? [label, subtitle].whereType<String>().join(', ');
    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: _enabled,
        label: sem,
        onTap: _enabled && !loading ? onPressed : null,
        child: MsPressable(
          enabled: _enabled,
          onPressed: loading ? null : onPressed,
          cursor: loading ? SystemMouseCursors.progress : SystemMouseCursors.click,
          focusNode: focusNode,
          autofocus: autofocus,
          forced: forcedStates,
          builder: (context, states, press) => _build(context, states, press),
        ),
      ),
    );
  }

  Widget _build(BuildContext context, MsStates s, double press) {
    final c = msColors(context);
    final g = PixelScope.of(context);
    final ghost = variant == MsButtonVariant.ghost && _kind != _Kind.play;
    final pal = _palette(c);
    final disabled = !_enabled;
    final pressed = s.pressed && !disabled && !loading;
    final hot = (s.hovered || pressed) && !disabled;
    final play = _kind == _Kind.play;

    // Lato del blocco (px di design) e abbassamento.
    final side = ghost ? 0.0 : (play ? 6.0 : 4.0);
    // Disattivato: blocco piatto e spento alto quanto gli altri (faccia e
    // lato del colore dell'incasso), così accanto a un pulsante attivo testo
    // e bordi restano allineati; il GIOCA disattivato resta affondato.
    final sunk = disabled && play;
    final shiftPhys = sunk
        ? msPressPhys(g, 1, side)
        : (disabled ? 0 : msPressPhys(g, loading ? 0 : press, 2));
    final sidePhys = sunk ? 0 : msPressPhys(g, 1, side) - (ghost ? 0 : shiftPhys);

    final Color? face = disabled
        ? (ghost ? null : c.inset)
        : (hot ? pal.hover : (ghost ? null : pal.face));
    final Color? hl = disabled || ghost ? null : pal.hi;
    final Color? sd = ghost ? null : (disabled ? c.inset : pal.side);
    final Color? outline = ghost ? (s.hovered && !disabled ? c.pxOutline : null) : c.pxOutline;
    final fg = disabled ? c.text3 : pal.text;
    final focus = s.focused && !disabled;

    // nella testa di un pannello i pulsanti piccoli sono compatti (vedi MsCompact)
    final compact = size == MsButtonSize.sm && MsCompact.of(context);
    final (padding, minH, minW, gap, role) = switch ((_kind, size)) {
      (_Kind.play, _) => (const EdgeInsets.fromLTRB(32, 16, 32, 16), 72.0, 240.0, 16.0, null),
      (_Kind.icon, MsButtonSize.sm) => (EdgeInsets.zero, 36.0, 44.0, 0.0, null),
      (_Kind.icon, _) => (EdgeInsets.zero, 44.0, 44.0, 0.0, null),
      (_, MsButtonSize.sm) => (
        EdgeInsets.symmetric(horizontal: 12, vertical: compact ? 2 : 6),
        compact ? 24.0 : 36.0,
        44.0,
        8.0,
        MsTextRole.sm,
      ),
      (_, MsButtonSize.md) => (
        const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        44.0,
        44.0,
        8.0,
        MsTextRole.md,
      ),
      (_, MsButtonSize.lg) => (
        const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
        56.0,
        44.0,
        8.0,
        MsTextRole.lg,
      ),
    };
    // anche i pulsanti senza bordo tengono gli 8 px sotto: accanto a un
    // pulsante a blocco il testo sta sulla stessa linea
    final outset = EdgeInsets.fromLTRB(2, 2, 2, play ? 10 : 8);

    final content = _content(context, fg, face ?? c.bg, gap, role);
    final spread = block && (alignStart || trailing != null);
    Widget frame = PixelFrame(
      padding: padding,
      outset: outset,
      minWidth: _kind == _Kind.icon ? 44 : minW,
      minHeight: minH,
      centerX: !spread,
      centerY: true,
      childShiftPhys: shiftPhys,
      repaintKey: (face, hl, sd, outline, shiftPhys, sidePhys, focus, c.focus),
      painter: (p, w, h) {
        _paintBlock(
          p,
          w,
          h,
          shiftPhys: shiftPhys,
          sidePhys: sidePhys,
          face: face,
          hl: hl,
          sd: sd,
          outline: outline,
        );
        if (focus) p.shiftPhys(0, shiftPhys).outline(-4, -4, w + 8, h + 8, c.focus);
      },
      child: content,
    );
    if (_kind == _Kind.icon) {
      frame = SizedBox(width: g.d(48), child: frame);
    } else if (block) {
      frame = SizedBox(width: double.infinity, child: frame);
    }
    return frame;
  }

  Widget _content(BuildContext context, Color fg, Color bg, double gap, MsTextRole? role) {
    final g = PixelScope.of(context);
    final play = _kind == _Kind.play;
    final iconSize = play ? 32.0 : 16.0;
    Widget? lead;
    if (loading) {
      lead = MsSpinGlyph(color: fg, background: bg);
    } else if (icon != null) {
      lead = ExcludeSemantics(child: msIconSlot(context, icon!, fg, size: iconSize));
    }
    if (_kind == _Kind.icon) return lead ?? const SizedBox.shrink();

    // .ms-btn .ms-ico { margin-left: -2px }
    if (lead != null && !play && !loading) {
      lead = SizedBox(
        width: g.d(iconSize - 2),
        height: g.d(iconSize),
        child: OverflowBox(
          alignment: Alignment.centerRight,
          maxWidth: g.d(iconSize),
          minWidth: g.d(iconSize),
          child: lead,
        ),
      );
    }

    final PixelTextStyle style = play
        ? msText(context, MsTextRole.label, fg).copyWith(size: 32, lineHeight: 40, weight: 700)
        : msText(context, role!, fg, weight: 600);
    final spread = block && (alignStart || trailing != null);
    Widget text = PixelText(play ? msSentenceCase(label!) : label!, style: style);
    if (subtitle != null) {
      text = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          text,
          PixelText(subtitle!, style: msText(context, MsTextRole.sm, fg, weight: 600)),
        ],
      );
    }
    if (spread) {
      text = Expanded(
        child: Align(alignment: Alignment.centerLeft, child: text),
      );
    } else {
      // in uno spazio stretto il testo si accorcia con i puntini invece di
      // traboccare dal pulsante
      text = Flexible(child: text);
    }
    final row = Row(
      mainAxisSize: spread ? MainAxisSize.max : MainAxisSize.min,
      children: [
        if (lead != null) ...[lead, PixelGap(gap, 0)],
        text,
        if (trailing != null) ...[
          PixelGap(gap, 0),
          DefaultTextStyle.merge(
            style: TextStyle(color: fg),
            child: trailing!,
          ),
        ],
      ],
    );
    // GIOCA: padding 16 40 16 32, il contenuto centrato tiene conto degli
    // 8 px in più a destra.
    if (play) {
      return Padding(
        padding: EdgeInsets.only(right: g.d(8)),
        child: row,
      );
    }
    return row;
  }

  _Palette _palette(MsColors c) => switch ((_kind, variant)) {
    (_Kind.play, _) || (_, MsButtonVariant.primary) => _Palette(
      c.accent,
      c.accentHover,
      c.accentHi,
      c.accentLo,
      c.onAccent,
    ),
    (_, MsButtonVariant.danger) => _Palette(c.err, c.errHover, c.errHi, c.errLo, c.onErr),
    (_, MsButtonVariant.ghost) => _Palette(c.panelHi, c.panelHi, c.pxLight, c.pxShadow, c.text),
    (_, MsButtonVariant.secondary) => _Palette(c.panelHi, c.overlay, c.pxLight, c.pxShadow, c.text),
  };
}

final class _Palette {
  const _Palette(this.face, this.hover, this.hi, this.side, this.text);
  final Color face;
  final Color hover;
  final Color hi;
  final Color side;
  final Color text;
}

/// Blocco estruso: contorno con angoli smussati, lato inferiore, faccia e
/// filo di luce. La faccia scende di [shiftPhys] pixel fisici, il lato è
/// alto [sidePhys].
void _paintBlock(
  PixelCanvas c0,
  double w,
  double h, {
  required int shiftPhys,
  required int sidePhys,
  required Color? face,
  required Color? hl,
  required Color? sd,
  required Color? outline,
}) {
  final g = c0.g;
  final u = g.unitPx;
  final c = c0.shiftPhys(0, shiftPhys);
  final wP = (g.d(w) * g.dpr).round();
  final hP = (g.d(h) * g.dpr).round();
  if (outline != null) {
    c.rectPhys(-u, 0, u, hP + sidePhys, outline);
    c.rectPhys(wP, 0, u, hP + sidePhys, outline);
    c.rect(0, -2, w, 2, outline);
    c.rectPhys(0, hP + sidePhys, wP, u, outline);
  }
  if (sd != null && sidePhys > 0) c.rectPhys(0, hP, wP, sidePhys, sd);
  if (face != null) c.rect(0, 0, w, h, face);
  if (hl != null) c.rect(0, 0, w, 2, hl);
}
