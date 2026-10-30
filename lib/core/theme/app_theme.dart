import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

// ─── Palette ────────────────────────────────────────────────────────────────
/// Every colour that changes between light and dark mode.
///
/// Brand colours (`primary`, `secondary`, `accent`) and the vivid status/fill
/// colours deliberately live on [AppColors] as `static const` instead: they are
/// identical in both themes, so const call sites keep working and only the
/// theme-varying tokens below are resolved at build time.
@immutable
class AppPalette {
  const AppPalette({
    required this.brightness,
    required this.surface,
    required this.surfaceAlt,
    required this.surfaceDim,
    required this.divider,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.locked,
    required this.primaryText,
    required this.successText,
    required this.warningText,
    required this.errorText,
    required this.heroGradient,
    required this.cardGradient,
    required this.shadow,
    required this.overlayScrim,
  });

  final Brightness brightness;

  // Surfaces
  final Color surface;
  final Color surfaceAlt;
  final Color surfaceDim;
  final Color divider;

  // Text
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color locked;

  /// Brand red used as small text / link. The vivid [AppColors.primary] fill is
  /// ~4.0:1 on white, below the 4.5:1 target for small glyphs.
  final Color primaryText;

  /// Green used as a glyph or label. [AppColors.correct] is ~1.8:1 on white, so
  /// the vivid value stays reserved for fills, tints and glows.
  final Color successText;

  /// Amber used as a glyph or label.
  final Color warningText;

  /// Red used as a glyph or label.
  final Color errorText;

  // Backdrops
  final List<Color> heroGradient;
  final List<Color> cardGradient;

  /// Card / tray drop shadow.
  final Color shadow;

  /// Barrier behind sheets and dialogs.
  final Color overlayScrim;
}

const AppPalette kDarkPalette = AppPalette(
  brightness: Brightness.dark,
  surface: Color(0xFF1E1E2E),
  surfaceAlt: Color(0xFF252535),
  surfaceDim: Color(0xFF16161F),
  divider: Color(0xFF2E2E42),
  textPrimary: Color(0xFFF8F8FF),
  textSecondary: Color(0xFFB0B0CC),
  textMuted: Color(0xFF6B6B8A),
  locked: Color(0xFF6B6B8A),
  primaryText: Color(0xFFE63946),
  successText: Color(0xFF38EF7D),
  warningText: Color(0xFFF4A261),
  errorText: Color(0xFFE63946),
  heroGradient: [
    Color(0xFF1D1D2C),
    Color(0xFF2D1B3D),
    Color(0xFF1A0A2E),
  ],
  cardGradient: [
    Color(0xFF1E1E2E),
    Color(0xFF252540),
  ],
  shadow: Color(0x2E000000),
  overlayScrim: Color(0x99000000),
);

/// Light mode is a warm off-white canvas with white cards — not an inverted
/// dark theme — so brand gradients read as a soft wash rather than a void.
const AppPalette kLightPalette = AppPalette(
  brightness: Brightness.light,
  surface: Color(0xFFFFFFFF),
  surfaceAlt: Color(0xFFF1EFF6),
  surfaceDim: Color(0xFFF6F5F8),
  divider: Color(0xFFE4E1EC),
  textPrimary: Color(0xFF191923),
  textSecondary: Color(0xFF55556B),
  textMuted: Color(0xFF74748A),
  locked: Color(0xFF8A8AA0),
  primaryText: Color(0xFFC21F30),
  successText: Color(0xFF0B7A45),
  warningText: Color(0xFFB45309),
  errorText: Color(0xFFC1121F),
  heroGradient: [
    Color(0xFFFDF4F5),
    Color(0xFFF6F1FB),
    Color(0xFFFFF8F2),
  ],
  cardGradient: [
    Color(0xFFFFFFFF),
    Color(0xFFFAF8FD),
  ],
  shadow: Color(0x14000000),
  overlayScrim: Color(0x66000000),
);

// ─── Design Tokens ───────────────────────────────────────────────────────────
class AppColors {
  AppColors._();

  static AppPalette _palette = kDarkPalette;

  /// The palette currently in force. Assigned by [use] from the app root
  /// (`AnimeQuizApp.build`) and from [ThemeProvider] when the mode changes.
  static AppPalette get palette => _palette;
  static Brightness get brightness => _palette.brightness;
  static bool get isDark => _palette.brightness == Brightness.dark;

  /// Swaps the active palette. Call before anything rebuilds.
  static void use(Brightness brightness) {
    _palette = brightness == Brightness.light ? kLightPalette : kDarkPalette;
  }

  /// Restores dark — for tests that must not leak palette state between cases.
  static void reset() => _palette = kDarkPalette;

  /// Colours already reported as having no light-mode variant. Keeps a hot
  /// rebuild path (a list of rows, an animation) to one log line per colour
  /// instead of one per frame.
  static final Set<int> _unmappedLightColors = <int>{};

  /// Maps a vivid fill/brand colour to its legible on-surface variant.
  ///
  /// Use this wherever a colour that is fine as a fill is also used as a glyph
  /// or label (e.g. `AppColors.correct` as text). Identity in dark mode, darker
  /// in light mode, so call sites that pass a status colour through a parameter
  /// stay readable without threading a second argument everywhere.
  ///
  /// In debug light mode, a colour with no mapping is logged once so new call
  /// sites surface during QA instead of silently shipping a vivid glyph.
  static Color readable(Color color) {
    if (isDark) return color;
    if (color == correct || color == win) return successText;
    if (color == wrong || color == lose || color == crimsonBright) {
      return errorText;
    }
    if (color == primary) return primaryText;
    if (color == skyBright) return secondary;
    if (color == silver) return textMuted;
    if (color == amber ||
        color == accent ||
        color == gold ||
        color == coinGold ||
        color == draw ||
        color == bronze ||
        color == rival) {
      return warningText;
    }
    assert(() {
      if (_unmappedLightColors.add(color.toARGB32())) {
        debugPrint(
          '[AppColors.readable] no light-mode variant for '
          '0x${color.toARGB32().toRadixString(16).padLeft(8, '0')} — '
          'left unchanged',
        );
      }
      return true;
    }());
    return color;
  }

  // Brand — identical in both themes, so these stay `const`.
  static const primary = Color(0xFFE63946);
  static const secondary = Color(0xFF457B9D);
  static const accent = Color(0xFFF4A261);

  // Gradients (status — brand-locked)
  static const List<Color> winGradient = [Color(0xFF11998E), Color(0xFF38EF7D)];
  static const List<Color> loseGradient = [
    Color(0xFFEB3349),
    Color(0xFFF45C43)
  ];
  static const List<Color> drawGradient = [
    Color(0xFFF7971E),
    Color(0xFFFFD200)
  ];

  // Surface (adaptive)
  static Color get surface => _palette.surface;
  static Color get surfaceAlt => _palette.surfaceAlt;
  static Color get surfaceDim => _palette.surfaceDim;

  // Text (adaptive)
  static Color get textPrimary => _palette.textPrimary;
  static Color get textSecondary => _palette.textSecondary;
  static Color get textMuted => _palette.textMuted;

  // Status (fills stay vivid; `*Text` variants are for glyphs and labels)
  static const correct = Color(0xFF38EF7D);
  static const wrong = Color(0xFFE63946);
  static Color get locked => _palette.locked;
  static Color get divider => _palette.divider;
  static const amber = Color(0xFFF59E0B);

  static Color get primaryText => _palette.primaryText;
  static Color get successText => _palette.successText;
  static Color get warningText => _palette.warningText;
  static Color get errorText => _palette.errorText;

  // Backdrops (adaptive)
  static List<Color> get heroGradient => _palette.heroGradient;
  static List<Color> get cardGradient => _palette.cardGradient;
  static Color get shadow => _palette.shadow;
  static Color get overlayScrim => _palette.overlayScrim;

  /// Success snackbar surface: dark green in both themes so the white snackbar
  /// content stays legible — the vivid [correct] mint is a fill, not a surface
  /// for text.
  static const successSurface = Color(0xFF0E7A43);

  // Extended palette (brand-locked)
  static const crimsonBright = Color(0xFFFF6B7A);
  static const gold = Color(0xFFFFD700);
  static const silver = Color(0xFFD0D0D0);
  static const bronze = Color(0xFFCD7F32);
  static const rival = Color(0xFFFF6B00);
  static const win = Color(0xFF4ADE80);
  static const draw = Color(0xFFFBBF24);
  static const lose = Color(0xFFFB7185);
  static const coinGold = Color(
      0xFFFBBF24); // quiz_header coin accent (semantically separate from draw)
  static const skyBright = Color(0xFF70AEFF);

  // Stable alpha tints — pre-baked to replace withOpacity() on fixed colors
  static const primarySoft = Color(0x1AE63946); // primary @ ~10%
  static const primaryBorder = Color(0x59E63946); // primary @ ~35%
  static const secondarySoft = Color(0x1F457B9D); // secondary @ ~12%
  static const secondaryBorder = Color(0x59457B9D); // secondary @ ~35%

  // Semantic aliases
  static Color get onSurface => textPrimary;
  static Color get onSurfaceVariant => textSecondary;
  static Color get onPrimary => Colors.white;
  static Color get onSecondary => Colors.white;
  static Color get error => errorText;
  static Color get success => successText;
  static Color get warning => warningText;
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
  static const double page =
      24.0; // canonical page gutter (semantic alias of xl)
  static const double rhythm =
      48.0; // large section-breath gaps (coin/premium pages)
}

// ─── Typography Scale ──────────────────────────────────────────────────────
/// Getters, not `static final`: a cached style would keep the palette that was
/// active at first access. `TextStyle` has value equality, so Flutter's text
/// layout cache still hits even though a new instance is built per read.
class AppTypography {
  AppTypography._();

  static const String fontFamily = 'Nunito';

  static TextStyle get heading1 => TextStyle(
        fontFamily: fontFamily,
        fontSize: 32.sp,
        fontWeight: FontWeight.w900,
        height: 1.1,
        letterSpacing: -0.5,
        color: AppColors.textPrimary,
      );

  static TextStyle get heading2 => TextStyle(
        fontFamily: fontFamily,
        fontSize: 24.sp,
        fontWeight: FontWeight.w900,
        height: 1.2,
        letterSpacing: -0.3,
        color: AppColors.textPrimary,
      );

  static TextStyle get heading3 => TextStyle(
        fontFamily: fontFamily,
        fontSize: 20.sp,
        fontWeight: FontWeight.w800,
        height: 1.3,
        letterSpacing: -0.2,
        color: AppColors.textPrimary,
      );

  static TextStyle get titleLarge => TextStyle(
        fontFamily: fontFamily,
        fontSize: 18.sp,
        fontWeight: FontWeight.w800,
        height: 1.3,
        letterSpacing: -0.2,
        color: AppColors.textPrimary,
      );

  static TextStyle get titleMedium => TextStyle(
        fontFamily: fontFamily,
        fontSize: 16.sp,
        fontWeight: FontWeight.w700,
        height: 1.4,
        color: AppColors.textPrimary,
      );

  static TextStyle get bodyLarge => TextStyle(
        fontFamily: fontFamily,
        fontSize: 15.sp,
        fontWeight: FontWeight.w600,
        height: 1.5,
        color: AppColors.textPrimary,
      );

  static TextStyle get bodyMedium => TextStyle(
        fontFamily: fontFamily,
        fontSize: 13.sp,
        fontWeight: FontWeight.w600,
        height: 1.5,
        color: AppColors.textSecondary,
      );

  static TextStyle get bodySmall => TextStyle(
        fontFamily: fontFamily,
        fontSize: 12.sp,
        fontWeight: FontWeight.w600,
        height: 1.5,
        color: AppColors.textMuted,
      );

  static TextStyle get labelLarge => TextStyle(
        fontFamily: fontFamily,
        fontSize: 14.sp,
        fontWeight: FontWeight.w700,
        height: 1.2,
        color: AppColors.textPrimary,
      );

  static TextStyle get labelMedium => TextStyle(
        fontFamily: fontFamily,
        fontSize: 11.sp,
        fontWeight: FontWeight.w700,
        height: 1.2,
        color: AppColors.textSecondary,
      );

  static TextStyle get labelSmall => TextStyle(
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

  static ThemeData get dark => _build(Brightness.dark);
  static ThemeData get light => _build(Brightness.light);

  static ThemeData forBrightness(Brightness brightness) =>
      brightness == Brightness.light ? light : dark;

  /// One builder for both themes so the component themes cannot drift apart.
  /// Deliberately side-effect free: the active palette is assigned by the app
  /// root via [AppColors.use], which keeps widget tests independent.
  static ThemeData _build(Brightness brightness) {
    final palette =
        brightness == Brightness.light ? kLightPalette : kDarkPalette;

    final scheme = brightness == Brightness.light
        ? ColorScheme.light(
            primary: AppColors.primary,
            onPrimary: Colors.white,
            secondary: AppColors.secondary,
            onSecondary: Colors.white,
            surface: palette.surface,
            onSurface: palette.textPrimary,
            onSurfaceVariant: palette.textSecondary,
            error: palette.errorText,
            onError: Colors.white,
          )
        : ColorScheme.dark(
            primary: AppColors.primary,
            onPrimary: Colors.white,
            secondary: AppColors.secondary,
            onSecondary: Colors.white,
            surface: palette.surface,
            onSurface: palette.textPrimary,
            onSurfaceVariant: palette.textSecondary,
            error: palette.errorText,
            onError: Colors.white,
          );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: palette.surfaceDim,
      canvasColor: palette.surfaceDim,
      fontFamily: AppTypography.fontFamily,
      iconTheme: IconThemeData(color: palette.textPrimary),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: AppTypography.heading2,
        iconTheme: IconThemeData(color: palette.textPrimary),
      ),
      dividerTheme: DividerThemeData(
        color: palette.divider,
        thickness: 1,
        space: 1,
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
        fillColor: palette.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          borderSide: BorderSide(color: palette.divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          borderSide: BorderSide(color: palette.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          borderSide: const BorderSide(color: AppColors.primary, width: 2),
        ),
        labelStyle:
            AppTypography.bodyMedium.copyWith(color: palette.textSecondary),
        hintStyle: AppTypography.bodySmall,
      ),
      cardTheme: CardThemeData(
        color: palette.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.xl),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        // Inverse surface, like Material 3: snackbars stay a dark bar in both
        // themes, so the many `backgroundColor: AppColors.wrong` error
        // snackbars keep legible white content instead of inheriting
        // textPrimary (near-black) from the light palette.
        backgroundColor: const Color(0xFF2A2A38),
        contentTextStyle:
            AppTypography.bodyMedium.copyWith(color: Colors.white),
        actionTextColor: Colors.white,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.primary,
      ),
    );
  }
}

// ─── Shared Decorations ────────────────────────────────────────────────────
class AppDecorations {
  AppDecorations._();

  static BoxDecoration get heroBg => BoxDecoration(
        gradient: LinearGradient(
          colors: AppColors.heroGradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      );

  static BoxDecoration get card => BoxDecoration(
        gradient: LinearGradient(
          colors: AppColors.cardGradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(AppRadii.xl),
        border: Border.all(color: AppColors.divider, width: 1),
      );

  static BoxDecoration glowCard({required Color glowColor}) => BoxDecoration(
        gradient: LinearGradient(
          colors: AppColors.cardGradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(AppRadii.xl),
        border: Border.all(color: glowColor.withValues(alpha: 0.5), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: glowColor.withValues(alpha: AppColors.isDark ? 0.25 : 0.14),
            blurRadius: 20,
            spreadRadius: 0,
          ),
        ],
      );
}
