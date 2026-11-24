// Piccoli indicatori di ms.css: .ms-badge, .ms-pill, .ms-chip, l'etichetta
// a sola icona (MsIconTag), .ms-lock, .ms-live e .ms-level. Lo stato non è mai affidato al solo colore: pillole,
// lock e indicatore live hanno anche una forma pixel diversa.
import 'package:flutter/widgets.dart';

import '../../pixel/grid.dart';
import '../../pixel/render.dart';
import '../../theme.dart';
import '../../tokens.g.dart';
import '../controls/core.dart' show msText;
import '../controls/tooltip.dart';
import 'common.dart';
import 'text.dart';

/// Tipo di attività di un badge (`.ms-badge--*`).
enum MsBadgeKind {
  /// Neutro (--ms-panel-hi).
  neutral,

  /// Salvataggio sull'hub (--ms-ok).
  push,

  /// Presa del lock / avvio (--ms-info).
  lock,

  /// Rilascio del lock (neutro).
  stop,

  /// Rilascio forzato (--ms-err).
  force,

  /// Ripristino (--ms-accent).
  restore,

  /// Disco (--ms-warn).
  disk,

  /// Pulizia (neutro).
  gc,

  /// Server (neutro).
  server,

  /// Impostazioni (neutro).
  settings,
}

/// Badge di attività (`.ms-badge`): blocchetto pieno largo almeno 88 px e
/// alto come pillole, chip e pulsanti piccoli,
/// etichetta in grassetto, contorno e filo d'ombra in basso.
class MsBadge extends StatelessWidget {
  const MsBadge(this.label, {super.key, this.kind = MsBadgeKind.neutral});

  final String label;
  final MsBadgeKind kind;

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final (bg, fg) = switch (kind) {
      MsBadgeKind.push => (c.ok, c.onOk),
      MsBadgeKind.lock => (c.info, c.onInfo),
      MsBadgeKind.force => (c.err, c.onErr),
      MsBadgeKind.restore => (c.accent, c.onAccent),
      MsBadgeKind.disk => (c.warn, c.onWarn),
      _ => (c.panelHi, c.text),
    };
    return PixelFrame(
      minWidth: 88,
      minHeight: 32,
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
      outset: const EdgeInsets.all(2),
      centerX: true,
      centerY: true,
      repaintKey: (bg, c),
      painter: (p, w, h) {
        p.ring(0, 0, w, h, c.pxOutline);
        p.rect(0, 0, w, h, bg);
        p.rect(0, h - 2, w, 2, c.pxShadow);
      },
      child: MsText(label, kind: MsTextKind.labelSmall, color: fg, maxLines: 1),
    );
  }
}

/// Tono di [MsPill] e [MsAlert].
enum MsStatusTone {
  /// Neutro (--ms-text-2), quadrato pieno.
  neutral,

  /// Ok: quadrato pieno.
  ok,

  /// Avviso: triangolo a gradini.
  warn,

  /// Errore: croce.
  err,

  /// Informazione: barretta.
  info,
}

/// Colore e colore sopra di un tono.
(Color, Color) msStatusColors(MsColors c, MsStatusTone tone) => switch (tone) {
  MsStatusTone.neutral => (c.text2, c.bg),
  MsStatusTone.ok => (c.ok, c.onOk),
  MsStatusTone.warn => (c.warn, c.onWarn),
  MsStatusTone.err => (c.err, c.onErr),
  MsStatusTone.info => (c.info, c.onInfo),
};

/// Disegna la forma del tono in un riquadro di [w]×8 px a partire da (x, y).
void msPaintStatusShape(PixelCanvas p, MsStatusTone tone, num x, num y, Color color) {
  switch (tone) {
    case MsStatusTone.neutral || MsStatusTone.ok:
      p.rect(x, y, 8, 8, color);
    case MsStatusTone.warn:
      // triangolo 10×8 a gradini di 2 px
      p.rect(x + 4, y, 2, 2, color);
      p.rect(x + 2, y + 2, 6, 4, color);
      p.rect(x, y + 6, 10, 2, color);
    case MsStatusTone.err:
      // croce 8×8
      for (final (cx, cy) in const [
        (0, 0),
        (6, 0),
        (2, 2),
        (4, 2),
        (2, 4),
        (4, 4),
        (0, 6),
        (6, 6),
      ]) {
        p.rect(x + cx, y + cy, 2, 2, color);
      }
    case MsStatusTone.info:
      p.rect(x, y, 4, 8, color);
  }
}

double _shapeWidth(MsStatusTone t) => switch (t) {
  MsStatusTone.warn => 10,
  MsStatusTone.info => 4,
  _ => 8,
};

/// Pillola di stato (`.ms-pill`): forma pixel + testo, contorno nel colore
/// del tono su --ms-panel; [solid] la riempie del colore del tono.
class MsPill extends StatelessWidget {
  const MsPill(this.label, {super.key, this.tone = MsStatusTone.neutral, this.solid = false});

  final String label;
  final MsStatusTone tone;
  final bool solid;

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final (tint, on) = msStatusColors(c, tone);
    final bg = solid ? tint : c.panel;
    final fg = solid ? on : tint;
    final sw = _shapeWidth(tone);
    final compact = MsCompact.of(context);
    // nella testa di un pannello: niente contorno, il bordo destro del testo
    // si allinea ai pulsanti del corpo
    final plain = compact && !solid;
    return PixelFrame(
      minHeight: compact ? 24 : 32,
      // stesso margine interno a sinistra e a destra
      padding: plain
          ? EdgeInsets.zero
          : EdgeInsets.fromLTRB(10, compact ? 0 : 2, 10, compact ? 0 : 2),
      outset: plain ? EdgeInsets.zero : const EdgeInsets.all(2),
      centerY: true,
      repaintKey: (tone, solid, plain, c),
      painter: (p, w, h) {
        if (plain) return;
        p.ring(0, 0, w, h, tint);
        p.rect(0, 0, w, h, bg);
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PixelBox(
            width: sw,
            height: 8,
            repaintKey: (tone, fg),
            painter: (p, w, h) => msPaintStatusShape(p, tone, 0, 0, fg),
          ),
          const PixelGap(8, 0),
          MsText(label, kind: MsTextKind.labelSmall, color: fg, maxLines: 1),
        ],
      ),
    );
  }
}

/// Variante di [MsChip].
enum MsChipTone {
  /// `.ms-chip`: --ms-panel-hi.
  neutral,

  /// `.ms-chip--accent`: fondo e inchiostro d'accento.
  accent,

  /// `.ms-chip--update`: pieno d'accento con filo di luce (aggiornamento
  /// pronto); di solito cliccabile.
  update,
}

/// Chip (`.ms-chip`): etichetta compatta con icona facoltativa. Con [onTap]
/// diventa un pulsante (alto almeno 32 px).
class MsChip extends StatelessWidget {
  const MsChip(
    this.label, {
    super.key,
    this.icon,
    this.tone = MsChipTone.neutral,
    this.onTap,
    this.forceFocus = false,
  });

  final String label;

  /// Icona 16 px: riceve colore e dimensione da [IconTheme].
  final Widget? icon;
  final MsChipTone tone;
  final VoidCallback? onTap;
  final bool forceFocus;

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final g = PixelScope.of(context);
    final (bg, fg) = switch (tone) {
      MsChipTone.neutral => (c.panelHi, c.text),
      MsChipTone.accent => (c.accentBg, c.accentInk),
      MsChipTone.update => (c.accent, c.onAccent),
    };
    return MsPressable(
      onTap: onTap,
      forceFocus: forceFocus,
      builder: (context, s) => Semantics(
        button: onTap != null,
        child: PixelFrame(
          minHeight: 32,
          padding: const EdgeInsets.fromLTRB(10, 2, 10, 2),
          outset: const EdgeInsets.all(2),
          centerY: true,
          repaintKey: (tone, s.focused, c),
          painter: (p, w, h) {
            p.ring(0, 0, w, h, c.pxOutline);
            p.rect(0, 0, w, h, bg);
            if (tone == MsChipTone.update) p.rect(0, 0, w, 2, c.accentHi);
            if (s.focused) p.outline(-2, -2, w + 4, h + 4, c.focus);
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                IconTheme(
                  data: IconThemeData(color: fg, size: g.d(16)),
                  child: icon!,
                ),
                const PixelGap(6, 0),
              ],
              MsText(label, kind: MsTextKind.small, color: fg, weight: 600, maxLines: 1),
            ],
          ),
        ),
      ),
    );
  }
}

/// Etichetta a sola icona: quadrato di 24×24 px (contorno --ms-px-outline di
/// 2 px compreso) su --ms-panel-hi come [MsChip], con un'icona di 16 px. Per
/// le eccezioni che si leggono a colpo d'occhio in una riga (es. «solo sul
/// server»): il significato sta nel [tooltip], che è anche l'etichetta per
/// gli screen reader. Il colore resta neutro.
class MsIconTag extends StatelessWidget {
  const MsIconTag(this.icon, {super.key, required this.tooltip});

  /// Icona 16 px: riceve colore e dimensione da [IconTheme].
  final Widget icon;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final g = PixelScope.of(context);
    return MsTooltip(
      message: tooltip,
      child: Semantics(
        label: tooltip,
        container: true,
        excludeSemantics: true,
        child: PixelFrame(
          minWidth: 20,
          minHeight: 20,
          outset: const EdgeInsets.all(2),
          centerX: true,
          centerY: true,
          repaintKey: c,
          painter: (p, w, h) {
            p.ring(0, 0, w, h, c.pxOutline);
            p.rect(0, 0, w, h, c.panelHi);
          },
          child: IconTheme(
            data: IconThemeData(color: c.text, size: g.d(16)),
            child: SizedBox(
              width: g.d(16),
              height: g.d(16),
              child: Center(child: icon),
            ),
          ),
        ),
      ),
    );
  }
}

/// Stato del lock di un server.
enum MsLockState {
  /// Libero: contorno pieno e quadrato vuoto.
  free,

  /// In gioco: blocco pieno e triangolo "play" che lampeggia.
  play,

  /// Stale (heartbeat perso): contorno tratteggiato e clessidra.
  stale,
}

/// Stato del lock (`.ms-lock`): tre forme diverse oltre alla tinta.
/// [meta] è il testo secondario, non in grassetto (es. il nome di chi gioca).
class MsLock extends StatefulWidget {
  const MsLock({
    super.key,
    required this.label,
    this.state = MsLockState.free,
    this.meta,
    this.big = false,
  });

  final String label;
  final MsLockState state;
  final String? meta;

  /// `.ms-lock--big`: alto 44 px, etichetta 16/24.
  final bool big;

  @override
  State<MsLock> createState() => _MsLockState();
}

class _MsLockState extends State<MsLock> {
  // ms-blink 1,6 s a due scatti: acceso, poi al 35 %.
  final _blink = MsBlink(const Duration(milliseconds: 1600));

  void _sync() {
    final run = widget.state == MsLockState.play && !MsTheme.reducedMotionOf(context);
    if (run && !_blink.isAnimating) {
      _blink.repeat();
    } else if (!run && _blink.isAnimating) {
      _blink.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(MsLock old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final state = widget.state;
    final tint = switch (state) {
      MsLockState.free => c.lockFree,
      MsLockState.play => c.lockPlay,
      MsLockState.stale => c.lockStale,
    };
    final play = state == MsLockState.play;
    final bg = play ? tint : c.panel;
    final fg = play ? c.onInfo : tint;
    final dimFg = msBlend(fg, bg, .35);
    final big = widget.big;
    final labelKind = big ? MsTextKind.label : MsTextKind.labelSmall;
    return PixelFrame(
      minHeight: big ? 44 : 32,
      padding: big
          ? const EdgeInsets.fromLTRB(14, 8, 14, 8)
          : const EdgeInsets.fromLTRB(10, 4, 10, 4),
      outset: const EdgeInsets.all(2),
      centerY: true,
      repaintKey: (state, c),
      painter: (p, w, h) {
        switch (state) {
          case MsLockState.free:
            p.ring(0, 0, w, h, tint);
            p.rect(0, 0, w, h, bg);
          case MsLockState.play:
            p.ring(0, 0, w, h, c.pxOutline);
            p.rect(0, 0, w, h, bg);
            p.rect(0, h - 2, w, 2, msBlend(const Color(0xFF000000), bg, .25));
          case MsLockState.stale:
            p.rect(0, 0, w, h, bg);
            p.dashedOutline(0, 0, w, h, tint);
        }
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _blink,
            builder: (context, _) {
              final on = _blink.value < .5;
              final color = on ? fg : dimFg;
              return PixelBox(
                width: state == MsLockState.play ? 8 : 10,
                height: 10,
                repaintKey: (state, color),
                painter: (p, w, h) => _paintLockShape(p, state, color),
              );
            },
          ),
          const PixelGap(8, 0),
          MsText(widget.label, kind: labelKind, color: fg, maxLines: 1),
          if (widget.meta != null) ...[
            const PixelGap(8, 0),
            MsText(widget.meta!, kind: MsTextKind.small, color: fg, weight: 600, maxLines: 1),
          ],
        ],
      ),
    );
  }
}

void _paintLockShape(PixelCanvas p, MsLockState s, Color color) {
  switch (s) {
    case MsLockState.free:
      // quadrato vuoto 10×10, bordo 2
      p.rect(0, 0, 10, 2, color);
      p.rect(0, 8, 10, 2, color);
      p.rect(0, 2, 2, 6, color);
      p.rect(8, 2, 2, 6, color);
    case MsLockState.play:
      // triangolo "play" 8×10 a gradini
      p.rect(0, 0, 2, 10, color);
      p.rect(2, 2, 2, 6, color);
      p.rect(4, 2, 2, 6, color);
      p.rect(6, 4, 2, 2, color);
    case MsLockState.stale:
      // clessidra: barra, granello centrale, barra
      p.rect(0, 0, 10, 2, color);
      p.rect(4, 4, 2, 2, color);
      p.rect(0, 8, 10, 2, color);
  }
}

/// Indicatore live (`.ms-live`): quadratino --ms-ok con alone che lampeggia
/// e testo; [online] falso mostra il quadrato vuoto in --ms-err
/// (`.ms-live--off`). Il lampeggio è composto su [background] (predefinito
/// --ms-bg-2, il fondo di barra titolo e header).
class MsLive extends StatefulWidget {
  const MsLive(this.label, {super.key, this.online = true, this.background});

  final String label;
  final bool online;
  final Color? background;

  @override
  State<MsLive> createState() => _MsLiveState();
}

class _MsLiveState extends State<MsLive> {
  // ms-blink 2 s a due scatti: acceso, poi al 35 %.
  final _blink = MsBlink(const Duration(milliseconds: 2000));

  void _sync() {
    final run = widget.online && !MsTheme.reducedMotionOf(context);
    if (run && !_blink.isAnimating) {
      _blink.repeat();
    } else if (!run && _blink.isAnimating) {
      _blink.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(MsLive old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final bg = widget.background ?? c.bg2;
    final online = widget.online;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _blink,
          builder: (context, _) {
            final dim = online && _blink.value >= .5;
            final dot = dim ? msBlend(c.ok, bg, .35) : c.ok;
            final halo = dim ? msBlend(c.okBg, bg, .35) : c.okBg;
            return PixelBox(
              width: 8,
              height: 8,
              repaintKey: (online, dot, halo, c.err),
              painter: (p, w, h) {
                if (online) {
                  // alone di 2 px (box-shadow 0 0 0 2px) fuori dal riquadro
                  p.rect(-2, -2, 12, 12, halo);
                  p.rect(0, 0, 8, 8, dot);
                } else {
                  p.rect(0, 0, 8, 2, c.err);
                  p.rect(0, 6, 8, 2, c.err);
                  p.rect(0, 2, 2, 4, c.err);
                  p.rect(6, 2, 2, 4, c.err);
                }
              },
            );
          },
        ),
        const PixelGap(8, 0),
        MsText(
          widget.label,
          kind: MsTextKind.small,
          weight: 600,
          color: online ? c.text2 : c.err,
          maxLines: 1,
        ),
      ],
    );
  }
}

/// Contatore "livello" (`.ms-level`, es. la generazione "#128"): blocchetto
/// d'accento con numero in grassetto.
class MsLevel extends StatelessWidget {
  const MsLevel(this.text, {super.key, this.semanticLabel});

  final String text;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    // alto 36 (24 nella testa di un pannello, vedi MsCompact), largo quanto
    // serve al numero: «#2189» ci sta
    final compact = MsCompact.of(context);
    final small = compact;
    return Semantics(
      label: semanticLabel,
      child: PixelFrame(
        minWidth: compact ? 32 : 40,
        minHeight: compact ? 24 : 36,
        padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 8),
        outset: const EdgeInsets.all(2),
        centerX: true,
        centerY: true,
        repaintKey: c,
        painter: (p, w, h) {
          p.ring(0, 0, w, h, c.pxOutline);
          p.rect(0, 0, w, h, c.accent);
          p.rect(0, h - 2, w, 2, c.accentLo);
        },
        child: MsText(
          text,
          kind: small ? MsTextKind.small : MsTextKind.body,
          weight: 700,
          color: c.onAccent,
          maxLines: 1,
        ),
      ),
    );
  }
}

/// Dati brevi affiancati (autore, ora, dimensione…) come etichette piatte:
/// fondo incassato, niente contorno e niente separatori a pallino.
///
/// [MsMeta.split] spezza una riga già unita con « · ».
class MsMeta extends StatelessWidget {
  const MsMeta(this.items, {super.key, this.color, this.maxLines});

  /// Una riga « a · b · c » come etichette separate.
  factory MsMeta.split(String line, {Key? key, Color? color, int? maxLines}) => MsMeta(
    [
      for (final p in line.split(' · '))
        if (p.trim().isNotEmpty) p.trim(),
    ],
    key: key,
    color: color,
    maxLines: maxLines,
  );

  final List<String> items;

  /// Colore del testo; di norma il secondario.
  final Color? color;

  /// Con 1 le etichette stanno su una riga: la prima che non entra si
  /// accorcia con i puntini, le successive non si mostrano; senza limite
  /// vanno a capo.
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final g = PixelScope.of(context);
    final fg = color ?? c.text2;
    Widget tag(String t) => PixelFrame(
      minHeight: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      centerY: true,
      repaintKey: c.inset,
      painter: (p, w, h) => p.rect(0, 0, w, h, c.inset),
      child: MsText(t, kind: MsTextKind.small, color: fg, weight: 500, maxLines: 1),
    );
    if (maxLines == 1) {
      // su una riga: si misurano le etichette, si mostrano quelle che
      // entrano e la prima che non entra si accorcia con i puntini
      final style = msText(context, MsTextRole.sm, fg, weight: 500).toTextStyle(g);
      double natural(String t) {
        final tp = TextPainter(
          text: TextSpan(text: t, style: style),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        final w = g.ceilToUnit(tp.width) + g.d(12);
        tp.dispose();
        return w;
      }

      return LayoutBuilder(
        builder: (context, box) {
          final gap = g.d(4);
          final children = <Widget>[];
          var left = box.maxWidth;
          for (var i = 0; i < items.length; i++) {
            final need = natural(items[i]) + (i > 0 ? gap : 0);
            if (need <= left) {
              if (i > 0) children.add(const PixelGap(4, 0));
              children.add(tag(items[i]));
              left -= need;
              continue;
            }
            // non entra: accorciata nello spazio rimasto, se basta per
            // qualche lettera; le successive non si mostrano
            final room = left - (i > 0 ? gap : 0);
            if (room >= g.d(40)) {
              if (i > 0) children.add(const PixelGap(4, 0));
              children.add(SizedBox(width: room, child: tag(items[i])));
            }
            break;
          }
          return Row(mainAxisSize: MainAxisSize.min, children: children);
        },
      );
    }
    return Wrap(spacing: g.d(4), runSpacing: g.d(4), children: [for (final t in items) tag(t)]);
  }
}
