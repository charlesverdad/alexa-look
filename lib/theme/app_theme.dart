import 'package:flutter/material.dart';

/// A small, clean dark theme for Alexa Look.
class AppTheme {
  AppTheme._();

  static const Color background = Color(0xFF0E0E10);
  static const Color surface = Color(0xFF19191C);
  static const Color surfaceHigh = Color(0xFF232327);
  static const Color accent = Color(0xFFE7B76B); // warm film-print amber
  static const Color textPrimary = Color(0xFFF2F1EE);
  static const Color textSecondary = Color(0xFFA7A6A2);

  static ThemeData get dark {
    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      scaffoldBackgroundColor: background,
      colorScheme: const ColorScheme.dark(
        surface: background,
        primary: accent,
        secondary: accent,
        onPrimary: Colors.black,
        onSurface: textPrimary,
      ),
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        foregroundColor: textPrimary,
        elevation: 0,
        centerTitle: false,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          side: const BorderSide(color: surfaceHigh, width: 1.5),
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: accent,
        inactiveTrackColor: surfaceHigh,
        thumbColor: accent,
        overlayColor: accent.withValues(alpha: 0.2),
      ),
      cardTheme: const CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: accent,
      ),
    );
  }
}
