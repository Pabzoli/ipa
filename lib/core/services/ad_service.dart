import 'package:flutter/material.dart';

/// Web-only ad seam.
///
/// The AdMob implementation (`google_mobile_ads`) was removed with the
/// native folders. This no-op keeps every former call site compiling so a
/// future web-ads provider can plug back in without touching the screens.
///
/// Contract: every `show*` returns "not shown", every `is*Ready` is false,
/// cooldowns are 0. Callers already fall back to their snackbar paths.
class AdService {
  AdService._();
  static final AdService instance = AdService._();

  /// Master switch for app-open ads. Always off until a web provider lands.
  static const bool appOpenAdsEnabled = false;

  /// Tracks whether a quiz run is on screen. Counter-based so nested or
  /// overlapping quiz pages can never leave the gate stuck open. Pure Dart
  /// state (no plugin) — also read by WebUpdateService so an auto-refresh
  /// never kills a live run.
  static int _quizActiveCount = 0;

  /// True while any quiz page is mounted.
  bool get isQuizActive => _quizActiveCount > 0;

  /// Call from QuestionsPage.initState() / dispose().
  void setQuizActive(bool active) {
    if (active) {
      _quizActiveCount++;
    } else if (_quizActiveCount > 0) {
      _quizActiveCount--;
    }
  }

  void preloadAll() {}

  void loadRewardedAd() {}

  Future<void> recordResultAndMaybeShowInterstitial({
    required bool isPremium,
  }) async {}

  void showAppOpenAdIfReady({required bool isPremium}) {}

  void showInterstitial() {}

  int cooldownSecondsRemaining() => 0;

  bool get isRewardedAdReady => false;

  Future<int> remainingToday() async => 0;

  Future<bool> showRewardedAd({
    required BuildContext context,
    required void Function(int coinsAwarded) onComplete,
  }) async =>
      false;

  Future<bool> showQMTokenAd({
    required BuildContext context,
    required VoidCallback onTokenGranted,
  }) async =>
      false;
}
