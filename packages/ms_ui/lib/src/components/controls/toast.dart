// Notifiche (.ms-toast, --ok/--warn/--err) e pila (.ms-toast-stack), più un
// piccolo gestore con chiusura automatica e barra del tempo residuo.
import 'dart:ui' show SemanticsRole;
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../pixel/grid.dart';
import '../../pixel/render.dart';
import '../../theme.dart';
import '../../tokens.g.dart';
import 'button.dart';
import 'core.dart';

/// Tone of an [MsToast]: info (default), ok, warn, err.
enum MsToastTone { info, ok, warn, err }

/// Toast (`.ms-toast`): coloured icon column, title, optional text, close
/// button and optional remaining-time bar ([progress] 1..0).
///
/// Announced politely (`role="status"`), errors as alerts.
class MsToast extends StatelessWidget {
  const MsToast({
    super.key,
    required this.title,
    required this.closeLabel,
    this.text,
    this.tone = MsToastTone.info,
    this.icon,
    this.onClose,
    this.progress,
  });

  final String title;
  final String? text;
  final MsToastTone tone;

  /// Icon in the coloured column (gets the `--on` colour via [IconTheme]).
  final Widget? icon;

  /// Close button; hidden when null.
  final VoidCallback? onClose;

  /// Screen-reader label of the close button ("Chiudi notifica").
  final String closeLabel;

  /// Remaining time, 1 = full bar; no bar when null.
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final c = msColors(context);
    final g = PixelScope.of(context);
    final (col, on) = switch (tone) {
      MsToastTone.info => (c.info, c.onInfo),
      MsToastTone.ok => (c.ok, c.onOk),
      MsToastTone.warn => (c.warn, c.onWarn),
      MsToastTone.err => (c.err, c.onErr),
    };
    final prog = progress?.clamp(0.0, 1.0);
    return Semantics(
      role: tone == MsToastTone.err ? SemanticsRole.alert : SemanticsRole.status,
      container: true,
      child: PixelFrame(
        outset: const EdgeInsets.fromLTRB(2, 2, 8, 8),
        padding: EdgeInsets.only(right: 4, bottom: prog == null ? 0 : 4),
        repaintKey: (col, prog, c.overlay, c.drop),
        painter: (p, w, h) {
          p.rect(6, 6, w, h, c.drop);
          p.ring(0, 0, w, h, c.pxOutline);
          p.rect(0, 0, w, h, c.overlay);
          p.bevel(w, h, c.pxLight, c.pxShadow);
          final barH = prog == null ? 0.0 : 4.0;
          p.rect(0, 0, 44, h - barH, col);
          if (prog != null) {
            final bw = ((w * prog) / 2).round() * 2.0;
            p.rect(0, h - 4, bw, 4, col);
          }
        },
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: g.d(44),
              child: Padding(
                padding: EdgeInsets.only(top: g.d(14)),
                child: Center(
                  child: icon == null
                      ? SizedBox(height: g.d(16))
                      : ExcludeSemantics(child: msIconSlot(context, icon!, on)),
                ),
              ),
            ),
            const PixelGap(12, 0),
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: g.d(12)),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MsWrapText(title, style: msText(context, MsTextRole.md, c.text, weight: 600)),
                    if (text != null)
                      MsWrapText(text!, style: msText(context, MsTextRole.sm, c.text2)),
                  ],
                ),
              ),
            ),
            if (onClose != null) ...[
              const PixelGap(12, 0),
              Padding(
                padding: EdgeInsets.only(top: g.d(2)),
                child: MsButton.icon(
                  icon: _CloseGlyph(),
                  semanticLabel: closeLabel,
                  variant: MsButtonVariant.ghost,
                  onPressed: onClose,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CloseGlyph extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      MsGlyph(MsGlyphs.close, color: IconTheme.of(context).color ?? msColors(context).text);
}

/// Vertical stack of toasts (`.ms-toast-stack`): 12 px apart, at most
/// 420 px wide.
class MsToastStack extends StatelessWidget {
  const MsToastStack({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    return LayoutBuilder(
      builder: (context, cons) {
        final max = g.d(420 + 10);
        final w = cons.hasBoundedWidth ? math.min(cons.maxWidth, max) : max;
        return SizedBox(
          width: w,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const PixelGap(0, 12),
                children[i],
              ],
            ],
          ),
        );
      },
    );
  }
}

/// A toast queued in an [MsToastController].
@immutable
final class MsToastData {
  const MsToastData({
    required this.title,
    this.text,
    this.tone = MsToastTone.info,
    this.icon,
    this.duration = const Duration(seconds: 6),
  });

  final String title;
  final String? text;
  final MsToastTone tone;
  final Widget? icon;

  /// Auto-dismiss after this time (with the remaining-time bar); null keeps
  /// the toast until closed.
  final Duration? duration;
}

/// Queue of toasts shown by an [MsToastHost].
class MsToastController extends ChangeNotifier {
  final List<(int, MsToastData)> _items = [];
  int _next = 0;

  List<(int, MsToastData)> get items => List.unmodifiable(_items);

  /// Shows [data]; returns its id for [dismiss].
  int show(MsToastData data) {
    final id = _next++;
    _items.add((id, data));
    notifyListeners();
    return id;
  }

  void dismiss(int id) {
    _items.removeWhere((e) => e.$1 == id);
    notifyListeners();
  }
}

/// Puts an [MsToastStack] in the bottom-right corner over [child] (above
/// dialogs when it wraps the navigator, `MsZ.toast`). Toasts slide in from
/// 16 px on the right ([MsDuration.d3]) and close on their own after their
/// duration; the timer pauses while the pointer is over the stack.
class MsToastHost extends StatefulWidget {
  const MsToastHost({
    super.key,
    required this.controller,
    required this.closeLabel,
    required this.child,
  });

  final MsToastController controller;
  final String closeLabel;
  final Widget child;

  @override
  State<MsToastHost> createState() => _MsToastHostState();
}

class _MsToastHostState extends State<MsToastHost> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(MsToastHost old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  bool _paused = false;

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    final items = widget.controller.items;
    return Stack(
      children: [
        widget.child,
        if (items.isNotEmpty)
          Positioned(
            right: g.d(16),
            bottom: g.d(16),
            child: MouseRegion(
              onEnter: (_) => setState(() => _paused = true),
              onExit: (_) => setState(() => _paused = false),
              child: MsToastStack(
                children: [
                  for (final (id, data) in items)
                    _LiveToast(
                      key: ValueKey(id),
                      data: data,
                      paused: _paused,
                      closeLabel: widget.closeLabel,
                      onClose: () => widget.controller.dismiss(id),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _LiveToast extends StatefulWidget {
  const _LiveToast({
    super.key,
    required this.data,
    required this.paused,
    required this.closeLabel,
    required this.onClose,
  });

  final MsToastData data;
  final bool paused;
  final String closeLabel;
  final VoidCallback onClose;

  @override
  State<_LiveToast> createState() => _LiveToastState();
}

class _LiveToastState extends State<_LiveToast> with TickerProviderStateMixin {
  late final AnimationController _in = AnimationController(vsync: this, duration: MsDuration.d3);
  AnimationController? _life;

  @override
  void initState() {
    super.initState();
    final d = widget.data.duration;
    if (d != null) {
      _life = AnimationController(vsync: this, duration: d)
        ..addStatusListener((s) {
          if (s == AnimationStatus.completed) widget.onClose();
        });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MsTheme.reducedMotionOf(context)) {
      _in.value = 1;
    } else if (_in.value == 0 && !_in.isAnimating) {
      _in.forward();
    }
    if (_life != null && !_life!.isAnimating && _life!.value == 0 && !widget.paused) {
      unawaited(_life!.forward());
    }
  }

  @override
  void didUpdateWidget(_LiveToast old) {
    super.didUpdateWidget(old);
    final life = _life;
    if (life == null || old.paused == widget.paused) return;
    if (widget.paused) {
      life.stop();
    } else if (!life.isCompleted) {
      unawaited(life.forward());
    }
  }

  @override
  void dispose() {
    _in.dispose();
    _life?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    final life = _life;
    return AnimatedBuilder(
      animation: Listenable.merge([_in, ?life]),
      builder: (context, _) {
        final t = msEaseOut.transform(_in.value);
        final toast = MsToast(
          title: widget.data.title,
          text: widget.data.text,
          tone: widget.data.tone,
          icon: widget.data.icon,
          closeLabel: widget.closeLabel,
          onClose: widget.onClose,
          progress: life == null ? null : 1 - life.value,
        );
        if (t >= 1) return toast;
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(g.roundToUnit(g.d(16) * (1 - t)), 0),
            child: toast,
          ),
        );
      },
    );
  }
}
