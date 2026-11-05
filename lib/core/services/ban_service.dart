import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// Client half of the auto-ban system (server lives in `functions/index.js`:
/// `onSecureCall` central suspension gate + `_recordAntiCheatSignal` ladder +
/// `adminBan` / `adminUnban` + `getMyEnforcementStatus`).
///
/// The enforcement collections are server-only (`firestore.rules` denies every
/// client read), so the app cannot watch them directly. It learns it is banned
/// two ways: the probe below, and `isBanError` on any callable failure.
class BanService {
  BanService._();
  static final BanService instance = BanService._();

  FirebaseFunctions get _functions =>
      FirebaseFunctions.instanceFor(region: 'us-central1');

  /// True for the server's suspension rejection, whatever the call site.
  static bool isBanError(Object e) {
    if (e is FirebaseFunctionsException) {
      if (e.code == 'failed-precondition' &&
          (e.message ?? '') == 'account_under_review') {
        return true;
      }
      final details = e.details;
      if (e.code == 'failed-precondition' &&
          details is Map &&
          details['reason'] == 'account_under_review') {
        return true;
      }
    }
    return false;
  }

  /// Probe for the ban gate. Returns true when suspended. Fails open — an
  /// unreachable backend never locks anyone out.
  Future<bool> isBanned() async {
    try {
      final res =
          await _functions.httpsCallable('getMyEnforcementStatus').call();
      final data = Map<String, dynamic>.from(res.data as Map);
      return data['suspended'] == true;
    } catch (e) {
      if (isBanError(e)) return true;
      debugPrint('[BanService] status probe failed (fail open): $e');
      return false;
    }
  }
}
