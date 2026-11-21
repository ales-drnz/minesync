// Colori di ms.css come interi ARGB (puro Dart: li usa anche lo script di
// analisi, che non ha dart:ui).

abstract final class MsHex {
  static const bg = 0xFF17140F;
  static const panel = 0xFF2A2219;
  static const panelHi = 0xFF352B1F;
  static const inset = 0xFF110E0A;
  static const overlay = 0xFF3A2F22;
  static const text = 0xFFF6EEDB;
  static const text2 = 0xFFCDBF9F;
  static const pxLight = 0xFF54452F;
  static const pxShadow = 0xFF0B0906;
  static const pxOutline = 0xFF050403;
  static const accent = 0xFF62B53C;
  static const accentHi = 0xFF8FD862;
  static const accentLo = 0xFF2F6A1B;
  static const accentHover = 0xFF8FD862;
  static const onAccent = 0xFF0C1806;
  static const ok = 0xFF7FCB55;
  static const warn = 0xFFF2B844;
  static const err = 0xFFFF7A63;
  static const info = 0xFF7CC0EF;
  static const focus = 0xFFFFE36B;
  static const conBg = 0xFF100D09;
  static const conText = 0xFFECE3CF;
  static const conDim = 0xFFA3967C;
  static const conInfo = 0xFF9FD3F5;
  static const conWarn = 0xFFF5C35A;
  static const conErr = 0xFFFF8A73;
  static const conJoin = 0xFF8CC2FF;
  static const conOk = 0xFF8BD462;
  static const conCmd = 0xFFF6EEDB;
  static const conWarnBg = 0xFF271F11;
  static const conErrBg = 0xFF2D1C16;

  /// Ombra --ms-drop rgba(0,0,0,.45) composta su --ms-bg.
  static final drop = blendHex(0xFF000000, bg, .45);
}

/// Composizione "source over" di [fg] con opacità [a] su [bg], 8 bit per canale.
int blendHex(int fg, int bg, double a) {
  int ch(int s) => ((((fg >> s) & 0xFF) * a + ((bg >> s) & 0xFF) * (1 - a))).round();
  return 0xFF000000 | (ch(16) << 16) | (ch(8) << 8) | ch(0);
}
