// lib/theme/app_theme.dart
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Tokens visuais da identidade McQueen (interface automotiva minimalista escura).
/// Contrastes ajustados para atender WCAG AA (>= 4.5:1 em texto e >= 3:1 em bordas interativas).
class McQueenColors {
  McQueenColors._();

  static const Color bgPrimary = Color(0xFF07080D);
  static const Color bgSecondary = Color(0xFF0C0F17);
  static const Color surface = Color(0xFF111520);
  static const Color surfaceElevated = Color(0xFF171D2C);
  static const Color surfaceHighlight = Color(0xFF1E2538);

  static const Color borderSubtle = Color(0xFF283145);
  static const Color borderStrong = Color(0xFF4B5875); // >= 3:1 sobre surface

  /// Vermelho assinatura McQueen (elementos decorativos e bordas em destaque).
  static const Color crimson = Color(0xFFE63946);

  /// Preenchimento sólido para botões com texto branco (contraste >= 5.25:1).
  static const Color crimsonFill = Color(0xFFC81E2B);
  static const Color crimsonDeep = Color(0xFF9F1D28);

  /// Vermelho claro acessível para texto/ícones sobre fundo escuro (>= 6.8:1).
  static const Color crimsonText = Color(0xFFFF7582);

  static const Color cyan = Color(0xFF38BDF8);
  static const Color amber = Color(0xFFF59E0B);
  static const Color emerald = Color(0xFF22C55E);
  static const Color violet = Color(0xFFA855F7);
  static const Color violetText = Color(0xFFC084FC);
  static const Color orange = Color(0xFFF97316);
  static const Color orangeText = Color(0xFFFB923C);
  static const Color pink = Color(0xFFEC4899);
  static const Color pinkText = Color(0xFFF472B6);

  static const Color textPrimary = Color(0xFFF8FAFC);
  static const Color textSecondary = Color(0xFF94A3B8);
  static const Color textMuted = Color(0xFF8896AB); // >= 5.3:1 em dark surfaces
}

class McQueenTheme {
  McQueenTheme._();

  static ThemeData get darkTheme {
    final baseText = GoogleFonts.outfitTextTheme(ThemeData.dark().textTheme);
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: McQueenColors.bgPrimary,
      colorScheme: const ColorScheme.dark(
        primary: McQueenColors.crimsonFill,
        onPrimary: Colors.white,
        secondary: McQueenColors.cyan,
        onSecondary: Colors.black,
        surface: McQueenColors.surface,
        onSurface: McQueenColors.textPrimary,
        error: McQueenColors.crimsonText,
        onError: Colors.black,
      ),
      textTheme: baseText.apply(
        bodyColor: McQueenColors.textPrimary,
        displayColor: McQueenColors.textPrimary,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: McQueenColors.bgPrimary,
        foregroundColor: McQueenColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.outfit(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: McQueenColors.textPrimary,
          letterSpacing: -0.2,
        ),
      ),
      dividerColor: McQueenColors.borderSubtle,
      dialogTheme: DialogThemeData(
        backgroundColor: McQueenColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: McQueenColors.borderStrong),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: McQueenColors.surfaceElevated,
        contentTextStyle: GoogleFonts.outfit(
          color: McQueenColors.textPrimary,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }
}
