// Cornici dell'app desktop: sidebar (.ms-sidebar) con sezioni e voci di
// navigazione (.ms-nav), barra del titolo (.ms-titlebar) nelle varianti
// Windows/Linux (controlli a destra) e macOS (quadratini a sinistra).
import 'dart:ui' show SemanticsRole;

import 'package:flutter/widgets.dart';

import '../../pixel/grid.dart';
import '../../pixel/render.dart';
import '../../pixel/text.dart';
import '../../theme.dart';
import '../display/common.dart' show MsPixelCanvasX;
import 'core.dart';

/// Shape of an [MsNavDot]: repeats the lock state shape (never colour alone).
enum MsNavDotKind {
  /// Hollow square (lock free).
  free,

  /// Filled square (someone is playing).
  play,

  /// Dashed square (stale lock).
  stale,
}

/// Small 8x8 lock dot for nav items (`.ms-nav__dot`).
class MsNavDot extends StatelessWidget {
  const MsNavDot(this.kind, {super.key});

  final MsNavDotKind kind;

  @override
  Widget build(BuildContext context) {
    final c = msColors(context);
    // sulla voce corrente (piena d'accento) la forma resta, il colore è
    // quello sull'accento
    final on = _MsNavOnAccent.of(context);
    final free = on ? c.onAccent : c.lockFree;
    final play = on ? c.onAccent : c.lockPlay;
    final stale = on ? c.onAccent : c.lockStale;
    return ExcludeSemantics(
      child: PixelBox(
        width: 8,
        height: 8,
        repaintKey: (kind, free, play, stale),
        painter: (p, w, h) {
          switch (kind) {
            case MsNavDotKind.free:
              p.rect(0, 0, 8, 2, free);
              p.rect(0, 6, 8, 2, free);
              p.rect(0, 2, 2, 4, free);
              p.rect(6, 2, 2, 4, free);
            case MsNavDotKind.play:
              p.rect(0, 0, 8, 8, play);
            case MsNavDotKind.stale:
              msPaintBits(p, 0, 0, const ['# # ', '   #', '#   ', ' # #'], stale);
          }
        },
      ),
    );
  }
}

/// Navigation item (`.ms-nav__item`): full-width row. When [current]
/// (`aria-current="page"`) the whole item is a solid accent block with the
/// pixel outline and bevel, label, icon and trailing in the on-accent
/// colour. With [dashed] it is an action slot (e.g. "+ New server"): dashed
/// outline, same height, padding and icon column as the other items.
class MsNavItem extends StatelessWidget {
  const MsNavItem({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.current = false,
    this.dashed = false,
    this.quiet = false,
    this.trailing,
    this.semanticLabel,
    this.focusNode,
    this.forcedStates,
  });

  final String label;
  final VoidCallback? onPressed;
  final Widget? icon;
  final bool current;

  /// Action slot with a dashed outline instead of a destination.
  final bool dashed;

  /// Secondary navigation (e.g. sections of a page): the current item is a
  /// soft panel with a 4 px accent bar on the left, so it does not compete
  /// with the solid current item of the main sidebar.
  final bool quiet;

  /// `.ms-nav__trail`: e.g. an [MsNavDot] and a state word, or an [MsKbd].
  final Widget? trailing;
  final String? semanticLabel;
  final FocusNode? focusNode;
  final MsStates? forcedStates;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return MergeSemantics(
      child: Semantics(
        button: true,
        selected: current,
        enabled: enabled,
        label: semanticLabel ?? label,
        onTap: onPressed,
        child: MsPressable(
          enabled: enabled,
          onPressed: onPressed,
          focusNode: focusNode,
          forced: forcedStates,
          builder: (context, s, _) {
            final c = msColors(context);
            final hover = s.hovered && enabled && !current;
            final solid = current && !quiet;
            final fg = solid
                ? c.onAccent
                : current
                ? c.text
                : !enabled
                ? c.text3
                : (hover ? c.text : c.text2);
            return PixelFrame(
              outset: const EdgeInsets.all(2),
              padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
              minHeight: 44,
              centerY: true,
              repaintKey: (hover, current, dashed, quiet, s.focused, c),
              painter: (p, w, h) {
                if (current && quiet) {
                  p.rect(0, 0, w, h, c.panelHi);
                  p.rect(0, 0, 4, h, c.accent);
                } else if (current) {
                  p.ring(0, 0, w, h, c.pxOutline);
                  p.rect(0, 0, w, h, c.accent);
                  p.bevel(w, h, c.accentHi, c.accentLo);
                } else if (hover) {
                  p.rect(0, 0, w, h, c.panel);
                }
                if (dashed && !current) {
                  p.dashedOutline(2, 2, w - 4, h - 4, hover ? c.text2 : c.text3);
                }
                if (s.focused) {
                  // sull'accento il fuoco gira attorno alla voce
                  if (solid) {
                    p.outline(0, 0, w, h, c.focus);
                  } else {
                    p.outline(2, 2, w - 4, h - 4, c.focus);
                  }
                }
              },
              child: _MsNavOnAccent(
                on: solid,
                child: Row(
                  children: [
                    if (icon != null) ...[
                      ExcludeSemantics(child: msIconSlot(context, icon!, fg)),
                      const PixelGap(12, 0),
                    ],
                    Expanded(
                      child: PixelText(
                        label,
                        style: msText(context, MsTextRole.md, fg, weight: 600),
                      ),
                    ),
                    if (trailing != null) ...[
                      const PixelGap(6, 0),
                      ExcludeSemantics(
                        child: DefaultTextStyle.merge(
                          style: TextStyle(color: solid ? c.onAccent : c.text2),
                          child: trailing!,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Dice ai contenuti di una voce se sono sull'accento (voce corrente).
class _MsNavOnAccent extends InheritedWidget {
  const _MsNavOnAccent({required this.on, required super.child});

  final bool on;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_MsNavOnAccent>()?.on ?? false;

  @override
  bool updateShouldNotify(_MsNavOnAccent old) => old.on != on;
}

/// Trailing content of a nav item: optional [dot] and a small [text]
/// (`.ms-nav__trail`).
class MsNavTrail extends StatelessWidget {
  const MsNavTrail({super.key, this.dot, this.text});

  final MsNavDotKind? dot;
  final String? text;

  @override
  Widget build(BuildContext context) {
    final c = msColors(context);
    final fg = _MsNavOnAccent.of(context) ? c.onAccent : c.text2;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (dot != null) MsNavDot(dot!),
        if (dot != null && text != null) const PixelGap(6, 0),
        if (text != null) PixelText(text!, style: msText(context, MsTextRole.sm, fg)),
      ],
    );
  }
}

/// Vertical list of [MsNavItem]s (`.ms-nav`), 4 px apart.
class MsNav extends StatelessWidget {
  const MsNav({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < children.length; i++) ...[if (i > 0) const PixelGap(0, 4), children[i]],
    ],
  );
}

/// Section heading inside a sidebar (`.ms-sidebar__section`).
class MsSidebarSection extends StatelessWidget {
  const MsSidebarSection(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = msColors(context);
    return Semantics(
      header: true,
      label: label,
      excludeSemantics: true,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          PixelScope.of(context).d(12),
          PixelScope.of(context).d(12),
          PixelScope.of(context).d(12),
          PixelScope.of(context).d(4),
        ),
        child: PixelText(
          msSentenceCase(label),
          style: msText(context, MsTextRole.label, c.text2).copyWith(size: 14, lineHeight: 20),
        ),
      ),
    );
  }
}

/// App sidebar (`.ms-sidebar`): 256 px wide, bg-2 with the outline on the
/// right, children 4 px apart. Fills the available height. [footer] items
/// (e.g. Settings) sit at the very bottom, under a full-width pixel divider.
class MsSidebar extends StatelessWidget {
  const MsSidebar({
    super.key,
    required this.children,
    this.footer = const [],
    this.semanticLabel,
    this.width = 256,
  });

  final List<Widget> children;

  /// Items pinned to the bottom edge, below a divider.
  final List<Widget> footer;

  /// Name of the navigation landmark (e.g. "App navigation").
  final String? semanticLabel;

  /// Width in design px.
  final double width;

  @override
  Widget build(BuildContext context) {
    final c = msColors(context);
    final g = PixelScope.of(context);
    Widget list(List<Widget> items) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++) ...[if (i > 0) const PixelGap(0, 4), items[i]],
      ],
    );
    final main = Padding(
      padding: EdgeInsets.symmetric(horizontal: g.d(8), vertical: g.d(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const PixelGap(0, 4),
            children[i],
          ],
        ],
      ),
    );
    return Semantics(
      role: semanticLabel == null ? null : SemanticsRole.navigation,
      label: semanticLabel,
      container: true,
      explicitChildNodes: true,
      child: SizedBox(
        width: g.d(width),
        child: PixelFrame(
          repaintKey: (c.bg2, c.pxOutline),
          painter: (p, w, h) {
            p.rect(0, 0, w, h, c.bg2);
            p.rect(w - 2, 0, 2, h, c.pxOutline);
          },
          child: footer.isEmpty
              ? main
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: main),
                    // filo a tutta larghezza fino al contorno di destra
                    PixelFrame(
                      minHeight: 2,
                      repaintKey: c.pxOutline,
                      painter: (p, w, h) => p.rect(0, 0, w, 2, c.pxOutline),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(g.d(8), g.d(8), g.d(8), g.d(12)),
                      child: list(footer),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Window-control layout of an [MsTitlebar] (`data-os`).
enum MsTitlebarOs { windows, linux, mac }

/// Desktop title bar (`.ms-titlebar`, 44 px).
///
/// Windows/Linux: brand, breadcrumbs, drag space, [end] widgets, then the
/// three 46x44 window controls (close turns red on hover). macOS: three
/// 16x16 coloured squares first. Window integration (dragging, real
/// minimise/maximise) is up to the app; the drag space is [dragArea] or
/// empty.
class MsTitlebar extends StatelessWidget {
  const MsTitlebar({
    super.key,
    required this.os,
    required this.title,
    required this.minimizeLabel,
    required this.maximizeLabel,
    required this.closeLabel,
    this.logo,
    this.version,
    this.crumbs = const [],
    this.end = const [],
    this.maximized = false,
    this.onMinimize,
    this.onMaximize,
    this.onClose,
    this.dragArea,
    this.forcedHover,
  });

  final MsTitlebarOs os;

  /// Brand name ("MineSync").
  final String title;
  final Widget? logo;
  final String? version;

  /// Breadcrumbs; the last one is the current place (bold).
  final List<String> crumbs;
  final List<Widget> end;
  final bool maximized;
  final VoidCallback? onMinimize;
  final VoidCallback? onMaximize;
  final VoidCallback? onClose;
  final String minimizeLabel;
  final String maximizeLabel;
  final String closeLabel;

  /// Fills the free space (e.g. a window-drag detector); empty by default.
  final Widget? dragArea;

  /// Forced hover on a window control (0 minimise, 1 maximise, 2 close).
  final int? forcedHover;

  @override
  Widget build(BuildContext context) {
    final c = msColors(context);
    final g = PixelScope.of(context);
    final mac = os == MsTitlebarOs.mac;
    final ctrls = _controls(context, mac);
    final crumbsRow = crumbs.isEmpty
        ? null
        : IgnorePointer(
            child: Semantics(
              label: crumbs.join(' › '),
              excludeSemantics: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < crumbs.length; i++) ...[
                    if (i > 0) ...[
                      const PixelGap(8, 0),
                      MsGlyph(MsGlyphs.chevron, color: c.text2),
                      const PixelGap(8, 0),
                    ],
                    Flexible(
                      child: PixelText(
                        crumbs[i],
                        style: i == crumbs.length - 1
                            ? msText(context, MsTextRole.sm, c.text, weight: 600)
                            : msText(context, MsTextRole.sm, c.text2),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
    return SizedBox(
      height: g.d(44),
      child: PixelFrame(
        padding: mac ? const EdgeInsets.only(right: 12) : const EdgeInsets.only(left: 12),
        minHeight: 44,
        repaintKey: (c.bg2, c.pxOutline),
        painter: (p, w, h) {
          p.rect(0, 0, w, h, c.bg2);
          p.rect(0, h - 2, w, 2, c.pxOutline);
        },
        child: SizedBox(
          height: g.d(44),
          child: Row(
            children: [
              if (mac) ...[ctrls, const PixelGap(12, 0)],
              Semantics(
                header: true,
                label: [title, ?version].join(' '),
                excludeSemantics: true,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (logo != null) ...[
                      // un logo più piccolo del riquadro resta al centro, non in alto a sinistra
                      SizedBox(
                        width: g.d(24),
                        height: g.d(24),
                        child: Center(child: logo),
                      ),
                      const PixelGap(8, 0),
                    ],
                    PixelText(title, style: msText(context, MsTextRole.md, c.text, weight: 700)),
                    if (version != null) ...[
                      const PixelGap(8, 0),
                      PixelText(
                        version!,
                        style: PixelTextStyle(
                          font: PixelFont.mono,
                          size: 13,
                          lineHeight: 16,
                          color: c.text2,
                          weight: 500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const PixelGap(12, 0),
              // l'area di trascinamento occupa tutto lo spazio libero, anche
              // sotto le briciole: un Flexible accanto a un Expanded si
              // prenderebbe metà dello spazio anche con briciole corte
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    dragArea ?? const SizedBox.expand(),
                    if (crumbsRow != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: EdgeInsets.only(right: g.d(12)),
                          child: crumbsRow,
                        ),
                      ),
                  ],
                ),
              ),
              for (final e in end) ...[e, const PixelGap(12, 0)],
              if (!mac) ctrls,
            ],
          ),
        ),
      ),
    );
  }

  Widget _controls(BuildContext context, bool mac) {
    final items = [
      (minimizeLabel, onMinimize, MsGlyphs.minimize, false),
      (maximizeLabel, onMaximize, maximized ? MsGlyphs.restore : MsGlyphs.maximize, false),
      (closeLabel, onClose, MsGlyphs.close, true),
    ];
    final order = mac ? [2, 0, 1] : [0, 1, 2];
    return Padding(
      padding: mac
          ? EdgeInsets.only(left: PixelScope.of(context).d(16), right: PixelScope.of(context).d(8))
          : EdgeInsets.zero,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final i in order) ...[
            if (mac && i != order.first) const PixelGap(8, 0),
            _ctrl(context, items[i], i, mac),
          ],
        ],
      ),
    );
  }

  Widget _ctrl(
    BuildContext context,
    (String, VoidCallback?, List<String>, bool) item,
    int index,
    bool mac,
  ) {
    final (label, onTap, glyph, isClose) = item;
    return MergeSemantics(
      child: Semantics(
        button: true,
        label: label,
        onTap: onTap,
        child: MsPressable(
          enabled: onTap != null,
          onPressed: onTap,
          forced: forcedHover == index ? MsStates.hover : null,
          builder: (context, s, _) {
            final c = msColors(context);
            if (mac) {
              final fill = switch (index) {
                0 => c.warn,
                1 => c.ok,
                _ => c.err,
              };
              return PixelBox(
                width: 20,
                height: 20,
                repaintKey: (fill, s.focused, c.focus),
                painter: (p0, _, _) {
                  final p = p0.shiftPhys(p0.g.unitPx, p0.g.unitPx);
                  p.ring(0, 0, 16, 16, c.pxOutline);
                  p.rect(0, 0, 16, 16, fill);
                  if (s.focused) p.outline(-4, -4, 24, 24, c.focus);
                },
              );
            }
            final hot = s.hovered || s.pressed;
            final bg = hot ? (isClose ? c.err : c.panelHi) : null;
            final fg = hot ? (isClose ? c.onErr : c.text) : c.text2;
            return PixelBox(
              width: 46,
              height: 44,
              repaintKey: (bg, fg, s.focused, glyph, c.focus),
              painter: (p, w, h) {
                if (bg != null) p.rect(0, 0, w, h, bg);
                msPaintBits(p, 16, 14, glyph, fg);
                if (s.focused) p.outline(2, 2, w - 4, h - 4, c.focus);
              },
            );
          },
        ),
      ),
    );
  }
}
