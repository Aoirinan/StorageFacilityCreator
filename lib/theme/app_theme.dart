import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Apply a fallback font so missing glyphs (e.g. symbols) don't trigger Noto font warnings.
TextTheme _textThemeWithFallback(TextTheme theme) {
  const fallback = ['Arial', 'sans-serif'];
  return TextTheme(
    displayLarge: theme.displayLarge?.copyWith(fontFamilyFallback: fallback),
    displayMedium: theme.displayMedium?.copyWith(fontFamilyFallback: fallback),
    displaySmall: theme.displaySmall?.copyWith(fontFamilyFallback: fallback),
    headlineLarge: theme.headlineLarge?.copyWith(fontFamilyFallback: fallback),
    headlineMedium: theme.headlineMedium?.copyWith(fontFamilyFallback: fallback),
    headlineSmall: theme.headlineSmall?.copyWith(fontFamilyFallback: fallback),
    titleLarge: theme.titleLarge?.copyWith(fontFamilyFallback: fallback),
    titleMedium: theme.titleMedium?.copyWith(fontFamilyFallback: fallback),
    titleSmall: theme.titleSmall?.copyWith(fontFamilyFallback: fallback),
    bodyLarge: theme.bodyLarge?.copyWith(fontFamilyFallback: fallback),
    bodyMedium: theme.bodyMedium?.copyWith(fontFamilyFallback: fallback),
    bodySmall: theme.bodySmall?.copyWith(fontFamilyFallback: fallback),
    labelLarge: theme.labelLarge?.copyWith(fontFamilyFallback: fallback),
    labelMedium: theme.labelMedium?.copyWith(fontFamilyFallback: fallback),
    labelSmall: theme.labelSmall?.copyWith(fontFamilyFallback: fallback),
  );
}

/// Professional SaaS dashboard theme for facility operations
class AppTheme {
  // Primary brand blue palette
  static const Color primaryBlue = Color(0xFF1E3A8A); // Primary brand blue
  static const Color primaryBlueLight = Color(0xFF3B82F6); // Lighter blue
  static const Color primaryBlueDark = Color(0xFF1E40AF); // Darker blue
  static const Color accentBlueLight = Color(0xFF60A5FA); // Accent blue light
  static const Color accentYellow = Color(0xFFFFC107); // Accent yellow
  static const Color accentOrange = Color(0xFFFF9800);
  
  // Neutral colors
  static const Color backgroundLight = Color(0xFFF8FAFC);
  static const Color backgroundSecondary = Color(0xFFF1F5F9); // Secondary background
  static const Color backgroundDark = Color(0xFF0F172A);
  static const Color surface = Colors.white;
  static const Color surfaceDark = Color(0xFF1E293B);
  
  // Status colors
  static const Color success = Color(0xFF10B981);
  static const Color warning = Color(0xFFF59E0B);
  static const Color error = Color(0xFFEF4444);
  static const Color info = Color(0xFF3B82F6);
  
  // Text colors
  static const Color textPrimary = Color(0xFF1F2937);
  static const Color textSecondary = Color(0xFF6B7280);
  static const Color textTertiary = Color(0xFF9CA3AF);
  static const Color textOnDark = Colors.white;
  
  // Border and divider colors
  static const Color borderLight = Color(0xFFE5E7EB);
  static const Color borderMedium = Color(0xFFD1D5DB);

  /// Text style for dropdown/popup menu items — improves mobile readability,
  /// prevents words from blurring together with proper line height and spacing.
  static const TextStyle dropdownItemTextStyle = TextStyle(
    fontSize: 16,
    height: 1.5,
    letterSpacing: 0.25,
    fontWeight: FontWeight.w500,
  );

  // Dark mode semantic tokens (readable contrast)
  static const Color darkSurface = Color(0xFF1E293B);
  static const Color darkBackground = Color(0xFF0F172A);
  static const Color darkTextPrimary = Color(0xFFF1F5F9);
  static const Color darkTextSecondary = Color(0xFF94A3B8);
  static const Color darkTextMuted = Color(0xFF64748B);
  static const Color darkBorder = Color(0xFF334155);
  static const Color darkScrollbarThumb = Color(0xFF64748B);
  static const Color darkScrollbarTrack = Color(0xFF1E293B);
  
  static ThemeData get lightTheme {
    const baseTextTheme = TextTheme(
      displayLarge: TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        color: textPrimary,
        letterSpacing: -1,
      ),
      displayMedium: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        color: textPrimary,
        letterSpacing: -0.5,
      ),
      displaySmall: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: textPrimary,
        letterSpacing: -0.5,
      ),
      headlineMedium: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: textPrimary,
        letterSpacing: -0.3,
      ),
      titleLarge: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: textPrimary,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: textPrimary,
      ),
      bodyLarge: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: textPrimary,
        letterSpacing: 0.15,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: textPrimary,
        letterSpacing: 0.1,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: textSecondary,
        letterSpacing: 0.1,
      ),
    );
    return ThemeData(
      useMaterial3: true,
      fontFamily: 'Noto Sans',
      colorScheme: ColorScheme.light(
        primary: primaryBlue,
        primaryContainer: primaryBlueLight,
        secondary: accentYellow,
        secondaryContainer: accentOrange,
        surface: surface,
        surfaceContainerHighest: backgroundSecondary,
        background: backgroundLight,
        outline: borderLight,
        error: error,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: textPrimary,
        onSurfaceVariant: textSecondary,
        onBackground: textPrimary,
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: backgroundLight,
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: borderLight, width: 1),
        ),
        color: surface,
      ),
      appBarTheme: const AppBarTheme(
        elevation: 0,
        centerTitle: false,
        backgroundColor: primaryBlue,
        foregroundColor: Colors.white,
        titleTextStyle: TextStyle(
          fontFamily: 'Noto Sans',
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.5,
        ),
      ),
      textTheme: _textThemeWithFallback(GoogleFonts.notoSansTextTheme(baseTextTheme)),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          backgroundColor: primaryBlue,
          foregroundColor: textOnDark,
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: borderLight),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: borderLight),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: primaryBlue, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: error),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: borderLight,
        selectedColor: primaryBlue,
        labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: borderLight,
        thickness: 1,
        space: 1,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbVisibility: WidgetStateProperty.resolveWith((_) => true),
        trackVisibility: WidgetStateProperty.resolveWith((_) => true),
        thickness: WidgetStateProperty.all(8),
        radius: const Radius.circular(4),
        thumbColor: WidgetStateProperty.all(borderMedium),
        trackColor: WidgetStateProperty.all(backgroundSecondary),
      ),
    );
  }

  static ThemeData get darkTheme {
    const darkTextTheme = TextTheme(
      displayLarge: TextStyle(fontSize: 32, fontWeight: FontWeight.w700, color: darkTextPrimary),
      displayMedium: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: darkTextPrimary),
      displaySmall: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: darkTextPrimary),
      headlineMedium: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: darkTextPrimary),
      titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: darkTextPrimary),
      titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: darkTextPrimary),
      bodyLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w400, color: darkTextPrimary),
      bodyMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: darkTextPrimary),
      bodySmall: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: darkTextSecondary),
      labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: darkTextPrimary),
      labelMedium: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: darkTextSecondary),
      labelSmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: darkTextSecondary),
    );
    return ThemeData(
      useMaterial3: true,
      fontFamily: 'Noto Sans',
      brightness: Brightness.dark,
      colorScheme: ColorScheme.dark(
        primary: primaryBlueLight,
        primaryContainer: primaryBlueDark,
        surface: darkSurface,
        onSurface: darkTextPrimary,
        onSurfaceVariant: darkTextSecondary,
        surfaceContainerHighest: const Color(0xFF334155),
        outline: darkBorder,
        background: darkBackground,
        onBackground: darkTextPrimary,
        error: error,
        onPrimary: Colors.white,
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: darkBackground,
      textTheme: _textThemeWithFallback(GoogleFonts.notoSansTextTheme(darkTextTheme)),
      appBarTheme: const AppBarTheme(
        elevation: 0,
        centerTitle: false,
        backgroundColor: primaryBlueDark,
        foregroundColor: Colors.white,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: darkBorder, width: 1),
        ),
        color: darkSurface,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: darkSurface,
        labelStyle: const TextStyle(color: darkTextSecondary),
        hintStyle: const TextStyle(color: darkTextMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: darkBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: darkBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: primaryBlueLight, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      dividerTheme: const DividerThemeData(
        color: darkBorder,
        thickness: 1,
        space: 1,
      ),
      dataTableTheme: DataTableThemeData(
        headingTextStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          color: darkTextPrimary,
          fontSize: 14,
        ),
        dataTextStyle: const TextStyle(
          color: darkTextPrimary,
          fontSize: 13,
        ),
        decoration: BoxDecoration(
          border: Border.all(color: darkBorder),
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbVisibility: WidgetStateProperty.resolveWith((_) => true),
        trackVisibility: WidgetStateProperty.resolveWith((_) => true),
        thickness: WidgetStateProperty.all(8),
        radius: const Radius.circular(4),
        thumbColor: WidgetStateProperty.all(darkScrollbarThumb),
        trackColor: WidgetStateProperty.all(darkScrollbarTrack),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: darkBorder,
        selectedColor: primaryBlueLight,
        labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: darkTextPrimary),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          backgroundColor: primaryBlueLight,
          foregroundColor: Colors.white,
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
  
  // Dashboard-specific colors for metrics
  static const Color metricPrimary = primaryBlue;
  static const Color metricSuccess = success;
  static const Color metricWarning = warning;
  static const Color metricError = error;
  static const Color metricInfo = info;
}

/// Extension for easy access to theme colors.
/// Prefer colorScheme (theme-aware) for surfaces, text, and borders so dark mode works.
extension ThemeExtensions on BuildContext {
  ThemeData get theme => Theme.of(this);
  ColorScheme get colorScheme => Theme.of(this).colorScheme;

  Color get primaryBlue => AppTheme.primaryBlue;
  Color get primaryBlueLight => AppTheme.primaryBlueLight;
  Color get accentYellow => AppTheme.accentYellow;
  Color get backgroundLight => AppTheme.backgroundLight;
  Color get textPrimary => AppTheme.textPrimary;
  Color get textSecondary => AppTheme.textSecondary;
}

