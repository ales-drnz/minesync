// Console del server (.ms-console): barra, uscita virtualizzata con
// righe .ms-line--dim/info/warn/err/join/ok/cmd/match, pulsante "torna live"
// (.ms-console__live) e riga di comando (.ms-console__input). Resta scura in
// entrambi i temi.
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../pixel/grid.dart';
import '../../pixel/render.dart';
import '../../pixel/text.dart';
import '../../theme.dart';
import '../../tokens.g.dart';
import 'common.dart';
import 'text.dart';

/// Tipo di riga della console.
enum MsLineKind {
  /// Informazione (testo normale, livello in --ms-con-info).
  info,

  /// Attenuata (avanzamenti, messaggi di servizio).
  dim,

  /// Avviso: giallo, fondo tenue e barra di 4 px a sinistra.
  warn,

  /// Errore: rosso, fondo tenue e barra di 4 px a sinistra.
  err,

  /// Ingresso o uscita di un giocatore (blu).
  join,

  /// Esito positivo (verde).
  ok,

  /// Comando inviato (grassetto).
  cmd,
}

/// Riga della console. [time] e [level] sono le prime due colonne (76 e
/// 56 px); [match] evidenzia una corrispondenza della ricerca.
@immutable
class MsConsoleLine {
  const MsConsoleLine(
    this.text, {
    this.time = '',
    this.level = '',
    this.kind = MsLineKind.info,
    this.match = false,
  });

  final String text;
  final String time;
  final String level;
  final MsLineKind kind;
  final bool match;

  MsConsoleLine copyWith({bool? match}) =>
      MsConsoleLine(text, time: time, level: level, kind: kind, match: match ?? this.match);

  @override
  bool operator ==(Object other) =>
      other is MsConsoleLine &&
      other.text == text &&
      other.time == time &&
      other.level == level &&
      other.kind == kind &&
      other.match == match;

  @override
  int get hashCode => Object.hash(text, time, level, kind, match);
}

/// Console del server.
///
/// L'uscita è virtualizzata (si costruiscono solo le righe visibili) e regge
/// migliaia di righe aggiunte di continuo. Finché si è in fondo ("live") le
/// righe nuove restano in vista; se si scorre indietro la vista resta ferma e
/// compare il pulsante "torna live" con il numero di righe arrivate (anche il
/// tasto Fine torna in fondo). Sotto un [Overlay] (come in WidgetsApp) il
/// testo si seleziona e si copia con il mouse e Ctrl+C; [MsConsole.plainText]
/// dà il testo di tutte le righe.
///
/// Va messa in un genitore di altezza limitata (es. [Expanded]); altrimenti
/// l'uscita è alta [fallbackHeight].
class MsConsole extends StatefulWidget {
  const MsConsole({
    super.key,
    required this.lines,
    required this.liveLabel,
    this.toolbar,
    this.input,
    this.footer,
    this.wrap = true,
    this.liveIcon,
    this.liveButtonBuilder,
    this.semanticLabel,
    this.announce = true,
    this.controller,
    this.onLiveChanged,
    this.prompt = '>',
    this.fallbackHeight = 400,
  });

  /// Righe da mostrare, dalla più vecchia. Si può passare la stessa lista
  /// dopo averla allungata: conta la lunghezza.
  final List<MsConsoleLine> lines;

  /// Testo del pulsante "torna live" dato il numero di righe nuove (es.
  /// `(n) => '$n righe nuove · torna live'`).
  final String Function(int newLines) liveLabel;

  /// Contenuto della barra in alto (`.ms-console__bar`: filtri, ricerca,
  /// azioni), su --ms-panel.
  final Widget? toolbar;

  /// Campo di comando (`.ms-console__input`), preceduto da [prompt].
  final Widget? input;

  /// Riga sotto il campo (comandi veloci), sul fondo del campo.
  final Widget? footer;

  /// A capo delle righe lunghe (come `pre-wrap`); falso = una riga sola
  /// tagliata, ad altezza fissa (il più veloce).
  final bool wrap;

  /// Icona del pulsante "torna live" (riceve colore da [IconTheme]).
  final Widget? liveIcon;

  /// Pulsante "torna live" personalizzato.
  final Widget Function(BuildContext context, int newLines, VoidCallback goLive)? liveButtonBuilder;

  /// Nome della console per le tecnologie assistive.
  final String? semanticLabel;

  /// Annuncia l'ultima riga arrivata (regione live, come `aria-live`).
  final bool announce;
  final ScrollController? controller;

  /// Chiamata quando si entra o si esce dalla modalità live.
  final ValueChanged<bool>? onLiveChanged;
  final String prompt;

  /// Altezza dell'uscita in px di design se il genitore non la limita.
  final double fallbackHeight;

  /// Testo semplice delle righe (ora, livello e testo separati da spazi),
  /// per "copia tutto".
  static String plainText(Iterable<MsConsoleLine> lines) =>
      lines.map((l) => [l.time, l.level, l.text].where((s) => s.isNotEmpty).join(' ')).join('\n');

  @override
  State<MsConsole> createState() => MsConsoleState();
}

/// Stato di [MsConsole]: [isLive], [newLines] e [goLive] per chi usa una
/// GlobalKey.
class MsConsoleState extends State<MsConsole> {
  ScrollController? _own;
  ScrollController get _ctrl => widget.controller ?? (_own ??= ScrollController());
  final FocusNode _focus = FocusNode(debugLabel: 'MsConsole');

  bool _live = true;
  int _newLines = 0;
  int _lastLen = 0;
  bool _jumpScheduled = false;

  /// Vero se la vista segue le righe nuove.
  bool get isLive => _live;

  /// Righe arrivate da quando si è usciti dalla modalità live.
  int get newLines => _newLines;

  @override
  void initState() {
    super.initState();
    _lastLen = widget.lines.length;
    _scheduleJump();
  }

  @override
  void didUpdateWidget(MsConsole oldWidget) {
    super.didUpdateWidget(oldWidget);
    final len = widget.lines.length;
    final delta = len - _lastLen;
    _lastLen = len;
    if (delta > 0) {
      if (_live) {
        _scheduleJump();
      } else {
        _newLines += delta;
      }
    } else if (delta < 0 && len == 0) {
      _newLines = 0;
    }
  }

  @override
  void dispose() {
    _own?.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _setLive(bool v) {
    if (v == _live) return;
    setState(() {
      _live = v;
      if (v) _newLines = 0;
    });
    widget.onLiveChanged?.call(v);
  }

  /// Torna in fondo e riprende a seguire le righe nuove.
  void goLive() {
    _setLive(true);
    _scheduleJump();
  }

  void _scheduleJump([int tries = 3]) {
    if (_jumpScheduled) return;
    _jumpScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _jumpScheduled = false;
      if (!mounted || !_live || !_ctrl.hasClients) return;
      final pos = _ctrl.position;
      if (pos.pixels != pos.maxScrollExtent) {
        pos.jumpTo(pos.maxScrollExtent);
        // l'estensione delle righe a capo si conosce dopo il layout: si
        // ricontrolla al fotogramma successivo
        if (tries > 1) {
          _scheduleJump(tries - 1);
          SchedulerBinding.instance.scheduleFrame();
        }
      }
    });
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is ScrollUpdateNotification || n is UserScrollNotification) {
      final m = n.metrics;
      final atEnd = m.pixels >= m.maxScrollExtent - PixelScope.of(context).d(10);
      _setLive(atEnd);
    }
    return false;
  }

  PixelTextStyle _style(MsColors c) =>
      PixelTextStyle(font: PixelFont.mono, size: 14, lineHeight: 20, color: c.conText);

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final g = PixelScope.of(context);
    final style = _style(c);
    final lines = widget.lines;

    Widget out = ListView.builder(
      controller: _ctrl,
      padding: EdgeInsets.symmetric(vertical: g.d(12)),
      itemCount: lines.length,
      itemExtent: widget.wrap ? null : g.d(style.lineHeight),
      itemBuilder: (context, i) => _LineView(line: lines[i], style: style, wrap: widget.wrap),
    );
    // La selezione richiede un Overlay (presente sotto WidgetsApp); senza,
    // la console resta di sola lettura.
    if (Overlay.maybeOf(context) != null) {
      out = DefaultSelectionStyle(
        selectionColor: c.conMatch,
        child: SelectableRegion(
          focusNode: _focus,
          selectionControls: emptyTextSelectionControls,
          child: out,
        ),
      );
    } else {
      out = Focus(focusNode: _focus, child: out);
    }
    out = CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.end): goLive},
      child: NotificationListener<ScrollNotification>(onNotification: _onScroll, child: out),
    );

    final liveButton = _live
        ? null
        : (widget.liveButtonBuilder?.call(context, _newLines, goLive) ??
              _LiveButton(
                label: widget.liveLabel(_newLines),
                icon: widget.liveIcon,
                onTap: goLive,
              ));

    final outArea = Stack(
      children: [
        Positioned.fill(child: out),
        if (liveButton != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: g.d(6),
            child: Center(child: liveButton),
          ),
        if (widget.announce && lines.isNotEmpty)
          Positioned(
            left: 0,
            top: 0,
            width: 1,
            height: 1,
            child: Semantics(
              liveRegion: true,
              label: lines.last.text,
              child: const SizedBox.shrink(),
            ),
          ),
      ],
    );

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.toolbar != null)
          PixelFrame(
            padding: const EdgeInsets.all(8),
            repaintKey: c,
            painter: (p, w, h) {
              p.rect(0, 0, w, h, c.panel);
              p.rect(0, h - 2, w, 2, c.pxOutline);
            },
            child: widget.toolbar,
          ),
        Expanded(child: outArea),
        if (widget.input != null)
          PixelFrame(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
            repaintKey: c,
            painter: (p, w, h) {
              p.rect(0, 0, w, h, c.conInput);
              p.rect(0, 0, w, 2, c.pxOutline);
            },
            child: Row(
              children: [
                ExcludeSemantics(
                  child: PixelText(
                    widget.prompt,
                    style: style.copyWith(color: c.conOk, weight: 700),
                  ),
                ),
                const PixelGap(8, 0),
                Expanded(child: widget.input!),
              ],
            ),
          ),
        if (widget.footer != null)
          PixelFrame(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            repaintKey: c,
            painter: (p, w, h) => p.rect(0, 0, w, h, c.conInput),
            child: widget.footer,
          ),
      ],
    );

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: widget.semanticLabel,
      child: LayoutBuilder(
        builder: (context, box) {
          double floor(double v) => (v / g.unit + 1e-6).floorToDouble() * g.unit;
          final w = box.hasBoundedWidth ? floor(box.maxWidth) : null;
          final h = box.hasBoundedHeight ? floor(box.maxHeight) : null;
          final frame = PixelFrame(
            outset: const EdgeInsets.all(2),
            padding: const EdgeInsets.all(2),
            repaintKey: c,
            painter: (p, w, h) {
              p.ring(0, 0, w, h, c.pxOutline);
              p.rect(0, 0, w, h, c.conBg);
              p.bevel(w, h, c.pxLight, c.pxShadow, inverted: true);
            },
            child: h == null
                ? SizedBox(height: g.d(widget.fallbackHeight), child: column)
                : SizedBox(height: h - g.d(8), child: column),
          );
          return SizedBox(width: w, height: h, child: frame);
        },
      ),
    );
  }
}

class _LineView extends StatefulWidget {
  const _LineView({required this.line, required this.style, required this.wrap});

  final MsConsoleLine line;
  final PixelTextStyle style;
  final bool wrap;

  @override
  State<_LineView> createState() => _LineViewState();
}

class _LineViewState extends State<_LineView> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final g = PixelScope.of(context);
    final l = widget.line;
    final (Color fg, Color lvl, Color? bg, Color? bar) = switch (l.kind) {
      MsLineKind.info => (c.conText, c.conInfo, null, null),
      MsLineKind.dim => (c.conDim, c.conDim, null, null),
      MsLineKind.warn => (c.conWarn, c.conWarn, c.conWarnBg, c.conWarn),
      MsLineKind.err => (c.conErr, c.conErr, c.conErrBg, c.conErr),
      MsLineKind.join => (c.conJoin, c.conDim, null, null),
      MsLineKind.ok => (c.conOk, c.conDim, null, null),
      MsLineKind.cmd => (c.conCmd, c.conCmd, null, null),
    };
    final fill = _hover ? c.conHover : (l.match ? c.conMatch : bg);
    final bold = l.kind == MsLineKind.cmd;
    final base = widget.style.toTextStyle(g);
    TextStyle ts(Color col, {bool strong = false}) => base.copyWith(
      color: col,
      fontWeight: strong ? FontWeight.w700 : FontWeight.w400,
      fontVariations: base.fontVariations == null
          ? null
          : [FontVariation('wght', strong ? 700 : 400)],
    );
    final maxLines = widget.wrap ? null : 1;
    Widget cell(String s, TextStyle st) => Text(
      s,
      style: st,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
      textScaler: TextScaler.noScaling,
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: PixelFrame(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        repaintKey: (fill, bar),
        painter: (p, w, h) {
          if (fill != null) p.rect(0, 0, w, h, fill);
          if (bar != null) p.rect(0, 0, 4, h, bar);
        },
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: g.d(76), child: cell(l.time, ts(c.conDim))),
            const PixelGap(12, 0),
            SizedBox(width: g.d(56), child: cell(l.level, ts(lvl, strong: true))),
            const PixelGap(12, 0),
            Expanded(
              child: Text(
                l.text,
                style: ts(fg, strong: bold),
                maxLines: maxLines,
                softWrap: widget.wrap,
                overflow: widget.wrap ? TextOverflow.clip : TextOverflow.ellipsis,
                textScaler: TextScaler.noScaling,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pulsante "torna live" predefinito: blocco estruso d'accento piccolo
/// (come `.ms-btn--primary.ms-btn--sm`), lato di 4 px.
class _LiveButton extends StatelessWidget {
  const _LiveButton({required this.label, required this.onTap, this.icon});

  final String label;
  final VoidCallback onTap;
  final Widget? icon;

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final g = PixelScope.of(context);
    return MsPressable(
      onTap: onTap,
      builder: (context, s) {
        final face = (s.hovered || s.pressed) ? c.accentHover : c.accent;
        final side = s.pressed ? 2.0 : 4.0;
        final shift = s.pressed ? g.unitPx : 0;
        return Semantics(
          button: true,
          label: label,
          excludeSemantics: true,
          child: PixelFrame(
            minHeight: 36,
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            outset: const EdgeInsets.fromLTRB(2, 2, 2, 8),
            centerY: true,
            childShiftPhys: shift,
            repaintKey: (face, side, s.focused, c),
            painter: (p0, w, h) {
              final p = p0.shiftPhys(0, shift);
              p.rect(-2, 0, 2, h + side, c.pxOutline);
              p.rect(w, 0, 2, h + side, c.pxOutline);
              p.rect(0, -2, w, 2, c.pxOutline);
              p.rect(0, h + side, w, 2, c.pxOutline);
              p.rect(0, h, w, side, c.accentLo);
              p.rect(0, 0, w, h, face);
              p.rect(0, 0, w, 2, c.accentHi);
              if (s.focused) p0.outline(-4, -4, w + 8, h + 8 + 4, c.focus);
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  IconTheme(
                    data: IconThemeData(color: c.onAccent, size: g.d(16)),
                    child: icon!,
                  ),
                  const PixelGap(8, 0),
                ],
                MsText(label, kind: MsTextKind.small, weight: 600, color: c.onAccent, maxLines: 1),
              ],
            ),
          ),
        );
      },
    );
  }
}
