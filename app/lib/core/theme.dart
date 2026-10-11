import 'package:flutter/material.dart';

/// Kassir uchun qulay mavzu: katta tugmalar, aniq kontrast, yorug'/qorong'u rejim.
class AppTheme {
  AppTheme._();

  static const seed = Color(0xFF0F766E); // Teal — tinch va professional

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness b) {
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: b);
    final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: b);
    return base.copyWith(
      visualDensity: VisualDensity.standard,
      scaffoldBackgroundColor: b == Brightness.light ? const Color(0xFFF4F6F8) : const Color(0xFF101415),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 52),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 52),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      chipTheme: base.chipTheme.copyWith(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
  }

  /// Ijobiy summalar (foyda, qaytim) uchun yashil.
  static Color success(BuildContext c) =>
      Theme.of(c).brightness == Brightness.light ? const Color(0xFF15803D) : const Color(0xFF4ADE80);

  static Color warning(BuildContext c) =>
      Theme.of(c).brightness == Brightness.light ? const Color(0xFFB45309) : const Color(0xFFFBBF24);
}
