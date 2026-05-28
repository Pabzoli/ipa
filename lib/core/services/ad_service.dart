import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_functions/cloud_functions.dart';

/// Singleton that manages all AdMob ad loading, showing, and daily limits.
class AdService {
  AdService._();
  static final AdService instance = AdService._();

  // ── Debug detector (stripped in release builds by Dart) ───────────────────
  //
  // IMPORTANT — WHY YOU ONLY SEE TEST ADS:
  //   assert() runs only in debug/profile mode. In release builds it is
  //   stripped by the Dart compiler, so _isDebug returns false and the real
  //   ad unit IDs below are used automatically.
  //
  //   To see real ads you MUST:
  //     1. Build in release mode:  flutter build apk --release
  //     2. Confirm your AdMob App ID is in AndroidManifest.xml
  //        (meta-data key="com.google.android.gms.ads.APPLICATION_ID")
  //     3. Wait up to 24 h for new ad units to be approved by AdMob.
  //   Running `flutter run` (debug) will always serve Google test creatives.
  static bool get _isDebug {
    bool debug = false;
    assert(() {
      debug = true;
      return true;
    }());
    return debug;
  }

  // ── Ad Unit IDs ───────────────────────────────────────────────────────────
  static String get _rewardedId {
  if (_isDebug) return Platform.isAndroid
      ? 'ca-app-pub-3940256099942544/5224354917'   // Android test
      : 'ca-app-pub-3940256099942544/1712485313';  // iOS test
  return Platform.isAndroid
      ? 'ca-app-pub-9195964766205519/8333794938'   // your existing Android ID
      : 'ca-app-pub-9195964766205519/3107536339';
}

// ── Interstitial ──────────────────────────────────────────────────────────────
static String get _interstitialId {
  if (_isDebug) return Platform.isAndroid
      ? 'ca-app-pub-3940256099942544/1033173712'   // Android test
      : 'ca-app-pub-3940256099942544/4411468910';  // iOS test
  return Platform.isAndroid
      ? 'ca-app-pub-9195964766205519/7020713265'   // your existing Android ID
      : 'ca-app-pub-9195964766205519/8027175151';
}

// ── Rewarded Interstitial ─────────────────────────────────────────────────────
static String get _rewardedInterstitialId {
  if (_isDebug) return Platform.isAndroid
      ? 'ca-app-pub-3940256099942544/5354046379'   // Android test
      : 'ca-app-pub-3940256099942544/6978759866';  // iOS test
  return Platform.isAndroid
      ? 'ca-app-pub-9195964766205519/7787502007'   // TODO: your Android unit
      : 'ca-app-pub-9195964766205519/2225699506';
}

  // ── State ─────────────────────────────────────────────────────────────────
  RewardedAd?             _rewardedAd;
  InterstitialAd?         _interstitialAd;
  RewardedInterstitialAd? _rewardedInterstitialAd; // ← P-05

  bool _rewardedLoading             = false;
  bool _interstitialLoading         = false;
  bool _rewardedInterstitialLoading = false;       // ← P-05

  // 90-second cooldown between rewarded ad views.
  static const Duration _cooldown = Duration(seconds: 90);
  DateTime? _lastAdCompletedAt;

  // Daily cap — max rewarded ads per day (enforced server-side by recordAdWatch).
  static const int _dailyMax = 10;

  // ── Public API ────────────────────────────────────────────────────────────

  /// Call once at app start (after MobileAds.instance.initialize()).
  void preloadAll() {
    loadRewardedAd();
    _loadInterstitial();
    loadRewardedInterstitial(); // ← P-05
  }

  /// Explicitly pre-loads (or re-loads) the rewarded ad.
  /// Safe to call multiple times — no-ops if already loading or loaded.
  void loadRewardedAd() => _loadRewarded();

  // ── P-05: Rewarded Interstitial public API ────────────────────────────────

  /// Pre-loads (or re-loads) the rewarded interstitial ad.
  /// Called by [preloadAll] at startup and automatically after each dismiss.
  /// Safe to call multiple times — no-ops if already loading or loaded.
  void loadRewardedInterstitial() => _loadRewardedInterstitial();

  /// Whether a rewarded interstitial ad is loaded and ready to show.
  bool get isRewardedInterstitialReady => _rewardedInterstitialAd != null;

  /// Shows a rewarded interstitial ad at quiz result screens.
  ///
  /// Behaviour:
  ///   - Fires for ALL users including Premium (per spec).
  ///   - [onRewarded] is called if the user watches the full ad.
  ///   - Skips silently (returns immediately) if the ad is not yet loaded —
  ///     never blocks the user.
  ///   - Returns a [Future] that completes only after the ad is fully dismissed
  ///     (or immediately if not loaded), allowing callers to chain
  ///     [showInterstitialIfDue] after.
  ///
  /// Usage in result pages:
  /// ```dart
  /// await AdService.instance.showRewardedInterstitial(
  ///   context,
  ///   onRewarded: () {
  ///     userData.updateAnimeCoins(5, 'earn_rewarded_interstitial');
  ///     CoinEarnAnimation.show(context, amount: 5);
  ///   },
  /// );
  /// // Ad is now fully dismissed — safe to chain the regular interstitial.
  /// AdService.instance.showInterstitialIfDue(
  ///   isPremium: userData.premiumActive,
  ///   sessionQuizCount: userData.sessionQuizCount,
  /// );
  /// ```
  Future<void> showRewardedInterstitial(
    BuildContext context, {
    VoidCallback? onRewarded,
  }) async {
    if (_rewardedInterstitialAd == null) {
      // Not ready — kick off a fresh load for next time, skip silently now.
      _loadRewardedInterstitial();
      return;
    }

    final completer = Completer<void>();
    bool _userEarnedReward = false;

    _rewardedInterstitialAd!.fullScreenContentCallback =
        FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        _rewardedInterstitialAd = null;
        loadRewardedInterstitial(); // pre-load next immediately

        // Fire the reward callback only if the full ad was watched.
        if (_userEarnedReward && context.mounted && onRewarded != null) {
          onRewarded();
        }
        completer.complete();
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        debugPrint('[AdService] rewarded interstitial failed to show: $error');
        ad.dispose();
        _rewardedInterstitialAd = null;
        loadRewardedInterstitial();
        completer.complete(); // resolve so callers are not blocked
      },
    );

    _rewardedInterstitialAd!.show(
      onUserEarnedReward: (_, __) {
        // Fires when the user has watched enough of the ad to earn the reward.
        // We flag it here; the actual coin award happens in onAdDismissed so
        // we can act in a still-mounted context.
        _userEarnedReward = true;
      },
    );

    return completer.future;
  }

  /// Shows a regular interstitial ad only when both conditions are met:
  ///   1. The current user is NOT Premium ([isPremium] == false).
  ///   2. [sessionQuizCount] is a non-zero multiple of 3.
  ///
  /// The counter is an in-memory value tracked in [UserDataProvider] and
  /// reset to 0 on app restart. It is never persisted.
  ///
  /// Always call this AFTER [showRewardedInterstitial] has resolved so the
  /// two ads are strictly sequential and never overlap.
  ///
  /// Skips silently if the ad is not loaded — never blocks the user.
  void showInterstitialIfDue({
    required bool isPremium,
    required int sessionQuizCount,
  }) {
    // Premium users never see regular interstitials.
    if (isPremium) return;

    // Fire on every 3rd quiz completion this session.
    if (sessionQuizCount <= 0 || sessionQuizCount % 3 != 0) return;

    // Silently skip if not loaded — caller is never blocked.
    showInterstitial();
  }

  // ── Original rewarded ad API (P-04) ──────────────────────────────────────

  /// How many seconds remain before the next rewarded ad is available.
  /// Returns 0 when the cooldown has elapsed or no ad has been watched yet.
  int cooldownSecondsRemaining() {
    if (_lastAdCompletedAt == null) return 0;
    final elapsed = DateTime.now().difference(_lastAdCompletedAt!);
    final remaining = _cooldown - elapsed;
    return remaining.isNegative ? 0 : remaining.inSeconds;
  }

  /// Whether a rewarded ad is loaded and ready to show.
  bool get isRewardedAdReady => _rewardedAd != null;

  /// Returns how many rewarded ads the user can still watch today.
  /// NOTE: this reads local SharedPreferences only. The authoritative cap
  /// is enforced server-side by the recordAdWatch Cloud Function.
  Future<int> remainingToday() async {
    final prefs = await SharedPreferences.getInstance();
    final today = _todayUtc();
    final saved = prefs.getString('ad_date') ?? '';
    if (saved != today) return _dailyMax;
    return (_dailyMax - (prefs.getInt('ad_count') ?? 0)).clamp(0, _dailyMax);
  }

  /// Shows a rewarded ad and — on full completion — calls the [recordAdWatch]
  /// Cloud Function to award +10 Anime Coins server-side.
  ///
  /// [onComplete] receives the number of coins actually awarded (10).
  ///
  /// Returns false (without showing anything) when:
  ///   - The ad is not yet loaded.
  ///   - The 90-second cooldown has not elapsed.
  ///
  /// On skip/early-dismiss: shows a snackbar; [onComplete] is NOT called.
  ///
  /// On Cloud Function failure: shows an error snackbar; [onComplete] is
  /// NOT called (coins are never awarded without server confirmation).
  Future<bool> showRewardedAd({
    required BuildContext context,
    required void Function(int coinsAwarded) onComplete,
  }) async {
    // ── Cooldown gate ────────────────────────────────────────────────────────
    final secs = cooldownSecondsRemaining();
    if (secs > 0) {
      _showSnackBar(context, 'Next ad available in ${secs}s.');
      return false;
    }

    // ── Ad not ready ─────────────────────────────────────────────────────────
    if (_rewardedAd == null) {
      _loadRewarded(); // kick off a fresh load
      return false;
    }

    bool userCompletedWatch = false;

    _rewardedAd!.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) async {
        ad.dispose();
        _rewardedAd = null;
        loadRewardedAd(); // pre-load next ad immediately

        if (!userCompletedWatch) {
          // User skipped — never award coins.
          if (context.mounted) {
            _showSnackBar(context, 'Watch the full ad to earn coins 🪙');
          }
          return;
        }

        // ── Full watch confirmed — call Cloud Function ────────────────────
        try {
          final fn = FirebaseFunctions.instance
              .httpsCallable('recordAdWatch');
          final result = await fn.call<Map<String, dynamic>>();
          final data = result.data as Map<String, dynamic>;

          if (data['success'] == true) {
            final coins = (data['coinsAwarded'] as num).toInt();
            _lastAdCompletedAt = DateTime.now();
            await _incrementLocalDailyCount();
            if (context.mounted) onComplete(coins);
          } else if (data['error'] == 'daily_limit_reached') {
            if (context.mounted) {
              _showSnackBar(context, "You've watched 10 ads today. Come back tomorrow!");
            }
          }
        } catch (e) {
          debugPrint('[AdService] recordAdWatch error: $e');
          if (context.mounted) {
            _showSnackBar(context, 'Ad not available right now. Try again in a moment.');
          }
        }
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        ad.dispose();
        _rewardedAd = null;
        loadRewardedAd();
        if (context.mounted) {
          _showSnackBar(context, 'Ad not available right now. Try again in a moment.');
        }
      },
    );

    _rewardedAd!.show(
      onUserEarnedReward: (_, __) {
        // This fires when the user watches enough of the ad to earn the reward.
        // We flag it here; the actual coin award happens in onAdDismissed above
        // so we can show the result in a still-mounted context.
        userCompletedWatch = true;

        // Silently increment prize pool — no user-visible connection (AdMob §2.1).
        _silentlyIncrementPrizePool();
      },
    );

    return true;
  }

  /// Shows an interstitial ad if loaded. Safe to call — no-ops if not ready.
  void showInterstitial() {
    if (_interstitialAd == null) {
      _loadInterstitial();
      return;
    }
    _interstitialAd!.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        _interstitialAd = null;
        _loadInterstitial();
      },
      onAdFailedToShowFullScreenContent: (ad, _) {
        ad.dispose();
        _interstitialAd = null;
        _loadInterstitial();
      },
    );
    _interstitialAd!.show();
  }

  // ── Private — loading ─────────────────────────────────────────────────────

  void _loadRewarded() {
    if (_rewardedLoading || _rewardedAd != null) return;
    _rewardedLoading = true;
    RewardedAd.load(
      adUnitId: _rewardedId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          _rewardedAd      = ad;
          _rewardedLoading = false;
        },
        onAdFailedToLoad: (_) {
          _rewardedLoading = false;
          Future.delayed(const Duration(seconds: 30), _loadRewarded);
        },
      ),
    );
  }

  void _loadInterstitial() {
    if (_interstitialLoading || _interstitialAd != null) return;
    _interstitialLoading = true;
    InterstitialAd.load(
      adUnitId: _interstitialId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _interstitialAd      = ad;
          _interstitialLoading = false;
        },
        onAdFailedToLoad: (_) {
          _interstitialLoading = false;
          Future.delayed(const Duration(seconds: 30), _loadInterstitial);
        },
      ),
    );
  }

  // ── P-05: Rewarded Interstitial loading ───────────────────────────────────
  void _loadRewardedInterstitial() {
    if (_rewardedInterstitialLoading || _rewardedInterstitialAd != null) return;
    _rewardedInterstitialLoading = true;
    RewardedInterstitialAd.load(
      adUnitId: _rewardedInterstitialId,
      request: const AdRequest(),
      rewardedInterstitialAdLoadCallback: RewardedInterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _rewardedInterstitialAd      = ad;
          _rewardedInterstitialLoading = false;
          debugPrint('[AdService] rewarded interstitial loaded ✓');
        },
        onAdFailedToLoad: (error) {
          _rewardedInterstitialLoading = false;
          debugPrint('[AdService] rewarded interstitial failed to load: $error');
          // Retry after 30s — same pattern as other ad types.
          Future.delayed(
            const Duration(seconds: 30),
            _loadRewardedInterstitial,
          );
        },
      ),
    );
  }

  // ── Private — helpers ─────────────────────────────────────────────────────

  String _todayUtc() => DateTime.now().toUtc().toIso8601String().substring(0, 10);

  /// Local daily count — used only for optimistic UI. Server is authoritative.
  Future<void> _incrementLocalDailyCount() async {
    final prefs = await SharedPreferences.getInstance();
    final today = _todayUtc();
    await prefs.setString('ad_date', today);
    final count = prefs.getInt('ad_count') ?? 0;
    await prefs.setInt('ad_count', count + 1);
  }

  void _showSnackBar(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// Silently increments the prize pool after a full rewarded ad watch.
  /// No UI feedback — per AdMob §2.1, the user must not see a naira reward.
  void _silentlyIncrementPrizePool() {
    FirebaseFunctions.instance
        .httpsCallable('incrementPrizePool')
        .call({'nairaAmount': 2.0})
        .catchError((_) {});
  }

  // ── Legacy method — kept for any call sites not yet migrated to P-04 ──────
  /// Prefer [showRewardedAd] for all new code.
  @Deprecated('Use showRewardedAd() — it awards AC via the recordAdWatch CF')
  Future<bool> showRewarded({required Future<void> Function() onRewarded}) async {
    final remaining = await remainingToday();
    if (remaining <= 0) return false;
    if (_rewardedAd == null) {
      _loadRewarded();
      return false;
    }

    _rewardedAd!.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        _rewardedAd = null;
        _loadRewarded();
      },
      onAdFailedToShowFullScreenContent: (ad, _) {
        ad.dispose();
        _rewardedAd = null;
        _loadRewarded();
      },
    );

    _rewardedAd!.show(onUserEarnedReward: (_, __) async {
      await _incrementLocalDailyCount();
      await onRewarded();
      _silentlyIncrementPrizePool();
    });

    return true;
  }
}