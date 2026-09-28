import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

// ─── Design Tokens ───────────────────────────────────────────────────────────
class AppColors {
  AppColors._();

  // Brand
  static const primary    = Color(0xFFE63946);
  static const secondary  = Color(0xFF457B9D);
  static const accent     = Color(0xFFF4A261);

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

  // Status
  static const correct = Color(0xFF38EF7D);
  static const wrong   = Color(0xFFE63946);
  static const locked  = Color(0xFF6B6B8A);
  static const divider = Color(0xFF2E2E42);
  static const amber   = Color(0xFFF59E0B);

  // Extended palette (Phase 2 additions — absorb app-wide hardcoded values)
  static const crimsonBright = Color(0xFFFF6B7A);
  static const gold      = Color(0xFFFFD700);
  static const silver    = Color(0xFFD0D0D0);
  static const bronze    = Color(0xFFCD7F32);
  static const rival     = Color(0xFFFF6B00);
  static const win       = Color(0xFF4ADE80);
  static const draw      = Color(0xFFFBBF24);
  static const lose      = Color(0xFFFB7185);
  static const coinGold  = Color(0xFFFBBF24); // quiz_header coin accent (semantically separate from draw)
  static const skyBright = Color(0xFF70AEFF);

  // Stable alpha tints — pre-baked to replace withOpacity() on fixed colors
  static const primarySoft    = Color(0x1AE63946); // primary @ ~10%
  static const primaryBorder  = Color(0x59E63946); // primary @ ~35%
  static const secondarySoft  = Color(0x1F457B9D); // secondary @ ~12%
  static const secondaryBorder = Color(0x59457B9D); // secondary @ ~35%

  // Semantic aliases (dark‑only)
  static Color get onSurface => textPrimary;
  static Color get onSurfaceVariant => textSecondary;
  static Color get onPrimary => Colors.white;
  static Color get onSecondary => Colors.white;
  static Color get error => wrong;
  static Color get success => correct;
  static Color get warning => accent;
}

// ─── Spacing Scale ──────────────────────────────────────────────────────────
class AppSpacing {
  AppSpacing._();

  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 12.0;
  static const double lg = 16.0;
  static const double xl = 24.0;
  static const double xxl = 32.0;
  static const double page = 24.0; // canonical page gutter (semantic alias of xl)
  static const double rhythm = 48.0; // large section-breath gaps (coin/premium pages)
}

// ─── Typography Scale ──────────────────────────────────────────────────────
class AppTypography {
  AppTypography._();

  static const String fontFamily = 'Nunito';

  static final TextStyle heading1 = TextStyle(
    fontFamily: fontFamily,
    fontSize: 32.sp,
    fontWeight: FontWeight.w900,
    height: 1.1,
    letterSpacing: -0.5,
    color: AppColors.textPrimary,
  );

  static final TextStyle heading2 = TextStyle(
    fontFamily: fontFamily,
    fontSize: 24.sp,
    fontWeight: FontWeight.w900,
    height: 1.2,
    letterSpacing: -0.3,
    color: AppColors.textPrimary,
  );

  static final TextStyle heading3 = TextStyle(
    fontFamily: fontFamily,
    fontSize: 20.sp,
    fontWeight: FontWeight.w800,
    height: 1.3,
    letterSpacing: -0.2,
    color: AppColors.textPrimary,
  );

  static final TextStyle titleLarge = TextStyle(
    fontFamily: fontFamily,
    fontSize: 18.sp,
    fontWeight: FontWeight.w800,
    height: 1.3,
    letterSpacing: -0.2,
    color: AppColors.textPrimary,
  );

  static final TextStyle titleMedium = TextStyle(
    fontFamily: fontFamily,
    fontSize: 16.sp,
    fontWeight: FontWeight.w700,
    height: 1.4,
    color: AppColors.textPrimary,
  );

  static final TextStyle bodyLarge = TextStyle(
    fontFamily: fontFamily,
    fontSize: 15.sp,
    fontWeight: FontWeight.w600,
    height: 1.5,
    color: AppColors.textPrimary,
  );

  static final TextStyle bodyMedium = TextStyle(
    fontFamily: fontFamily,
    fontSize: 13.sp,
    fontWeight: FontWeight.w600,
    height: 1.5,
    color: AppColors.textSecondary,
  );

  static final TextStyle bodySmall = TextStyle(
    fontFamily: fontFamily,
    fontSize: 12.sp,
    fontWeight: FontWeight.w600,
    height: 1.5,
    color: AppColors.textMuted,
  );

  static final TextStyle labelLarge = TextStyle(
    fontFamily: fontFamily,
    fontSize: 14.sp,
    fontWeight: FontWeight.w700,
    height: 1.2,
    color: AppColors.textPrimary,
  );

  static final TextStyle labelMedium = TextStyle(
    fontFamily: fontFamily,
    fontSize: 11.sp,
    fontWeight: FontWeight.w700,
    height: 1.2,
    color: AppColors.textSecondary,
  );

  static final TextStyle labelSmall = TextStyle(
    fontFamily: fontFamily,
    fontSize: 9.sp,
    fontWeight: FontWeight.w800,
    height: 1.2,
    letterSpacing: 0.5,
    color: AppColors.textMuted,
  );
}

// ─── Corner Radii ──────────────────────────────────────────────────────────
class AppRadii {
  AppRadii._();

  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 12.0;
  static const double lg = 16.0;
  static const double xl = 20.0;
  static const double full = 99.0;
  static const double feature = 28.0; // large feature surfaces (question card)
}

// ─── Theme ──────────────────────────────────────────────────────────────────
class AppTheme {
  AppTheme._();

  static ThemeData get dark => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.primary,
          secondary: AppColors.secondary,
          surface: AppColors.surface,
          onSurface: AppColors.textPrimary,
          onSurfaceVariant: AppColors.textSecondary,
          error: AppColors.wrong,
          onError: Colors.white,
        ),
        scaffoldBackgroundColor: AppColors.surfaceDim,
        fontFamily: AppTypography.fontFamily,

        appBarTheme: AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
          titleTextStyle: AppTypography.heading2,
          iconTheme: IconThemeData(color: AppColors.textPrimary),
        ),

        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.lg),
            ),
            textStyle: AppTypography.labelLarge,
            padding: const EdgeInsets.symmetric(
              vertical: AppSpacing.md,
              horizontal: AppSpacing.xl,
            ),
          ),
        ),

        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: AppColors.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadii.lg),
            borderSide: const BorderSide(color: AppColors.divider),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadii.lg),
            borderSide: const BorderSide(color: AppColors.divider),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadii.lg),
            borderSide: const BorderSide(color: AppColors.primary, width: 2),
          ),
          labelStyle: AppTypography.bodyMedium.copyWith(color: AppColors.textSecondary),
          hintStyle: AppTypography.bodySmall,
        ),

        cardTheme: CardThemeData(
          color: AppColors.surface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.xl),
          ),
        ),

        snackBarTheme: SnackBarThemeData(
          backgroundColor: AppColors.surfaceAlt,
          contentTextStyle: AppTypography.bodyMedium.copyWith(color: AppColors.textPrimary),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.md),
          ),
        ),
      );
}

// ─── Shared Decorations ────────────────────────────────────────────────────
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
        borderRadius: BorderRadius.circular(AppRadii.xl),
        border: Border.all(color: AppColors.divider, width: 1),
      );

  static BoxDecoration glowCard({required Color glowColor}) => BoxDecoration(
        gradient: const LinearGradient(
          colors: AppColors.cardGradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(AppRadii.xl),
        border: Border.all(color: glowColor.withValues(alpha: 0.5), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: glowColor.withValues(alpha: 0.25),
            blurRadius: 20,
            spreadRadius: 0,
          ),
        ],
      );
}