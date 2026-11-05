// Web-only connectivity check entry point.
//
// Conditional export so VM targets (`flutter test`) never compile
// `package:web`: the stub reports online, the web file reads
// `navigator.onLine` + `online`/`offline` events.
export 'connectivity_service_stub.dart'
    if (dart.library.js_interop) 'connectivity_service_web.dart';
