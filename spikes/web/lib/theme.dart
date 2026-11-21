// Tema "prato scuro" ripreso dai token di ms.css del mockup.
import 'package:flutter/material.dart';

class Ms {
  static const bg = Color(0xFF17140F);
  static const bg2 = Color(0xFF1F1A13);
  static const panel = Color(0xFF2A2219);
  static const panelHi = Color(0xFF352B1F);
  static const inset = Color(0xFF110E0A);
  static const text = Color(0xFFF6EEDB);
  static const text2 = Color(0xFFCDBF9F);
  static const text3 = Color(0xFFAB9D82);
  static const pxLight = Color(0xFF54452F);
  static const pxShadow = Color(0xFF0B0906);
  static const accent = Color(0xFF62B53C);
  static const onAccent = Color(0xFF0C1806);
  static const warn = Color(0xFFF2B844);
  static const warnBg = Color(0xFF4A3A20);
  static const err = Color(0xFFFF7A63);
  static const info = Color(0xFF7CC0EF);
  static const focus = Color(0xFFFFE36B);
  static const ok = Color(0xFF7FCB55);

  static const pixel = 'PixelifySans';
  static const silk = 'Silkscreen';
  static const mono = 'JetBrainsMono';
}

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    surface: Ms.panel,
    onSurface: Ms.text,
    primary: Ms.accent,
    onPrimary: Ms.onAccent,
    secondary: Ms.info,
    error: Ms.err,
    outline: Ms.pxLight,
  );
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: Ms.pixel,
    scaffoldBackgroundColor: Ms.bg,
    focusColor: Ms.focus.withValues(alpha: 0.25),
    // Niente angoli arrotondati: stile pixel.
    cardTheme: const CardThemeData(
      color: Ms.panel,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Ms.pxShadow, width: 3),
      ),
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: Ms.inset,
      border: OutlineInputBorder(borderRadius: BorderRadius.zero),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: Ms.focus, width: 2),
      ),
      labelStyle: TextStyle(color: Ms.text2),
      helperStyle: TextStyle(color: Ms.text3),
    ),
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: Ms.text, displayColor: Ms.text),
  );
}

const silkTitle = TextStyle(
    fontFamily: Ms.silk, fontSize: 13, letterSpacing: 1, color: Ms.text2);
const monoSmall =
    TextStyle(fontFamily: Ms.mono, fontSize: 12.5, color: Ms.text2);
