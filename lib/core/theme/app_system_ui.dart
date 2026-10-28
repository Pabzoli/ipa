import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';

/// Applies the status-bar and Android navigation-bar styling for [brightness].
///
/// Called from `main()` before `runApp` — so the splash frame is already
/// correct even though no provider exists yet — and again on every appearance
/// change (see `ThemeProvider`).
///
/// On Android the icon colour is [SystemUiOverlayStyle.statusBarIconBrightness];
/// on iOS it is the inverted [SystemUiOverlayStyle.statusBarBrightness], which
/// describes the *background* the system is drawing against.
void applySystemUiOverlay(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final palette = isDark ? kDarkPalette : kLightPalette;

  SystemChrome.setSystemUIOverlayStyle(
    SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: palette.surfaceDim,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness:
          isDark ? Brightness.light : Brightness.dark,
    ),
  );
}
