import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_update_service.dart';

/// Attaches a Play Integrity token to money calls.
///
/// Flow: `getIntegrityChallenge` issues a single-use nonce, the native side
/// requests a standard token with that nonce as `requestHash`, and the caller
/// sends `{integrityToken, integrityNonce}` with the money call. The server
/// verifies it in log-only mode today.
///
/// Never throws and never blocks play: any failure returns an empty map and
/// the call goes out without a token, exactly like the shipped build.
class PlayIntegrityService {
  PlayIntegrityService._();
  static final PlayIntegrityService instance = PlayIntegrityService._();

  static const MethodChannel _channel =
      MethodChannel('com.animequiz.app/play_integrity');

  // Must match the Google Cloud project number linked to the Play Console app.
  static const int _cloudProjectNumber = 342531348832;

  static const Duration _timeout = Duration(seconds: 8);

  Future<Map<String, String>> tokenFields(String action) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const {};
    }
    try {
      final challenge = await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('getIntegrityChallenge')
          .call<Map<Object?, Object?>>({
            'action': action,
            ...AppUpdateService.instance.clientBuildStamp,
          })
          .timeout(_timeout);
      final nonce = challenge.data['nonce'] as String?;
      if (nonce == null || nonce.isEmpty) return const {};

      final token = await _channel
          .invokeMethod<String>('requestToken', {
            'nonce': nonce,
            'cloudProjectNumber': _cloudProjectNumber,
          })
          .timeout(_timeout);
      if (token == null || token.isEmpty) return const {};

      return {'integrityToken': token, 'integrityNonce': nonce};
    } catch (e) {
      debugPrint('[PlayIntegrity] no token for $action, sending without: $e');
      return const {};
    }
  }
}
