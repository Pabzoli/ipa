// Shared homepage solo difficulty (single source of truth).
//
// The difficulty picker used to live on the homepage itself. It now lives in
// Profile → Settings, while the homepage (a different tab in the same
// IndexedStack) only consumes the value. A ChangeNotifier backed by
// SharedPreferences keeps both tabs in sync without manual refreshes.
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/solo_economy.dart';

class SoloDifficultyProvider extends ChangeNotifier {
  static const String prefsKey = 'solo_difficulty';

  String _difficulty = 'easy';
  bool _loaded = false;

  String get difficulty => _difficulty;
  bool get loaded => _loaded;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _difficulty =
          normalizeSoloDifficulty(prefs.getString(prefsKey));
    } catch (_) {
      _difficulty = 'easy';
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setDifficulty(String raw) async {
    final next = normalizeSoloDifficulty(raw);
    if (next == _difficulty) return;
    _difficulty = next;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, next);
    } catch (_) {
      // Best-effort persistence — the in-memory value is already updated.
    }
  }
}
