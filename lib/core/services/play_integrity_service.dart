import 'package:flutter/foundation.dart';

/// Web-only stub. Play Integrity (MethodChannel +
/// `com.google.android.play:integrity`) was removed with `android/`.
/// All money calls go out without a token, exactly like the previous
/// fail-open path.
class PlayIntegrityService {
  PlayIntegrityService._();
  static final PlayIntegrityService instance = PlayIntegrityService._();

  Future<Map<String, String>> tokenFields(String action) async {
    debugPrint('[PlayIntegrity] web build, sending without token');
    return const {};
  }
}
