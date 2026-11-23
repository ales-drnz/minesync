// Tema del design system: palette (prato, abisso), chiaro o scuro,
// animazioni ridotte e dimensione dell'interfaccia. Fornisce
// colori, stili di testo e griglia pixel ai componenti.
import 'package:flutter/widgets.dart';

import 'pixel/grid.dart';
import 'pixel/text.dart';
import 'tokens.g.dart';

/// Palette di colori.
enum MsPalette {
  /// Verde erba su terra calda (predefinita).
  prato,

  /// Viola ametista su ardesia.
  abisso,
}

/// Impostazioni del tema scelte dall'utente.
@immutable
final class MsThemeData {
  const MsThemeData({
    this.palette = MsPalette.prato,
    this.brightness = Brightness.dark,
    this.reducedMotion = false,
    this.sizeStep = 0,
  });

  final MsPalette palette;
  final Brightness brightness;

  /// Niente animazioni (anche se il sistema non lo chiede).
  final bool reducedMotion;

  /// Dimensione dell'interfaccia: passi di un pixel fisico per unità di
  /// griglia rispetto alla scelta automatica (−1, 0, +1, +2).
  final int sizeStep;

  MsColors get colors => switch ((palette, brightness)) {
    (MsPalette.prato, Brightness.dark) => pratoDark,
    (MsPalette.prato, Brightness.light) => pratoLight,
    (MsPalette.abisso, Brightness.dark) => abissoDark,
    (MsPalette.abisso, Brightness.light) => abissoLight,
  };

  MsThemeData copyWith({
    MsPalette? palette,
    Brightness? brightness,
    bool? reducedMotion,
    int? sizeStep,
  }) => MsThemeData(
    palette: palette ?? this.palette,
    brightness: brightness ?? this.brightness,
    reducedMotion: reducedMotion ?? this.reducedMotion,
    sizeStep: sizeStep ?? this.sizeStep,
  );

  @override
  bool operator ==(Object other) =>
      other is MsThemeData &&
      other.palette == palette &&
      other.brightness == brightness &&
      other.reducedMotion == reducedMotion &&
      other.sizeStep == sizeStep;

  @override
  int get hashCode => Object.hash(palette, brightness, reducedMotion, sizeStep);
}

/// Ruoli tipografici del design.
enum MsTextRole { display, h1, h2, h3, lg, md, sm, label, con, mono }

/// Stili di testo per i ruoli.
final class MsTypography {
  const MsTypography();

  PixelTextStyle style(MsTextRole role, Color color, {int? weight}) {
    final (size, line) = switch (role) {
      MsTextRole.display => MsTypeScale.display,
      MsTextRole.h1 => MsTypeScale.h1,
      MsTextRole.h2 => MsTypeScale.h2,
      MsTextRole.h3 => MsTypeScale.h3,
      MsTextRole.lg => MsTypeScale.lg,
      MsTextRole.md => MsTypeScale.md,
      MsTextRole.sm => MsTypeScale.sm,
      MsTextRole.label => MsTypeScale.label,
      MsTextRole.con || MsTextRole.mono => MsTypeScale.con,
    };
    final w =
        weight ??
        switch (role) {
          MsTextRole.label ||
          MsTextRole.display ||
          MsTextRole.h1 ||
          MsTextRole.h2 ||
          MsTextRole.h3 => 700,
          _ => 400,
        };
    return PixelTextStyle(
      font: role == MsTextRole.con || role == MsTextRole.mono ? PixelFont.mono : PixelFont.sans,
      size: size,
      lineHeight: line,
      color: color,
      weight: w,
    );
  }
}

/// Fornisce il tema e la griglia pixel ai componenti.
class MsTheme extends StatelessWidget {
  const MsTheme({super.key, required this.data, required this.child});

  final MsThemeData data;
  final Widget child;

  static MsThemeData of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_MsThemeScope>()?.data ?? const MsThemeData();

  static MsColors colorsOf(BuildContext context) => of(context).colors;

  static MsTypography typographyOf(BuildContext context) => const MsTypography();

  /// Vero se le animazioni vanno saltate (impostazione o sistema).
  static bool reducedMotionOf(BuildContext context) =>
      of(context).reducedMotion || MediaQuery.disableAnimationsOf(context);

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    return _MsThemeScope(
      data: data,
      child: PixelScope(
        grid: PixelGrid.forDpr(dpr, step: data.sizeStep),
        child: DefaultTextStyle(
          style: TextStyle(color: data.colors.text),
          child: child,
        ),
      ),
    );
  }
}

class _MsThemeScope extends InheritedWidget {
  const _MsThemeScope({required this.data, required super.child});
  final MsThemeData data;
  @override
  bool updateShouldNotify(_MsThemeScope old) => old.data != data;
}

/// Zona compatta (la testa di un pannello): le pillole di stato sono senza
/// contorno (quadratino e testo) e i pulsanti piccoli sono bassi, così
/// restano allineati al contenuto del pannello.
class MsCompact extends InheritedWidget {
  const MsCompact({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MsCompact>() != null;

  @override
  bool updateShouldNotify(MsCompact old) => false;
}
