import 'package:flutter/foundation.dart';

/// Web-only stub. The Android forced-update gate (`app_config/android`,
/// `package_info_plus`) was removed with the native folders. The server
/// still receives `platform: web` so its web exemption keeps working.
class AppUpdateState {
  final int installedBuild;
  final int? minBuild;
  final int? latestBuild;
  final String? apkUrl;

  const AppUpdateState({
    required this.installedBuild,
    this.minBuild,
    this.latestBuild,
    this.apkUrl,
  });

  bool get updateRequired => false;

  bool get newerBuildAvailable => false;
}

class AppUpdateService extends ChangeNotifier {
  AppUpdateService._();

  static final AppUpdateService instance = AppUpdateService._();

  final AppUpdateState _state = const AppUpdateState(installedBuild: 0);

  AppUpdateState get state => _state;

  Map<String, dynamic> get clientBuildStamp => const {'platform': 'web'};

  Future<void> init() async {}

  Future<bool> check({bool force = false}) async => false;

  void attachLifecycleGate() {}

  Future<bool> checkOnResume() async => false;

  void invalidateThrottle() {}
}
