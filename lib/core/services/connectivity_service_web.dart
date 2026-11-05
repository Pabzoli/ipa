import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Browser connectivity check.
///
/// Initial state comes from `navigator.onLine`; live updates come from the
/// browser `online`/`offline` events. Firestore/auth errors are handled by
/// the callers (streams fail open / retry) — this service only reports what
/// the browser knows.
class ConnectivityService {
  ConnectivityService._();
  static final ConnectivityService instance = ConnectivityService._();

  StreamController<bool>? _controller;

  bool get isOnlineNow {
    try {
      return web.window.navigator.onLine;
    } catch (_) {
      return true;
    }
  }

  Future<bool> checkOnline() async => isOnlineNow;

  Stream<bool> get onStatusChanged {
    final existing = _controller;
    if (existing != null) return existing.stream;
    final controller = StreamController<bool>.broadcast();
    _controller = controller;
    void onOnline(web.Event _) => controller.add(true);
    void onOffline(web.Event _) => controller.add(false);
    try {
      web.window.addEventListener('online', onOnline.toJS);
      web.window.addEventListener('offline', onOffline.toJS);
    } catch (_) {
      // Event wiring is best-effort; polling via checkOnline still works.
    }
    return controller.stream;
  }
}
