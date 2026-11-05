import 'package:flutter/foundation.dart';

/// VM/test fallback: reload makes no sense off-browser.
class WebReload {
  WebReload._();

  static void reload() {
    debugPrint('[WebReload] reload requested off-browser (ignored)');
  }
}
