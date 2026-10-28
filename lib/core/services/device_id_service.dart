import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// A per-install identifier used only for multi-account friction signals.
///
/// Deliberately NOT a hardware id: it is random, app-scoped, and reset by
/// clearing app data. The server stores only an HMAC hash (see
/// `_deviceHash` in functions/index.js), never this value.
class DeviceIdService {
  DeviceIdService._();
  static final DeviceIdService instance = DeviceIdService._();

  static const String _prefsKey = 'device_install_id_v1';

  String? _cached;

  Future<String> value() async {
    final cached = _cached;
    if (cached != null) return cached;

    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_prefsKey);
    if (id == null || id.isEmpty) {
      final random = Random.secure();
      id = List.generate(
        32,
        (_) => random.nextInt(16).toRadixString(16),
      ).join();
      await prefs.setString(_prefsKey, id);
    }
    _cached = id;
    return id;
  }
}
