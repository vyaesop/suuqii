import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Theme tuned for cheap Android phones and one-handed cashier use:
/// large touch targets, comfortable density, M3 throughout.
class AppTheme {
  static ThemeData light() => _base(brightness: Brightness.light, seed: const Color(0xFF1F6F4A));
  static ThemeData dark() => _base(brightness: Brightness.dark, seed: const Color(0xFF1F6F4A));

  static ThemeData _base({required Brightness brightness, required Color seed}) {
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    final baseText = brightness == Brightness.dark
        ? GoogleFonts.notoSansTextTheme(ThemeData(brightness: Brightness.dark).textTheme)
        : GoogleFonts.notoSansTextTheme();
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      visualDensity: VisualDensity.comfortable,
      textTheme: baseText,
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size.fromHeight(56),
          textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(56),
          textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 72,
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
