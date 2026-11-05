import 'package:web/web.dart' as web;

/// Browser implementation: hard-reloads the page so the newest deployed
/// build (already cached by the service worker / CDN) takes over.
class WebReload {
  WebReload._();

  static void reload() {
    try {
      web.window.location.reload();
    } catch (_) {
      // Best-effort only.
    }
  }
}
