import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';

/// Activates Firebase App Check before any other Firebase service is used.
///
/// Providers:
///   • Android — Play Integrity in release, debug provider in debug builds
///     (register the debug token printed by the plugin in the Firebase console).
///   • Web     — reCAPTCHA Enterprise. The site key is supplied at build time:
///     `flutter build web --dart-define=APP_CHECK_WEB_SITE_KEY=<key>`
///   • Apple   — App Attest with DeviceCheck fallback (debug provider in debug).
///
/// The SERVER is what actually enforces, and both of its switches start OFF
/// (monitor mode): `ENFORCE_APP_CHECK=true` at deploy time, and the runtime
/// flag `app_config/security.enforceAppCheck`. Activation failure here is
/// therefore logged, never fatal — an App Check outage must not brick the app
/// while the server is still in monitor mode.
class AppCheckService {
  AppCheckService._();
  static final AppCheckService instance = AppCheckService._();

  static const String _webSiteKey =
      String.fromEnvironment('APP_CHECK_WEB_SITE_KEY');

  bool _started = false;

  Future<void> activate() async {
    if (_started) return;
    _started = true;

    try {
      if (kIsWeb) {
        if (_webSiteKey.isEmpty) {
          debugPrint(
            '[AppCheck] APP_CHECK_WEB_SITE_KEY is not set — web attestation '
            'is disabled. The server stays in monitor mode for web clients.',
          );
          return;
        }
        await FirebaseAppCheck.instance.activate(
          providerWeb: ReCaptchaEnterpriseProvider(_webSiteKey),
        );
        debugPrint('[AppCheck] web reCAPTCHA Enterprise activated');
        return;
      }

      await FirebaseAppCheck.instance.activate(
        providerAndroid: kDebugMode
            ? const AndroidDebugProvider()
            : const AndroidPlayIntegrityProvider(),
        providerApple: kDebugMode
            ? const AppleDebugProvider()
            : const AppleAppAttestWithDeviceCheckFallbackProvider(),
      );
      debugPrint(
        '[AppCheck] activated (${kDebugMode ? 'debug' : 'release'} provider)',
      );
    } catch (e) {
      debugPrint('[AppCheck] activation failed (non-fatal): $e');
    }
  }
}
