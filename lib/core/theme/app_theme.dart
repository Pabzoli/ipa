import 'package:flutter/material.dart';

// ─── Design Tokens ───────────────────────────────────────────────────────────
class AppColors {
  AppColors._();

  // Brand
  static const primary    = Color(0xFFE63946);   // Vivid red
  static const secondary  = Color(0xFF457B9D);   // Steel blue
  static const accent     = Color(0xFFF4A261);   // Warm amber

  // Gradients
  static const List<Color> heroGradient = [
    Color(0xFF1D1D2C),
    Color(0xFF2D1B3D),
    Color(0xFF1A0A2E),
  ];

  static const List<Color> cardGradient = [
    Color(0xFF1E1E2E),
    Color(0xFF252540),
  ];

  static const List<Color> winGradient  = [Color(0xFF11998E), Color(0xFF38EF7D)];
  static const List<Color> loseGradient = [Color(0xFFEB3349), Color(0xFFF45C43)];
  static const List<Color> drawGradient = [Color(0xFFF7971E), Color(0xFFFFD200)];

  // Surface
  static const surface     = Color(0xFF1E1E2E);
  static const surfaceAlt  = Color(0xFF252535);
  static const surfaceDim  = Color(0xFF16161F);

  // Text
  static const textPrimary   = Color(0xFFF8F8FF);
  static const textSecondary = Color(0xFFB0B0CC);
  static const textMuted     = Color(0xFF6B6B8A);

  // Misc
  static const correct = Color(0xFF38EF7D);
  static const wrong   = Color(0xFFE63946);
  static const locked  = Color(0xFF6B6B8A);
  static const divider = Color(0xFF2E2E42);
}

class AppTheme {
  AppTheme._();

  static ThemeData get dark => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary:   AppColors.primary,
          secondary: AppColors.secondary,
          surface:   AppColors.surface,
        ),
        scaffoldBackgroundColor: AppColors.surfaceDim,
        fontFamily: 'Nunito',

        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            fontFamily: 'Nunito',
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
          iconTheme: IconThemeData(color: AppColors.textPrimary),
        ),

        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(16)),
            ),
            textStyle: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
            padding: EdgeInsets.symmetric(vertical: 16, horizontal: 24),
          ),
        ),

        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: AppColors.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
            borderSide: BorderSide(color: AppColors.divider),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
            borderSide: BorderSide(color: AppColors.divider),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
            borderSide: BorderSide(color: AppColors.primary, width: 2),
          ),
          labelStyle: TextStyle(color: AppColors.textSecondary),
          hintStyle:  TextStyle(color: AppColors.textMuted),
        ),

        cardTheme: CardThemeData(
          color: AppColors.surface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(20)),
          ),
        ),

        snackBarTheme: SnackBarThemeData(
          backgroundColor: AppColors.surfaceAlt,
          contentTextStyle: TextStyle(
            color: AppColors.textPrimary,
            fontFamily: 'Nunito',
          ),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
        ),
      );
}

// ─── Shared Decorations ───────────────────────────────────────────────────────
class AppDecorations {
  AppDecorations._();

  static BoxDecoration get heroBg => const BoxDecoration(
    gradient: LinearGradient(
      colors: AppColors.heroGradient,
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
  );

  static BoxDecoration get card => BoxDecoration(
    gradient: const LinearGradient(
      colors: AppColors.cardGradient,
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
    borderRadius: BorderRadius.circular(20),
    border: Border.all(color: AppColors.divider, width: 1),
  );

  static BoxDecoration glowCard({required Color glowColor}) => BoxDecoration(
    gradient: const LinearGradient(
      colors: AppColors.cardGradient,
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
    borderRadius: BorderRadius.circular(20),
    border: Border.all(color: glowColor.withOpacity(0.5), width: 1.5),
    boxShadow: [
      BoxShadow(
        color: glowColor.withOpacity(0.25),
        blurRadius: 20,
        spreadRadius: 0,
      ),
    ],
  );
}