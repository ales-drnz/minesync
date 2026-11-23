// Indicatori e messaggi di ms.css: .ms-spin (+ --lg), .ms-skel (+ --title,
// --text, --short, --sq), .ms-empty (+ --error), .ms-alert (+ --ok/--warn/
// --err), .ms-stat e .ms-facts.
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../../pixel/grid.dart';
import '../../pixel/render.dart';
import '../../theme.dart';
import 'common.dart';
import 'panel.dart';
import 'text.dart';

/// Spinner a blocchi (`.ms-spin`): quattro blocchi 2×2 attenuati e uno
/// acceso che gira a scatti (0,8 s). Con le animazioni ridotte resta fermo.
///
/// I blocchi attenuati (35 %) sono composti su [background] (predefinito
/// --ms-panel) per restare colori pieni.
class MsSpinner extends StatefulWidget {
  const MsSpinner({super.key, this.large = false, this.color, this.background, this.semanticLabel});

  /// `.ms-spin--lg`: 32 px.
  final bool large;

  /// Colore (predefinito --ms-text).
  final Color? color;
  final Color? background;

  /// Etichetta ("Caricamento"); senza, lo spinner è decorativo.
  final String? semanticLabel;

  @override
  State<MsSpinner> createState() => _MsSpinnerState();
}

class _MsSpinnerState extends State<MsSpinner> with SingleTickerProviderStateMixin {
  late final AnimationController _walk = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );

  void _sync() {
    final run = !MsTheme.reducedMotionOf(context);
    if (run && !_walk.isAnimating) {
      _walk.repeat();
    } else if (!run && _walk.isAnimating) {
      _walk
        ..stop()
        ..value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void dispose() {
    _walk.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final fg = widget.color ?? c.text;
    final dim = msBlend(fg, widget.background ?? c.panel, .35);
    final k = widget.large ? 2 : 1;
    final box = AnimatedBuilder(
      animation: _walk,
      builder: (context, _) {
        final step = (_walk.value * 4).floor().clamp(0, 3);
        return PixelBox(
          width: 16.0 * k,
          height: 16.0 * k,
          repaintKey: (step, fg, dim),
          painter: (p, w, h) {
            const pos = [(0, 0), (10, 0), (10, 10), (0, 10)];
            for (final (x, y) in pos) {
              p.rect(x * k, y * k, 6 * k, 6 * k, dim);
            }
            final (x, y) = pos[step];
            p.rect(x * k, y * k, 6 * k, 6 * k, fg);
          },
        );
      },
    );
    final framed = widget.large
        ? Padding(padding: EdgeInsets.all(PixelScope.of(context).d(8)), child: box)
        : box;
    if (widget.semanticLabel == null) return ExcludeSemantics(child: framed);
    return Semantics(
      role: SemanticsRole.loadingSpinner,
      label: widget.semanticLabel,
      child: ExcludeSemantics(child: framed),
    );
  }
}

/// Blocco segnaposto in caricamento (`.ms-skel`): --ms-panel-hi con una
/// banda a strisce che scorre (1,4 s a 10 scatti); fermo con le animazioni
/// ridotte. Escluso dalla semantica (decorativo).
class MsSkeleton extends StatefulWidget {
  const MsSkeleton({super.key, this.width, this.widthFactor = 1, this.height = 16});

  /// `.ms-skel--title`: alto 24, largo 60 %.
  const MsSkeleton.title({super.key}) : width = null, widthFactor = .6, height = 24;

  /// `.ms-skel--text`: largo 90 %.
  const MsSkeleton.text({super.key}) : width = null, widthFactor = .9, height = 16;

  /// `.ms-skel--short`: largo 40 %.
  const MsSkeleton.short({super.key}) : width = null, widthFactor = .4, height = 16;

  /// `.ms-skel--sq`: 48×48.
  const MsSkeleton.square({super.key}) : width = 48, widthFactor = 1, height = 48;

  /// Larghezza fissa in px di design (prevale su [widthFactor]).
  final double? width;

  /// Frazione della larghezza disponibile.
  final double widthFactor;

  /// Altezza in px di design.
  final double height;

  @override
  State<MsSkeleton> createState() => _MsSkeletonState();
}

class _MsSkeletonState extends State<MsSkeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _shine = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  void _sync() {
    final run = !MsTheme.reducedMotionOf(context);
    if (run && !_shine.isAnimating) {
      _shine.repeat();
    } else if (!run && _shine.isAnimating) {
      _shine
        ..stop()
        ..value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void dispose() {
    _shine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final g = PixelScope.of(context);
    final stripe = msBlend(c.overlay, c.panelHi, .7);
    final reduced = MsTheme.reducedMotionOf(context);
    return ExcludeSemantics(
      child: LayoutBuilder(
        builder: (context, box) {
          final avail = box.hasBoundedWidth ? box.maxWidth / g.unit * 2 : 0.0;
          final w = widget.width ?? ((avail * widget.widthFactor) / 2 + 1e-6).floorToDouble() * 2;
          return AnimatedBuilder(
            animation: _shine,
            builder: (context, _) {
              final step = (_shine.value * 10).floor().clamp(0, 9);
              return PixelBox(
                width: w,
                height: widget.height,
                repaintKey: (step, reduced, c),
                painter: (p, w, h) {
                  p.rect(0, 0, w, h, c.panelHi);
                  if (reduced) return;
                  final bw = ((w * .4) / 2).round() * 2.0;
                  final x0 = ((bw * (-1 + 3.8 * step / 10)) / 2).round() * 2.0;
                  for (var x = x0; x < x0 + bw; x += 12) {
                    final l = x < 0 ? 0.0 : x;
                    var r = x + 8;
                    if (r > x0 + bw) r = x0 + bw;
                    if (r > w) r = w;
                    if (r > l) p.rect(l, 0, r - l, h, stripe);
                  }
                },
              );
            },
          );
        },
      ),
    );
  }
}

/// Stato vuoto o di errore (`.ms-empty`, `.ms-empty--error`): illustrazione
/// 96×96, titolo, testo e azione, centrati. La variante errore ha il ruolo
/// "alert" (annunciata).
class MsEmptyState extends StatelessWidget {
  const MsEmptyState({
    super.key,
    required this.title,
    this.text,
    this.art,
    this.action,
    this.error = false,
  });

  final String title;
  final String? text;

  /// Illustrazione pixel (ospitata in 96×96).
  final Widget? art;

  /// Azione principale (di solito un pulsante).
  final Widget? action;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    final content = Padding(
      padding: EdgeInsets.symmetric(horizontal: g.d(24), vertical: g.d(40)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: g.d(12),
        children: [
          if (art != null)
            SizedBox.square(
              dimension: g.d(96),
              child: Center(child: art),
            ),
          MsText.h3(
            title,
            tone: error ? MsTextTone.err : MsTextTone.primary,
            align: TextAlign.center,
          ),
          if (text != null)
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: g.d(420)),
              child: MsText(text!, tone: MsTextTone.secondary, align: TextAlign.center),
            ),
          ?action,
        ],
      ),
    );
    return Semantics(
      container: true,
      role: error ? SemanticsRole.alert : null,
      child: Center(widthFactor: 1, child: content),
    );
  }
}

/// Tono di [MsAlert].
enum MsAlertTone { info, ok, warn, err }

/// Avviso persistente (`.ms-alert`): fondo tenue del tono, barra di 6 px a
/// sinistra e contorno nel colore del tono, icona, titolo, testo e azioni.
/// È annunciato: ruolo "alert" per gli errori, "status" per gli altri toni
/// (i ruoli implicano la regione live).
class MsAlert extends StatelessWidget {
  const MsAlert({
    super.key,
    required this.title,
    this.text,
    this.icon,
    this.actions = const [],
    this.tone = MsAlertTone.info,
  });

  final String title;
  final String? text;

  /// Icona 16 px: riceve il colore del tono da [IconTheme].
  final Widget? icon;
  final List<Widget> actions;
  final MsAlertTone tone;

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final g = PixelScope.of(context);
    final (tint, bg) = switch (tone) {
      MsAlertTone.info => (c.info, c.infoBg),
      MsAlertTone.ok => (c.ok, c.okBg),
      MsAlertTone.warn => (c.warn, c.warnBg),
      MsAlertTone.err => (c.err, c.errBg),
    };
    return Semantics(
      container: true,
      role: tone == MsAlertTone.err ? SemanticsRole.alert : SemanticsRole.status,
      child: MsUnitWidth(
        child: PixelFrame(
          padding: const EdgeInsets.fromLTRB(20, 12, 16, 12),
          outset: const EdgeInsets.all(2),
          repaintKey: (tone, c),
          painter: (p, w, h) {
            p.ring(0, 0, w, h, tint);
            p.rect(0, 0, w, h, bg);
            p.rect(0, 0, 6, h, tint);
          },
          // azioni centrate sull'altezza del testo; l'icona resta sul titolo
          child: Row(
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (icon != null) ...[
                      Padding(
                        padding: EdgeInsets.only(top: g.d(4)),
                        child: IconTheme(
                          data: IconThemeData(color: tint, size: g.d(16)),
                          child: icon!,
                        ),
                      ),
                      const PixelGap(12, 0),
                    ],
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          MsText(title, weight: 700),
                          if (text != null) MsText.small(text!),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (actions.isNotEmpty) ...[
                const PixelGap(12, 0),
                Wrap(
                  spacing: g.d(8),
                  runSpacing: g.d(8),
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Statistica (`.ms-stat`): icona in uno slot quadrato, valore grande a
/// cifre tabellari ed etichetta pixel.
class MsStat extends StatelessWidget {
  const MsStat({
    super.key,
    required this.value,
    required this.label,
    this.icon,
    this.iconTone = MsTextTone.accent,
  });

  final String value;
  final String label;

  /// Icona: riceve colore e dimensione (48) da [IconTheme].
  final Widget? icon;
  final MsTextTone iconTone;

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final g = PixelScope.of(context);
    return Semantics(
      container: true,
      label: '$value $label',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            MsSlot.square(
              child: IconTheme(
                data: IconThemeData(color: msToneColor(c, iconTone), size: g.d(48)),
                child: icon!,
              ),
            ),
            const PixelGap(16, 0),
          ],
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MsText(value, kind: MsTextKind.h2, weight: 700, tabular: true, maxLines: 1),
              MsText(label, kind: MsTextKind.labelSmall, tone: MsTextTone.secondary, maxLines: 1),
            ],
          ),
        ],
      ),
    );
  }
}

/// Voce di [MsFacts].
@immutable
class MsFact {
  const MsFact(this.term, this.value, {this.child});

  final String term;
  final String value;

  /// Contenuto personalizzato al posto di [value] (che resta per la
  /// semantica).
  final Widget? child;
}

/// Elenco di definizioni (`.ms-facts`): termini in --ms-text-2 a sinistra,
/// valori in grassetto; righe a 6 px, colonne a 16 px.
class MsFacts extends StatelessWidget {
  const MsFacts(this.facts, {super.key});

  final List<MsFact> facts;

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    return Table(
      columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()},
      children: [
        for (var i = 0; i < facts.length; i++)
          TableRow(
            children: [
              Padding(
                padding: EdgeInsets.only(right: g.d(16), top: i == 0 ? 0 : g.d(6)),
                child: MsText.small(facts[i].term, tone: MsTextTone.secondary),
              ),
              Padding(
                padding: EdgeInsets.only(top: i == 0 ? 0 : g.d(6)),
                child: facts[i].child ?? MsText.small(facts[i].value, weight: 600),
              ),
            ],
          ),
      ],
    );
  }
}
