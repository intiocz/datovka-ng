import 'package:flutter/material.dart';

/// Design tokens. One accent (official blue), deadline states carry the only
/// other colours, so colour on screen always means something.
class Tokens {
  final Color paper;
  final Color surface;
  final Color ink;
  final Color inkMuted;
  final Color line;
  final Color accent;
  final Color accentSoft;
  final Color warn;
  final Color danger;
  final Color ok;

  const Tokens({
    required this.paper,
    required this.surface,
    required this.ink,
    required this.inkMuted,
    required this.line,
    required this.accent,
    required this.accentSoft,
    required this.warn,
    required this.danger,
    required this.ok,
  });

  static const light = Tokens(
    paper: Color(0xFFF7F8FA),
    surface: Color(0xFFFFFFFF),
    ink: Color(0xFF17212B),
    inkMuted: Color(0xFF5B6673),
    line: Color(0xFFE3E7EC),
    accent: Color(0xFF2445A8),
    accentSoft: Color(0xFFE8EDFA),
    warn: Color(0xFFB86E00),
    danger: Color(0xFFB42318),
    ok: Color(0xFF1F7A4D),
  );

  static const dark = Tokens(
    paper: Color(0xFF12171D),
    surface: Color(0xFF1A2028),
    ink: Color(0xFFE6EAEF),
    inkMuted: Color(0xFF97A2AF),
    line: Color(0xFF2A323C),
    accent: Color(0xFF8AA6FF),
    accentSoft: Color(0xFF223055),
    warn: Color(0xFFF0A63A),
    danger: Color(0xFFFF7A6E),
    ok: Color(0xFF5CC593),
  );

  static Tokens of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

ThemeData buildTheme(Brightness brightness) {
  final t = brightness == Brightness.dark ? Tokens.dark : Tokens.light;
  final base = ThemeData(
    brightness: brightness,
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: t.accent,
      brightness: brightness,
      primary: t.accent,
      surface: t.surface,
      onSurface: t.ink,
      error: t.danger,
    ),
    scaffoldBackgroundColor: t.paper,
    dividerColor: t.line,
    splashFactory: NoSplash.splashFactory,
    fontFamily: 'PublicSans',
  );
  final text = base.textTheme.apply(bodyColor: t.ink, displayColor: t.ink);
  return base.copyWith(
    textTheme: text.copyWith(
      headlineSmall: text.headlineSmall?.copyWith(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        height: 1.25,
        letterSpacing: -0.2,
      ),
      titleMedium: text.titleMedium?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
      bodyMedium: text.bodyMedium?.copyWith(fontSize: 14, height: 1.45),
      bodySmall: text.bodySmall?.copyWith(fontSize: 12.5, color: t.inkMuted),
      labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: t.surface,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: t.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: t.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: t.accent, width: 1.5),
      ),
    ),
  );
}

const tabular = [FontFeature.tabularFigures()];
