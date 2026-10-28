import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_system_ui.dart';
import '../theme/app_theme.dart';

/// Visibility flag for the Appearance control.
///
/// Visible in all builds by default. `--dart-define=THEME_CONTROL=false` hides
/// it.
const bool kThemeControlEnabled =
    bool.fromEnvironment('THEME_CONTROL', defaultValue: true);

/// Device-local appearance preference (System / Light / Dark).
///
/// Mirrors [SoloDifficultyProvider]: a [ChangeNotifier] over
/// `SharedPreferences`, registered in `main.dart`'s `MultiProvider`.
///
/// The provider owns the *palette* swap as well as the [ThemeMode]: it calls
/// [AppColors.use] before notifying, so the frame that paints the new
/// [ThemeData] already carries the new colours, and it schedules the full-tree
/// rebuild described in [_scheduleFullRebuild].
class ThemeProvider extends ChangeNotifier with WidgetsBindingObserver {
  /// Persisted key. Values are `system` / `light` / `dark`.
  static const String prefsKey = 'theme_mode';

  ThemeProvider({
    ThemeMode mode = ThemeMode.system,
    Brightness? platformBrightness,
  })  : _mode = mode,
        _platformBrightness = platformBrightness ??
            WidgetsBinding.instance.platformDispatcher.platformBrightness {
    WidgetsBinding.instance.addObserver(this);
  }

  /// Reads the stored mode and applies it before the first frame.
  ///
  /// Call this as the **first** `SharedPreferences` access in `main()`: the
  /// seed below uses "does any preference exist?" to distinguish an existing
  /// install from a fresh one.
  static Future<ThemeProvider> load() async {
    final provider = ThemeProvider(mode: await _readMode());
    provider._apply();
    return provider;
  }

  ThemeMode _mode;
  Brightness _platformBrightness;

  ThemeMode get mode => _mode;

  /// The brightness actually in force, with `ThemeMode.system` resolved against
  /// the platform. This is what the app root and the system chrome use.
  Brightness get resolvedBrightness => switch (_mode) {
        ThemeMode.light => Brightness.light,
        ThemeMode.dark => Brightness.dark,
        ThemeMode.system => _platformBrightness,
      };

  Future<void> setMode(ThemeMode next) async {
    if (next == _mode) return;
    _mode = next;

    // Order matters: palette and chrome first, then the root rebuild (which
    // reads the palette), then the full pass for everything that did not
    // rebuild. This avoids a one-frame flash of new chrome over old colours.
    _apply();
    notifyListeners();
    _scheduleFullRebuild();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, _encode(next));
    } catch (e) {
      // Best effort: the in-memory mode already drives the UI.
      debugPrint('[ThemeProvider] could not persist theme mode: $e');
    }
  }

  @override
  void didChangePlatformBrightness() {
    final next = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    if (next == _platformBrightness) return;
    _platformBrightness = next;
    // Only System mode follows the platform; an explicit choice is sticky.
    if (_mode != ThemeMode.system) return;
    _apply();
    notifyListeners();
    _scheduleFullRebuild();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _apply() {
    final brightness = resolvedBrightness;
    AppColors.use(brightness);
    applySystemUiOverlay(brightness);
  }

  /// Forces every element to rebuild.
  ///
  /// Most widgets read [AppColors] directly and never call `Theme.of(context)`,
  /// so a provider notify rebuilds `MaterialApp` and the `ThemeData` but leaves
  /// the mounted route content — including `const` screens — painted with the
  /// previous palette. Marking each element dirty rebuilds them all without
  /// tearing down the navigator, which a keyed root would do.
  ///
  /// Runs in a post-frame callback because `Element.markNeedsBuild` asserts
  /// when called during a build.
  void _scheduleFullRebuild() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final root = WidgetsBinding.instance.rootElement;
      if (root == null) return;

      void mark(Element element) {
        element.markNeedsBuild();
        element.visitChildren(mark);
      }

      mark(root);
    });
  }

  // ── Persistence ──────────────────────────────────────────────────────────

  static Future<ThemeMode> _readMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw != null) return _decode(raw);

      // First run of the appearance feature. Existing installs are seeded to
      // dark so nobody is flipped into light mode without opting in, and while
      // the control is still hidden (kThemeControlEnabled false) *everything*
      // seeds dark — a release build must not render light mode with no way to
      // switch back. Fresh debug installs start on System so it can be tested.
      final existingInstall = prefs.getKeys().isNotEmpty;
      final seeded = (existingInstall || !kThemeControlEnabled)
          ? ThemeMode.dark
          : ThemeMode.system;
      await prefs.setString(prefsKey, _encode(seeded));
      return seeded;
    } catch (e) {
      // Unreadable storage must never block startup.
      debugPrint('[ThemeProvider] could not read theme mode: $e');
      return ThemeMode.dark;
    }
  }

  static String _encode(ThemeMode mode) => switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      };

  static ThemeMode _decode(String raw) => switch (raw) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
}
