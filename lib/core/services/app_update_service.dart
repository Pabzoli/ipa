import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Resolved state of the Android forced-update gate.
///
/// The app is distributed as a sideloaded APK hosted by us, so there is no
/// store to force an update and a stale install can linger indefinitely. The
/// server is the real enforcement (see `_assertClientBuildAllowed` in
/// functions/index.js); this is the client-side wall that stops a stale user
/// before they can even try, and it reads the same Firestore doc the server
/// reads so the two can never disagree about what the floor is.
class AppUpdateState {
  /// Installed build number, from the running binary. Never guessed.
  final int installedBuild;

  /// Lowest build the server will accept, or null if the config doc is
  /// absent/unreadable. Null means "no gate" and is always allowed.
  final int? minBuild;

  /// Newest published build. Informational only — not enforced anywhere.
  final int? latestBuild;

  /// Where to send the user for the new APK.
  final String? apkUrl;

  const AppUpdateState({
    required this.installedBuild,
    this.minBuild,
    this.latestBuild,
    this.apkUrl,
  });

  /// True when the install is below the floor and must be replaced.
  ///
  /// A null [minBuild] (config missing/unreadable) is treated as allowed, and
  /// the platform gate means non-Android platforms are always allowed. Both
  /// fail OPEN on purpose: a config or platform hiccup must never be able to
  /// lock every player out of the app. The server-side gate is what actually
  /// protects money, and it fails open for the same reason.
  bool get updateRequired => !kIsWeb && minBuild != null && installedBuild < minBuild!;

  /// A newer build exists but this install is not required to move.
  bool get newerBuildAvailable =>
      !kIsWeb && minBuild != null && installedBuild >= minBuild! && latestBuild != null
      && installedBuild < latestBuild!;
}

/// App-wide, app-lifetime owner of the update gate.
///
/// Deliberately not a Provider: the gate has to be readable from the
/// `MaterialApp.builder` overlay, above the Navigator, and a provider would
/// make the wall's own construction depend on the very widget tree it is
/// covering. A ChangeNotifier singleton gives the overlay something to listen
/// to without adding a node to the tree it is covering.
class AppUpdateService extends ChangeNotifier {
  AppUpdateService._();

  static final AppUpdateService instance = AppUpdateService._();

  static const String _docPath = 'app_config/android';

  /// Throttle for the resume re-check. Resuming triggers this on every app
  /// switch, and an ad-heavy session resumes constantly; without a floor this
  /// would issue a Firestore read every time. 2 minutes is short enough that
  /// arming the gate is picked up quickly and long enough to be invisible.
  static const Duration _resumeThrottle = Duration(minutes: 2);

  /// Set once [init] resolves the installed build. Kept separate from
  /// [_state] so a cached config read can never mask the real build number.
  int? _installedBuild;

  String? _platform;
  AppUpdateState _state = const AppUpdateState(installedBuild: 0);
  DateTime? _lastCheckedAt;
  bool _initStarted = false;
  bool _lifecycleAttached = false;

  /// Last resolved state. Before [init] completes this reports a
  /// non-gating state, so a slow/failed init can never wall a user in.
  AppUpdateState get state => _state;

  /// The stamp every gated callable must send.
  ///
  /// `platform` is what makes the server's web exemption work: a web client
  /// reports 'web' and is never compared against minBuild. The build number is
  /// omitted only if [init] has not completed, which the server treats as a
  /// legacy build-1 client.
  Map<String, dynamic> get clientBuildStamp => {
        if (_platform != null) 'platform': _platform,
        if (_installedBuild != null) 'appBuild': _installedBuild,
      };

  /// Reads the installed build number and platform. Safe to call more than
  /// once; only the first call does work.
  Future<void> init() async {
    if (_initStarted) return;
    _initStarted = true;
    try {
      final info = await PackageInfo.fromPlatform();
      _installedBuild = _parseBuildNumber(info.buildNumber);
    } catch (e) {
      // Leave _installedBuild null: the server treats that as a legacy
      // build-1 client, which is the correct interpretation of an app that
      // cannot state its own version.
      debugPrint('[AppUpdateService] could not read build number: $e');
    }
    _platform = kIsWeb ? 'web' : _defaultPlatformName();
  }

  /// Fetches app_config/android and updates [state].
  ///
  /// [force] bypasses the throttle (used for the launch check and the
  /// post-install retry). Returns true when an update is required.
  Future<bool> check({bool force = false}) async {
    await init();

    if (kIsWeb) {
      // Web is exempt server-side and has no build number to compare. Skip
      // the read entirely rather than spending a Firestore call on it.
      _setState(_state.installedBuild == _installedBuild
          ? _state
          : AppUpdateState(installedBuild: _installedBuild ?? 0));
      return false;
    }

    final now = DateTime.now();
    final last = _lastCheckedAt;
    if (!force && last != null && now.difference(last) < _resumeThrottle) {
      return _state.updateRequired;
    }
    _lastCheckedAt = now;

    int? minBuild;
    int? latestBuild;
    String? apkUrl;
    try {
      // get() rather than a stream: this is a point-in-time gate check, and a
      // live subscription would keep a Firestore listener alive for the whole
      // app lifetime for a document that changes a few times a year.
      final snap = await FirebaseFirestore.instance.doc(_docPath).get();
      if (snap.exists) {
        final data = snap.data() ?? const {};
        minBuild = _asPositiveInt(data['minBuild']);
        latestBuild = _asPositiveInt(data['latestBuild']);
        final url = data['apkUrl'];
        if (url is String && url.trim().isNotEmpty) apkUrl = url.trim();
      }
    } catch (e) {
      // Fail OPEN. Offline, permission-denied and malformed-config all land
      // here, and all of them must leave the app usable: the _OfflineWall
      // already covers the genuinely-offline case, and the server gate is
      // still enforcing the floor on every money-touching call.
      debugPrint('[AppUpdateService] update config read failed, gate open: $e');
      minBuild = null;
    }

    _setState(AppUpdateState(
      installedBuild: _installedBuild ?? 0,
      minBuild: minBuild,
      latestBuild: latestBuild,
      apkUrl: apkUrl,
    ));
    return _state.updateRequired;
  }

  /// Registers the app-lifecycle hook that re-checks the gate on every
  /// foreground resume. Call once, after [WidgetsFlutterBinding] is initialised.
  ///
  /// Lives here rather than in a widget so it is active BEFORE authentication:
  /// the wall has to be able to appear over the login screen, not only over the
  /// app shell. (_AppShell's own observer cannot do that — it does not exist
  /// until the user is signed in.)
  void attachLifecycleGate() {
    if (_lifecycleAttached) return;
    _lifecycleAttached = true;
    WidgetsBinding.instance.addObserver(_GateLifecycleObserver(this));
  }

  /// Called on app resume. Throttled — see [_resumeThrottle].
  Future<bool> checkOnResume() => check(force: false);

  /// Forgets the throttle so the next [check] hits Firestore. Used when the
  /// user has just installed an update and the wall should re-evaluate without
  /// waiting out the window.
  void invalidateThrottle() => _lastCheckedAt = null;

  void _setState(AppUpdateState next) {
    if (next.updateRequired == _state.updateRequired &&
        next.minBuild == _state.minBuild &&
        next.latestBuild == _state.latestBuild &&
        next.apkUrl == _state.apkUrl &&
        next.installedBuild == _state.installedBuild) {
      return;
    }
    _state = next;
    notifyListeners();
  }

  /// package_info_plus returns buildNumber as a String. On Android it is the
  /// APK's versionCode, which is exactly what the server compares against
  /// minBuild, so no translation is needed beyond parsing.
  static int? _parseBuildNumber(String raw) {
    final v = int.tryParse(raw.trim());
    if (v == null || v < 1) return null;
    return v;
  }
  /// Strictly positive integers only. A float, string or zero is treated as
  /// "no gate configured" rather than coerced, mirroring the server.
  static int? _asPositiveInt(Object? v) {
    if (v is int && v >= 1) return v;
    return null;
  }

  static String _defaultPlatformName() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        break;
    }
    // Anything else (including a platform added by a future Flutter release)
    // is reported verbatim. It will not equal 'android', so the server treats
    // it as exempt — the safe default, because a mislabelled desktop client
    // must not be treated as a phone subject to the Android floor.
    return defaultTargetPlatform.name;
  }

  @visibleForTesting
  static void debugResetForTest() {
    final s = instance;
    s._initStarted = false;
    s._installedBuild = null;
    s._platform = null;
    s._lastCheckedAt = null;
    s._state = const AppUpdateState(installedBuild: 0);
  }
}

/// Re-runs the gate check whenever the app returns to the foreground, so a
/// build that was walled on launch can pick up a freshly-armed minBuild, and a
/// user who sideloaded the new build while backgrounded stops being walled
/// without restarting.
class _GateLifecycleObserver extends WidgetsBindingObserver {
  _GateLifecycleObserver(this._service);

  final AppUpdateService _service;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Fire and forget: the check is a point-in-time read, and the wall
      // rebuilds itself via the notifier when it lands.
      _service.checkOnResume();
    }
  }
}
