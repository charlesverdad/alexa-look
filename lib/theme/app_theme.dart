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
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: _CinematicFadeTransitionsBuilder(),
          TargetPlatform.iOS: _CinematicFadeTransitionsBuilder(),
        },
      ),
    );
  }

  /// Pushes [page] with the app's smooth fade+scale transition, for screens
  /// built outside a route that already picks up [dark]'s
  /// `pageTransitionsTheme` (which only applies to [MaterialPageRoute]/
  /// [PageRoute]s using the platform default builder — this helper is handy
  /// for call sites that want the same feel explicitly).
  static Route<T> route<T>(Widget page) {
    return PageRouteBuilder<T>(
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween(begin: 0.98, end: 1.0).animate(curved),
            child: child,
          ),
        );
      },
    );
  }
}

/// A gentle, cinematic fade+scale page transition (no hard slide), used app-
/// wide so navigating between screens feels smooth and unobtrusive.
class _CinematicFadeTransitionsBuilder extends PageTransitionsBuilder {
  const _CinematicFadeTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween(begin: 0.98, end: 1.0).animate(curved),
        child: child,
      ),
    );
  }
}
