// Token di ms.css, palette "prato" tema scuro (solo quelli usati dallo spike).
import 'dart:ui';

import 'palette_hex.dart';

abstract final class Ms {
  static const bg = Color(MsHex.bg);
  static const panel = Color(MsHex.panel);
  static const panelHi = Color(MsHex.panelHi);
  static const inset = Color(MsHex.inset);
  static const overlay = Color(MsHex.overlay);
  static const text = Color(MsHex.text);
  static const text2 = Color(MsHex.text2);
  static const pxLight = Color(MsHex.pxLight);
  static const pxShadow = Color(MsHex.pxShadow);
  static const pxOutline = Color(MsHex.pxOutline);
  static const accent = Color(MsHex.accent);
  static const accentHi = Color(MsHex.accentHi);
  static const accentLo = Color(MsHex.accentLo);
  static const accentHover = Color(MsHex.accentHover);
  static const onAccent = Color(MsHex.onAccent);
  static const ok = Color(MsHex.ok);
  static const warn = Color(MsHex.warn);
  static const err = Color(MsHex.err);
  static const info = Color(MsHex.info);
  static const focus = Color(MsHex.focus);

  // console
  static const conBg = Color(MsHex.conBg);
  static const conText = Color(MsHex.conText);
  static const conDim = Color(MsHex.conDim);
  static const conInfo = Color(MsHex.conInfo);
  static const conWarn = Color(MsHex.conWarn);
  static const conErr = Color(MsHex.conErr);
  static const conJoin = Color(MsHex.conJoin);
  static const conOk = Color(MsHex.conOk);
  static const conCmd = Color(MsHex.conCmd);
  static const conWarnBg = Color(MsHex.conWarnBg);
  static const conErrBg = Color(MsHex.conErrBg);

  /// Ombra --ms-drop già composta su --ms-bg (colore pieno).
  static final drop = Color(MsHex.drop);

  /// Composizione "source over" di [fg] con opacità [a] su [bg] (8 bit),
  /// stessa formula dello script di analisi.
  static Color blend(Color fg, Color bg, double a) =>
      Color(blendHex(fg.toARGB32(), bg.toARGB32(), a));
}
