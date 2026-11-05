import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';

/// Applies the status-bar and navigation-bar styling for [brightness].
///
/// Web builds return immediately: the browser owns its chrome (covered by
/// the `theme-color` meta tag in `web/index.html`), and the MethodChannel
/// call is a no-op there.
///
/// Called from `ThemeProvider` on load and on every appearance change.
void applySystemUiOverlay(Brightness brightness) {
  if (kIsWeb) return;
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
