import 'package:shared_preferences/shared_preferences.dart';

/// First-run tutorial persistence.
///
/// Single bool flag — the tutorial is shown once after sign-in and can be
/// replayed from Settings. Fail-open: a prefs error means "do not block",
/// so callers show the tutorial rather than strand a new user.
class TutorialService {
  TutorialService._();

  static const String _key = 'hasSeenTutorial_v1';

  static Future<bool> shouldShow() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return !(prefs.getBool(_key) ?? false);
    } catch (_) {
      return true;
    }
  }

  static Future<void> markSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, true);
    } catch (_) {
      // Best-effort only — tutorial must never crash the shell.
    }
  }
}
