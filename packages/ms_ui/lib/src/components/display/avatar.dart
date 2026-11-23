// Avatar generato (.ms-avatar, --sm, --lg, .ms-avatar-stack): volto 8×8
// simmetrico calcolato dall'hash del nome, due colori della tavolozza avatar
// (--ms-av-1…8) e occhi fissi. Nessuna skin: ogni volto è originale.
import 'package:flutter/widgets.dart';

import '../../pixel/grid.dart';
import '../../pixel/render.dart';
import '../../theme.dart';
import '../../tokens.g.dart';

/// Dimensione dell'avatar (lato esterno, padding compreso).
enum MsAvatarSize {
  /// `.ms-avatar--sm`: 28 px, padding 2.
  small,

  /// `.ms-avatar`: 40 px, padding 4.
  medium,

  /// `.ms-avatar--lg`: 72 px, padding 4.
  large,
}

/// Volto 8×8 deterministico ricavato da un nome.
@immutable
class MsAvatarFace {
  const MsAvatarFace._(this.cells, this.primary, this.secondary);

  /// Volto per [name] (maiuscole e spazi ai bordi non contano).
  factory MsAvatarFace.of(String name) {
    final h = _fnv1a(name.trim().toLowerCase());
    final primary = h % 8;
    var secondary = (h >> 3) % 7;
    if (secondary >= primary) secondary++;
    // Bit del volto: 6 righe × 4 colonne (metà sinistra, poi specchiata),
    // bocca/collo: 2 righe × 3 colonne interne.
    var bits = _mix(h);
    final cells = List<int>.filled(64, 0);
    for (var y = 0; y < 6; y++) {
      for (var x = 0; x < 4; x++) {
        // la fronte (riga 0) è quasi sempre piena, come nei volti del canvas
        final on = y == 0 ? (bits & 3) != 0 : (bits & 1) == 1;
        bits = y == 0 ? bits >> 2 : bits >> 1;
        if (on) cells[y * 8 + x] = cells[y * 8 + 7 - x] = 1;
      }
    }
    var low = _mix(h ^ 0x9e3779b9);
    for (var y = 6; y < 8; y++) {
      for (var x = 1; x < 4; x++) {
        final on = (low & 1) == 1;
        low >>= 1;
        if (on) cells[y * 8 + x] = cells[y * 8 + 7 - x] = 2;
      }
    }
    // guance accanto agli occhi sempre piene, così gli occhi si leggono
    for (final i in const [2 * 8 + 1, 2 * 8 + 3, 2 * 8 + 4, 2 * 8 + 6]) {
      cells[i] = 1;
    }
    // occhi fissi: colonne 2 e 5, righe 2 e 3
    for (final i in const [2 * 8 + 2, 3 * 8 + 2, 2 * 8 + 5, 3 * 8 + 5]) {
      cells[i] = 3;
    }
    return MsAvatarFace._(List.unmodifiable(cells), primary, secondary);
  }

  /// 0 vuoto, 1 colore principale, 2 colore secondario, 3 occhi; riga per
  /// riga dall'alto.
  final List<int> cells;

  /// Indici (0…7) nella tavolozza --ms-av-1…8.
  final int primary;
  final int secondary;

  /// Colore degli occhi (fisso in tutti gli schemi, come nel canvas).
  static const eyeColor = Color(0xFF14100A);

  static int _fnv1a(String s) {
    var h = 0x811c9dc5;
    for (final u in s.codeUnits) {
      h ^= u;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h;
  }

  static int _mix(int x) {
    x = ((x ^ (x >> 16)) * 0x45d9f3b) & 0xffffffff;
    x = ((x ^ (x >> 16)) * 0x45d9f3b) & 0xffffffff;
    return x ^ (x >> 16);
  }
}

/// Colore --ms-av-[i+1] dello schema.
Color msAvatarColor(MsColors c, int i) =>
    [c.av1, c.av2, c.av3, c.av4, c.av5, c.av6, c.av7, c.av8][i % 8];

(double, double) _geometry(MsAvatarSize s) => switch (s) {
  MsAvatarSize.small => (28, 2),
  MsAvatarSize.medium => (40, 4),
  MsAvatarSize.large => (72, 4),
};

/// Avatar generato dal nome del giocatore, in uno slot incassato con
/// contorno. Le celle del volto sono intere di pixel fisici e centrate.
class MsAvatar extends StatelessWidget {
  const MsAvatar(this.name, {super.key, this.size = MsAvatarSize.medium, this.semanticLabel});

  final String name;
  final MsAvatarSize size;

  /// Etichetta per le tecnologie assistive (es. "Avatar di alice");
  /// senza, l'avatar è decorativo.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final face = MsAvatarFace.of(name);
    final (side, pad) = _geometry(size);
    final box = PixelBox(
      width: side + 4,
      height: side + 4,
      repaintKey: (name, size, c),
      painter: (p0, w, h) {
        final g = p0.g;
        final p = p0.shiftPhys(g.unitPx, g.unitPx); // margine di 2 per il contorno
        p.ring(0, 0, side, side, c.pxOutline);
        p.rect(0, 0, side, side, c.inset);
        p.bevel(side, side, c.pxLight, c.pxShadow, inverted: true);
        final innerPhys = ((side - 2 * pad) / 2 * g.unitPx).round();
        final cell = innerPhys ~/ 8;
        final off = (pad / 2 * g.unitPx).round() + (innerPhys - 8 * cell) ~/ 2;
        final colors = [
          null,
          msAvatarColor(c, face.primary),
          msAvatarColor(c, face.secondary),
          MsAvatarFace.eyeColor,
        ];
        for (var y = 0; y < 8; y++) {
          for (var x = 0; x < 8; x++) {
            final col = colors[face.cells[y * 8 + x]];
            if (col != null) p.rectPhys(off + x * cell, off + y * cell, cell, cell, col);
          }
        }
      },
    );
    if (semanticLabel == null) return ExcludeSemantics(child: box);
    return Semantics(image: true, label: semanticLabel, child: box);
  }
}

/// Pila di avatar sovrapposti (`.ms-avatar-stack`): i contorni adiacenti si
/// fondono in uno solo.
class MsAvatarStack extends StatelessWidget {
  const MsAvatarStack({
    super.key,
    required this.names,
    this.size = MsAvatarSize.small,
    this.semanticLabel,
  });

  final List<String> names;
  final MsAvatarSize size;

  /// Etichetta dell'insieme (es. "3 online: alice, bob, carol").
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    final (side, _) = _geometry(size);
    final n = names.length;
    final stack = SizedBox(
      width: n == 0 ? 0 : g.d(n * side + 4),
      height: g.d(side + 4),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < n; i++)
            Positioned(
              left: g.d(i * side),
              top: 0,
              child: MsAvatar(names[i], size: size),
            ),
        ],
      ),
    );
    return Semantics(label: semanticLabel, container: semanticLabel != null, child: stack);
  }
}
