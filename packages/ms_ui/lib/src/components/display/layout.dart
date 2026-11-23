// Impaginazione a blocchi: riga di colonne alte uguali (MsEqualRow) e
// colonna che, con un'altezza minima imposta, la riempie allungando l'ultimo figlio
// o spingendolo in fondo (MsFillColumn).
//
// Niente IntrinsicHeight: molti figli contengono LayoutBuilder, che non sa
// rispondere alle misure intrinseche. La riga misura invece i figli due
// volte: prima liberi in altezza, poi tutti all'altezza del più alto.
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../pixel/grid.dart';

/// Riga di colonne affiancate con un peso ciascuna e tutte alte quanto la
/// più alta (come `align-items: stretch` di una griglia flex).
///
/// Ogni figlio riceve prima la sua larghezza con l'altezza libera, poi la
/// stessa larghezza e l'altezza del figlio più alto come minimo: un
/// [MsPanel] la riempie (piede in fondo), un `MsStack(fillLast: true)`
/// allunga l'ultimo elemento.
class MsEqualRow extends StatelessWidget {
  const MsEqualRow({super.key, required this.children, this.flex, this.gap = 24});

  final List<Widget> children;

  /// Pesi delle colonne (predefinito: tutti 1).
  final List<int>? flex;

  /// Distanza tra le colonne in px di design.
  final double gap;

  @override
  Widget build(BuildContext context) {
    assert(flex == null || flex!.length == children.length, 'un peso per colonna');
    final g = PixelScope.of(context);
    return _EqualRow(
      flex: flex ?? List.filled(children.length, 1),
      gap: g.d(gap),
      dpr: g.dpr,
      children: children,
    );
  }
}

class _EqualRow extends MultiChildRenderObjectWidget {
  const _EqualRow({required this.flex, required this.gap, required this.dpr, super.children});

  final List<int> flex;
  final double gap;
  final double dpr;

  @override
  RenderMsEqualRow createRenderObject(BuildContext context) =>
      RenderMsEqualRow(flex: flex, gap: gap, dpr: dpr);

  @override
  void updateRenderObject(BuildContext context, RenderMsEqualRow renderObject) {
    renderObject
      ..flex = flex
      ..gap = gap
      ..dpr = dpr;
  }
}

class _BlockParentData extends ContainerBoxParentData<RenderBox> {}

/// Render di [MsEqualRow].
class RenderMsEqualRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _BlockParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _BlockParentData> {
  RenderMsEqualRow({required List<int> flex, required double gap, required double dpr})
    : _flex = flex,
      _gap = gap,
      _dpr = dpr;

  List<int> _flex;
  set flex(List<int> v) {
    if (listEquals(v, _flex)) return;
    _flex = v;
    markNeedsLayout();
  }

  double _gap;
  set gap(double v) {
    if (v == _gap) return;
    _gap = v;
    markNeedsLayout();
  }

  double _dpr;
  set dpr(double v) {
    if (v == _dpr) return;
    _dpr = v;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _BlockParentData) child.parentData = _BlockParentData();
  }

  List<RenderBox> get _kids {
    final out = <RenderBox>[];
    var c = firstChild;
    while (c != null) {
      out.add(c);
      c = childAfter(c);
    }
    return out;
  }

  int _flexAt(int i) => i < _flex.length ? math.max(1, _flex[i]) : 1;

  // Larghezze delle colonne, arrotondate per difetto al pixel fisico.
  List<double> _widths(double maxWidth, int n) {
    if (n == 0) return const [];
    final total = [for (var i = 0; i < n; i++) _flexAt(i)].fold(0, (a, b) => a + b);
    final free = math.max(0.0, maxWidth - _gap * (n - 1));
    return [
      for (var i = 0; i < n; i++) (free * _flexAt(i) / total * _dpr + 1e-6).floorToDouble() / _dpr,
    ];
  }

  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final kids = _kids;
    if (kids.isEmpty) return constraints.smallest;
    assert(constraints.hasBoundedWidth, 'MsEqualRow ha bisogno di una larghezza limitata');
    final ws = _widths(constraints.maxWidth, kids.length);
    var h = constraints.minHeight;
    final sizes = <Size>[];
    for (var i = 0; i < kids.length; i++) {
      final cc = BoxConstraints(minWidth: ws[i], maxWidth: ws[i], maxHeight: constraints.maxHeight);
      final s = dry ? kids[i].getDryLayout(cc) : _lay(kids[i], cc);
      sizes.add(s);
      h = math.max(h, s.height);
    }
    if (!dry) {
      var x = 0.0;
      for (var i = 0; i < kids.length; i++) {
        // altezza come minimo, non stretta: un figlio con vincoli stretti
        // diventa un confine di relayout e la riga non si accorgerebbe se il
        // suo contenuto cresce
        kids[i].layout(
          BoxConstraints(
            minWidth: ws[i],
            maxWidth: ws[i],
            minHeight: h,
            maxHeight: constraints.maxHeight,
          ),
          parentUsesSize: true,
        );
        (kids[i].parentData! as _BlockParentData).offset = Offset(x, 0);
        x += ws[i] + _gap;
      }
    }
    return constraints.constrain(Size(constraints.maxWidth, h));
  }

  Size _lay(RenderBox child, BoxConstraints c) {
    child.layout(c, parentUsesSize: true);
    return child.size;
  }

  @override
  void performLayout() => size = _layout(constraints, dry: false);

  @override
  Size computeDryLayout(BoxConstraints constraints) => _layout(constraints, dry: true);

  @override
  double computeMinIntrinsicWidth(double height) =>
      _kids.fold(0.0, (a, c) => a + c.getMinIntrinsicWidth(height)) +
      _gap * math.max(0, childCount - 1);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _kids.fold(0.0, (a, c) => a + c.getMaxIntrinsicWidth(height)) +
      _gap * math.max(0, childCount - 1);

  double _maxHeight(double width, double Function(RenderBox, double) f) {
    final kids = _kids;
    if (kids.isEmpty || !width.isFinite) {
      return kids.fold(0.0, (a, c) => math.max(a, f(c, double.infinity)));
    }
    final ws = _widths(width, kids.length);
    var h = 0.0;
    for (var i = 0; i < kids.length; i++) {
      h = math.max(h, f(kids[i], ws[i]));
    }
    return h;
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _maxHeight(width, (c, w) => c.getMinIntrinsicHeight(w));

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _maxHeight(width, (c, w) => c.getMaxIntrinsicHeight(w));

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      defaultComputeDistanceToFirstActualBaseline(baseline);

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// Cosa fa una [MsFillColumn] con l'altezza in più quando il genitore ne
/// impone un'altezza minima.
enum MsFill {
  /// Niente: i figli restano in alto, lo spazio in più resta vuoto sotto.
  none,

  /// L'ultimo figlio si allunga fino in fondo (riceve il resto come altezza minima).
  expandLast,

  /// L'ultimo figlio resta della sua altezza ma va in fondo (piede di un
  /// pannello).
  pushLast,
}

/// Colonna con [gap] px di design tra i figli. Con altezza libera o solo
/// limitata è come una `Column(mainAxisSize: min)`; con un'altezza minima imposta
/// la occupa tutta secondo [fill].
class MsFillColumn extends StatelessWidget {
  const MsFillColumn({
    super.key,
    required this.children,
    this.fill = MsFill.expandLast,
    this.gap = 0,
    this.crossAxisAlignment = CrossAxisAlignment.stretch,
  });

  final List<Widget> children;
  final MsFill fill;

  /// Distanza tra i figli in px di design.
  final double gap;

  /// Allineamento orizzontale dei figli ([CrossAxisAlignment.baseline] non
  /// è supportato e vale come start).
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) => _FillColumn(
    fill: fill,
    gap: PixelScope.of(context).d(gap),
    cross: crossAxisAlignment,
    children: children,
  );
}

class _FillColumn extends MultiChildRenderObjectWidget {
  const _FillColumn({required this.fill, required this.gap, required this.cross, super.children});

  final MsFill fill;
  final double gap;
  final CrossAxisAlignment cross;

  @override
  RenderMsFillColumn createRenderObject(BuildContext context) =>
      RenderMsFillColumn(fill: fill, gap: gap, cross: cross);

  @override
  void updateRenderObject(BuildContext context, RenderMsFillColumn renderObject) {
    renderObject
      ..fill = fill
      ..gap = gap
      ..cross = cross;
  }
}

/// Render di [MsFillColumn].
class RenderMsFillColumn extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _BlockParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _BlockParentData> {
  RenderMsFillColumn({required MsFill fill, required double gap, required CrossAxisAlignment cross})
    : _fill = fill,
      _gap = gap,
      _cross = cross;

  MsFill _fill;
  set fill(MsFill v) {
    if (v == _fill) return;
    _fill = v;
    markNeedsLayout();
  }

  double _gap;
  set gap(double v) {
    if (v == _gap) return;
    _gap = v;
    markNeedsLayout();
  }

  CrossAxisAlignment _cross;
  set cross(CrossAxisAlignment v) {
    if (v == _cross) return;
    _cross = v;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _BlockParentData) child.parentData = _BlockParentData();
  }

  List<RenderBox> get _kids {
    final out = <RenderBox>[];
    var c = firstChild;
    while (c != null) {
      out.add(c);
      c = childAfter(c);
    }
    return out;
  }

  bool get _stretch => _cross == CrossAxisAlignment.stretch;

  BoxConstraints _childConstraints(BoxConstraints c) => _stretch && c.hasBoundedWidth
      ? BoxConstraints.tightFor(width: c.maxWidth)
      : BoxConstraints(maxWidth: c.maxWidth);

  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final kids = _kids;
    // il genitore impone un'altezza minima da riempire
    final tight = constraints.minHeight > 0 && constraints.minHeight.isFinite;
    final cc = _childConstraints(constraints);
    Size lay(RenderBox k, BoxConstraints c) {
      if (dry) return k.getDryLayout(c);
      k.layout(c, parentUsesSize: true);
      return k.size;
    }

    final sizes = <Size>[];
    final gaps = _gap * math.max(0, kids.length - 1);
    var used = gaps;
    for (var i = 0; i < kids.length; i++) {
      final last = i == kids.length - 1;
      if (last && tight && _fill == MsFill.expandLast) {
        final h = math.max(0.0, constraints.minHeight - used);
        sizes.add(lay(kids[i], cc.copyWith(minHeight: math.min(h, cc.maxHeight))));
      } else {
        sizes.add(lay(kids[i], cc));
      }
      used += sizes.last.height;
    }
    final maxChildW = sizes.fold(0.0, (a, s) => math.max(a, s.width));
    final w = _stretch && constraints.hasBoundedWidth ? constraints.maxWidth : maxChildW;
    final size = constraints.constrain(Size(w, used));
    if (!dry) {
      var y = 0.0;
      for (var i = 0; i < kids.length; i++) {
        final s = sizes[i];
        final last = i == kids.length - 1;
        if (last && tight && _fill == MsFill.pushLast) y = math.max(y, size.height - s.height);
        final x = switch (_cross) {
          CrossAxisAlignment.center => (size.width - s.width) / 2,
          CrossAxisAlignment.end => size.width - s.width,
          _ => 0.0,
        };
        (kids[i].parentData! as _BlockParentData).offset = Offset(x, y);
        y += s.height + _gap;
      }
    }
    return size;
  }

  @override
  void performLayout() => size = _layout(constraints, dry: false);

  @override
  Size computeDryLayout(BoxConstraints constraints) => _layout(constraints, dry: true);

  @override
  double computeMinIntrinsicWidth(double height) =>
      _kids.fold(0.0, (a, c) => math.max(a, c.getMinIntrinsicWidth(double.infinity)));

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _kids.fold(0.0, (a, c) => math.max(a, c.getMaxIntrinsicWidth(double.infinity)));

  @override
  double computeMinIntrinsicHeight(double width) =>
      _kids.fold(0.0, (a, c) => a + c.getMinIntrinsicHeight(width)) +
      _gap * math.max(0, childCount - 1);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _kids.fold(0.0, (a, c) => a + c.getMaxIntrinsicHeight(width)) +
      _gap * math.max(0, childCount - 1);

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      defaultComputeDistanceToFirstActualBaseline(baseline);

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
