// Griglia pixel: converte i "pixel di design" (px del CSS di ms.css) in pixel
// logici di Flutter in modo che ogni "pixel di sistema" (--ms-px = 2 px di
// design) corrisponda a un numero INTERO di pixel fisici.
//
//   unitPx = max(1, floor(dpr * 2))        pixel fisici per unità (2 px design)
//   unit   = unitPx / dpr                  pixel logici per unità
//
// dpr 1.0 -> 2 fisici (scala 1.00), 1.25 -> 2 (scala 0.80),
// dpr 1.5 -> 3 (scala 1.00), 2.0 -> 4 (scala 1.00).
// Con la politica "nearest" 1.25 -> 3 (scala 1.20). La politica del
// prodotto è "floor" più l'impostazione "dimensione interfaccia" ([step]):
// ogni passo aggiunge o toglie un pixel fisico per unità.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

enum PixelPolicy { floor, nearest }

@immutable
class PixelGrid {
  const PixelGrid._(this.dpr, this.unitPx, this.policy);

  factory PixelGrid.forDpr(double dpr, {PixelPolicy policy = PixelPolicy.floor, int step = 0}) {
    final raw = dpr * 2;
    final n = policy == PixelPolicy.floor ? (raw + 1e-6).floor() : (raw + 1e-6).round();
    return PixelGrid._(dpr, math.max(1, n + step), policy);
  }

  final double dpr;

  /// Pixel fisici per unità (= 2 px di design).
  final int unitPx;
  final PixelPolicy policy;

  /// Pixel logici per unità.
  double get unit => unitPx / dpr;

  /// Fattore di scala effettivo rispetto al design (1.0 = dimensione nominale).
  double get scale => unitPx / (2 * dpr);

  /// Pixel di design -> pixel logici. Esatto (multiplo di pixel fisici) per
  /// valori pari; i valori dispari cadono su mezze unità.
  double d(num designPx) => designPx / 2 * unit;

  /// Pixel fisici interi -> pixel logici.
  double phys(num physicalPx) => physicalPx / dpr;

  /// Arrotonda un valore logico al pixel fisico più vicino.
  double snap(double logical) => (logical * dpr).roundToDouble() / dpr;

  /// Arrotonda per eccesso a un multiplo intero dell'unità.
  double ceilToUnit(double logical) => (logical / unit - 1e-6).ceilToDouble() * unit;

  /// Arrotonda al multiplo di unità più vicino.
  double roundToUnit(double logical) => (logical / unit).roundToDouble() * unit;

  @override
  bool operator ==(Object other) =>
      other is PixelGrid && other.dpr == dpr && other.unitPx == unitPx;

  @override
  int get hashCode => Object.hash(dpr, unitPx);

  @override
  String toString() => 'PixelGrid(dpr: $dpr, unitPx: $unitPx, scale: $scale)';
}

/// Fornisce la griglia ai discendenti. Se [grid] è nullo la ricava dal
/// devicePixelRatio della vista.
class PixelScope extends StatelessWidget {
  const PixelScope({super.key, this.grid, required this.child});

  final PixelGrid? grid;
  final Widget child;

  static PixelGrid of(BuildContext context) {
    final s = context.dependOnInheritedWidgetOfExactType<_PixelScopeData>();
    if (s != null) return s.grid;
    return PixelGrid.forDpr(MediaQuery.devicePixelRatioOf(context));
  }

  @override
  Widget build(BuildContext context) {
    final g = grid ?? PixelGrid.forDpr(MediaQuery.devicePixelRatioOf(context));
    return _PixelScopeData(grid: g, child: child);
  }
}

class _PixelScopeData extends InheritedWidget {
  const _PixelScopeData({required this.grid, required super.child});
  final PixelGrid grid;
  @override
  bool updateShouldNotify(_PixelScopeData old) => old.grid != grid;
}

/// Calcola lo spostamento (in pixel logici) che porta l'origine di [box]
/// sul pixel fisico più vicino, tenendo conto di scroll e trasformazioni.
Offset pixelSnapDelta(RenderBox box, PixelGrid g) {
  final p = box.localToGlobal(Offset.zero);
  return Offset(g.snap(p.dx) - p.dx, g.snap(p.dy) - p.dy);
}
