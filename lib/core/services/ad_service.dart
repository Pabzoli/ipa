import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'app_update_service.dart';

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

// ── App Open ──────────────────────────────────────────────────────────────────
// TODO: Create App Open ad units in your AdMob dashboard and replace these IDs.
static String get _appOpenAdId {
  if (_isDebug) return Platform.isAndroid
      ? 'ca-app-pub-3940256099942544/9257395921'   // Android test
      : 'ca-app-pub-3940256099942544/5575463023';  // iOS test
  return Platform.isAndroid
      ? 'ca-app-pub-9195964766205519/2949625797'
: 'ca-app-pub-9195964766205519/8728410558';
}

// ── State ─────────────────────────────────────────────────────────────────
  RewardedAd?     _rewardedAd;
  InterstitialAd? _interstitialAd;
  AppOpenAd?      _appOpenAd;

  bool _rewardedLoading     = false;
  bool _interstitialLoading = false;
  bool _appOpenLoading      = false;

  DateTime? _appOpenAdLoadTime;
  static const Duration _appOpenMaxAge = Duration(hours: 4);

  /// Rate-limit for app-open ads — at most one per 30 min across cold open
  /// and foreground resumes, so backgrounding mid-session never chains ads.
  static DateTime? _lastAppOpenShownAt;
  static const Duration _appOpenMinGap = Duration(minutes: 30);

  /// Set by QuestionsPage.initState() / dispose(). Counter-based so nested
  /// or overlapping quiz pages can never leave the gate stuck open.
  static int _quizActiveCount = 0;

  /// Call from QuestionsPage.initState() / dispose() to suppress app-open
  /// ads during active gameplay.
  void setQuizActive(bool active) {
    if (active) {
      _quizActiveCount++;
    } else if (_quizActiveCount > 0) {
      _quizActiveCount--;
    }
  }

  bool get _quizActive => _quizActiveCount > 0;

  /// Global concurrency gate — true while ANY ad is on-screen.
  /// All show/load entry-points short-circuit when this is true.
  bool _isAdShowing = false;

  // ── Session-level interstitial throttling (reset on app restart) ──────────
  static int _sessionResultCount        = 0;  // increments every result screen
  static int _sessionInterstitialsShown = 0;
  static DateTime? _lastInterstitialTime;

  static const int _interstitialEvery   = 3;   // trigger every Nth result
  static const int _sessionMax          = 5;   // hard cap per session
  static const int _cooldownSeconds     = 90;  // minimum gap (seconds)

  // 30-second cooldown between rewarded ad views — short enough to let users
  // comfortably grind the Earn Coins screen (10 ads = ~5 min) while still
  // preventing rapid-fire abuse. Interstitial cooldown is separate (90 s).
  static const Duration _cooldown = Duration(seconds: 30);
  DateTime? _lastAdCompletedAt;

  // Daily cap — max rewarded ads per day (enforced server-side by recordAdWatch).
  static const int _dailyMax = 10;

  // ── Public API ────────────────────────────────────────────────────────────

  /// Call once at app start (after MobileAds.instance.initialize()).
  void preloadAll() {
    loadRewardedAd();
    _loadInterstitial();
    if (appOpenAdsEnabled) {
      _loadAppOpenAd();
    }
  }

  /// Explicitly pre-loads (or re-loads) the rewarded ad.
  /// Safe to call multiple times — no-ops if already loading or loaded.
  void loadRewardedAd() => _loadRewarded();

  // ── Session-frequency interstitial API ────────────────────────────────────

  /// Call this from every result screen as soon as it mounts.
  /// Internally decides whether to fire an interstitial based on session
  /// frequency, cooldown, and the per-session hard cap.
  Future<void> recordResultAndMaybeShowInterstitial({
    required bool isPremium,
  }) async {
    _sessionResultCount++;
    if (_shouldShowInterstitial(isPremium)) {
      await _showInterstitialAd();
    }
  }

  bool _shouldShowInterstitial(bool isPremium) {
    if (isPremium) return false;
    if (_sessionInterstitialsShown >= _sessionMax) return false;
    if (_sessionResultCount % _interstitialEvery != 0) return false;
    if (_lastInterstitialTime != null &&
        DateTime.now()
                .difference(_lastInterstitialTime!)
                .inSeconds <
            _cooldownSeconds) {
      return false;
    }
    return true;
  }

  Future<void> _showInterstitialAd() async {
    // Interstitials are revenue-only — no AC reward.
    if (_isAdShowing) return;
    if (_interstitialAd == null) {
      _loadInterstitial(); // kick off a fresh load for next time
      return;
    }

    _sessionInterstitialsShown++;
    _lastInterstitialTime = DateTime.now();
    _isAdShowing = true;

    final completer = Completer<void>();

    _interstitialAd!.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        _interstitialAd = null;
        _isAdShowing = false;
        _loadInterstitial(); // pre-load next immediately
        completer.complete();
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        debugPrint('[AdService] interstitial failed to show: $error');
        ad.dispose();
        _interstitialAd = null;
        _isAdShowing = false;
        _loadInterstitial();
        completer.complete();
      },
    );

    _interstitialAd!.show();
    return completer.future;
  }

  // ── App Open Ad API ────────────────────────────────────────────────────────

  /// Master switch for app open ads. Currently DISABLED for release because
  /// the App Open ad units aren't configured in AdMob yet. Flip to `true` to
  /// re-enable the load/show path below — no other changes required.
  static const bool appOpenAdsEnabled = false;

  /// Call on cold open and every time the app returns to foreground.
  /// No-ops silently when: premium, quiz active, another ad is showing,
  /// ad not loaded, or the loaded ad has expired (>4 h old).
  void showAppOpenAdIfReady({required bool isPremium}) {
    if (!appOpenAdsEnabled) return;
    if (isPremium)      return;
    if (_quizActive)    return;
    if (_isAdShowing)   return;

    // Rate-limit — skip if an app-open was shown less than 30 min ago.
    final now = DateTime.now();
    if (_lastAppOpenShownAt != null &&
        now.difference(_lastAppOpenShownAt!) < _appOpenMinGap) {
      return;
    }

    // Expire and reload if the loaded creative is too old.
    if (_appOpenAd != null && _isAppOpenAdExpired) {
      _appOpenAd!.dispose();
      _appOpenAd = null;
      _loadAppOpenAd();
      return;
    }

    if (_appOpenAd == null) {
      _loadAppOpenAd();
      return;
    }

    _isAdShowing = true;
    _lastAppOpenShownAt = now;
    _appOpenAd!.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        _appOpenAd   = null;
        _isAdShowing = false;
        _loadAppOpenAd(); // pre-load immediately for next foreground
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        debugPrint('[AdService] app open ad failed to show: $error');
        ad.dispose();
        _appOpenAd   = null;
        _isAdShowing = false;
        _loadAppOpenAd();
      },
    );
    _appOpenAd!.show();
  }

  bool get _isAppOpenAdExpired {
    if (_appOpenAdLoadTime == null) return true;
    return DateTime.now().difference(_appOpenAdLoadTime!) > _appOpenMaxAge;
  }



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
  /// Cloud Function to award +15 Anime Coins server-side.
  ///
  /// [onComplete] receives the number of coins actually awarded (15).
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
    // ── Concurrency gate ─────────────────────────────────────────────────────
    if (_isAdShowing) return false;

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

    _isAdShowing = true;
    bool userCompletedWatch = false;

    _rewardedAd!.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) async {
        ad.dispose();
        _rewardedAd = null;
        _isAdShowing = false;   // ← release concurrency gate
        loadRewardedAd(); // pre-load next ad immediately

        if (!userCompletedWatch) {
          // User skipped — never award coins.
          if (context.mounted) {
            _showSnackBar(context, 'Watch the full ad to earn coins 🪙');
          }
          return;
        }

        // ── Full watch confirmed — call Cloud Function ────────────────────
        // Two-step, both server-authoritative: mint a single-use session token
        // for this completed view, then redeem it exactly once for the coins.
        // A script can still drive both calls, but it cannot bypass the
        // per-user daily cap or the 30-second spacing enforced with the token.
        try {
          final fn = FirebaseFunctions.instanceFor(region: 'us-central1');
          final stamp = AppUpdateService.instance.clientBuildStamp;

          final session = await fn
              .httpsCallable('startAdSession')
              .call<Map<String, dynamic>>(Map<String, dynamic>.from(stamp));
          final token = (session.data['sessionToken'] as String?)?.trim() ?? '';
          if (token.isEmpty) {
            throw StateError('startAdSession returned no token');
          }

          final result = await fn
              .httpsCallable('recordAdWatch')
              .call<Map<String, dynamic>>({
            'sessionToken': token,
            ...stamp,
          });
          final data = result.data;

          if (data['success'] == true) {
            final coins = (data['coinsAwarded'] as num).toInt();
            _lastAdCompletedAt = DateTime.now();
            await _incrementLocalDailyCount();
            if (context.mounted) onComplete(coins);
          } else if (data['error'] == 'daily_limit_reached') {
            if (context.mounted) {
              _showSnackBar(context, "You've reached the 10-ad daily limit. Come back tomorrow!");
            }
          } else if (data['error'] == 'ad_cooldown_active') {
            if (context.mounted) {
              _showSnackBar(context, 'Ad not available right now. Try again in a moment.');
            }
          } else if (data['error'] == 'ad_session_invalid') {
            if (context.mounted) {
              _showSnackBar(context, 'Ad verification expired. Please try again.');
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
        _isAdShowing = false;   // ← release concurrency gate
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

        // No prize-pool increment here: the pool is set explicitly by the
        // admin (setPrizePool), not accumulated from ad views.
      },
    );

    return true;
  }

  /// Shows an interstitial ad if loaded. Safe to call — no-ops if not ready.
  void showInterstitial() {
    // ── Concurrency gate ───────────────────────────────────────────────────
    if (_isAdShowing) return;

    if (_interstitialAd == null) {
      _loadInterstitial();
      return;
    }
    _isAdShowing = true;
    _interstitialAd!.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        _interstitialAd = null;
        _isAdShowing = false;   // ← release concurrency gate
        _loadInterstitial();
      },
      onAdFailedToShowFullScreenContent: (ad, _) {
        ad.dispose();
        _interstitialAd = null;
        _isAdShowing = false;   // ← release concurrency gate
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

  void _loadAppOpenAd() {
    if (_appOpenLoading || _appOpenAd != null) return;
    _appOpenLoading = true;
    AppOpenAd.load(
      adUnitId: _appOpenAdId,
      request: const AdRequest(),
      adLoadCallback: AppOpenAdLoadCallback(
        onAdLoaded: (ad) {
          _appOpenAd       = ad;
          _appOpenAdLoadTime = DateTime.now();
          _appOpenLoading  = false;
        },
        onAdFailedToLoad: (error) {
          debugPrint('[AdService] app open ad failed to load: $error');
          _appOpenLoading = false;
          // Back off 2 minutes before retrying — app open ads are lower priority.
          Future.delayed(const Duration(minutes: 2), _loadAppOpenAd);
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

  // REMOVED: _silentlyIncrementPrizePool.
  //
  // This called the incrementPrizePool Cloud Function after each rewarded ad
  // to top up the prize pool. It never worked: that callable accumulated into
  // prize_pool/{weekId}.totalNaira while weeklyReset computes the pool from
  // entryCodeRevenue and never read totalNaira. Every naira was discarded.
  //
  // The prize pool is now set explicitly by the admin via setPrizePool, so
  // there is nothing for an ad view to increment.

  // ── Quick Match ad-token rewarded ad ─────────────────────────────────────
  //
  // Loads and shows a rewarded ad using the same ad unit as showRewardedAd.
  // On full watch → calls the grantAdQMToken Cloud Function.
  //   • CF success : calls onTokenGranted() so the caller can refresh UI.
  //   • CF failure : shows a snackbar "Something went wrong — try again."
  //   • User skips : shows "Watch the full ad to earn a token 🎟" snackbar.
  //
  // Does NOT call recordAdWatch — no AC is awarded; no prize-pool increment.
  // Returns false without showing anything when:
  //   • Another ad is already on screen.
  //   • The rewarded ad is not yet loaded (kicks off a fresh load for next time).
  Future<bool> showQMTokenAd({
    required BuildContext context,
    required VoidCallback onTokenGranted,
  }) async {
    // ── Concurrency gate ─────────────────────────────────────────────────────
    if (_isAdShowing) return false;

    // ── Cooldown gate (shared with showRewardedAd) ────────────────────────────
    // Prevents back-to-back rewarded-ad views regardless of which path the
    // user takes (AC earn or QM token).
    final secs = cooldownSecondsRemaining();
    if (secs > 0) {
      _showSnackBar(context, 'Next ad available in ${secs}s.');
      return false;
    }

    // ── Ad not ready ─────────────────────────────────────────────────────────
    if (_rewardedAd == null) {
      _loadRewarded();
      return false;
    }

    _isAdShowing = true;
    bool userCompletedWatch = false;

    _rewardedAd!.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) async {
        ad.dispose();
        _rewardedAd  = null;
        _isAdShowing = false;
        loadRewardedAd(); // pre-load next ad immediately

        if (!userCompletedWatch) {
          if (context.mounted) {
            _showSnackBar(context, 'Watch the full ad to earn a token 🎟');
          }
          return;
        }

        // ── Full watch confirmed — call Cloud Function ────────────────────────
        try {
          final result = await FirebaseFunctions.instanceFor(region: 'us-central1')
              .httpsCallable('grantAdQMToken')
              .call<Map<Object?, Object?>>({});

          final data = Map<String, dynamic>.from(result.data);
          if (data['success'] == true) {
            _lastAdCompletedAt = DateTime.now(); // start shared cooldown
            if (context.mounted) onTokenGranted();
          } else {
            if (context.mounted) {
              _showSnackBar(context, 'Something went wrong — try again.');
            }
          }
        } catch (e) {
          debugPrint('[AdService] grantAdQMToken error: $e');
          if (context.mounted) {
            _showSnackBar(context, 'Something went wrong — try again.');
          }
        }
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        debugPrint('[AdService] showQMTokenAd failed to show: $error');
        ad.dispose();
        _rewardedAd  = null;
        _isAdShowing = false;
        loadRewardedAd();
        if (context.mounted) {
          _showSnackBar(context, 'Ad not available right now. Try again in a moment.');
        }
      },
    );

    _rewardedAd!.show(
      onUserEarnedReward: (_, __) {
        // Flag completion; CF call happens in onAdDismissed above so context
        // is still mounted when we show the result / snackbar.
        userCompletedWatch = true;
        // No prize-pool increment here (see showRewardedAd above).
      },
    );

    return true;
  }
}