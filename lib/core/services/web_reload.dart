// Page-reload entry point.
//
// Conditional import so VM targets (`flutter test`) never compile
// `package:web`.
export 'web_reload_stub.dart'
    if (dart.library.js_interop) 'web_reload_web.dart';
