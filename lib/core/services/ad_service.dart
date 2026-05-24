import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_functions/cloud_functions.dart';

/// Singleton that manages all AdMob ad loading, showing, and daily limits.
class AdService {
  AdService._();
  static final AdService instance = AdService._();

  // ── Debug detector (stripped in release builds by Dart) ───────────────────
  static bool get _isDebug {
    bool debug = false;
    assert(() {
      debug = true;
      return true;
    }());
    return debug;
  }

  // ── Ad Unit IDs ───────────────────────────────────────────────────────────
  static String get _rewardedId => _isDebug
      ? 'ca-app-pub-3940256099942544/5224354917'   // Google test ID (debug)
      : 'ca-app-pub-9195964766205519/8333794938';  // Real ID (release)

  static String get _interstitialId => _isDebug
      ? 'ca-app-pub-3940256099942544/1033173712'   // Google test ID (debug)
      : 'ca-app-pub-9195964766205519/7020713265';  // Real ID (release)

  // ── State ─────────────────────────────────────────────────────────────────
  RewardedAd?     _rewardedAd;
  InterstitialAd? _interstitialAd;
  bool _rewardedLoading     = false;
  bool _interstitialLoading = false;

  // Daily cap — max rewarded ads per day
  static const int _dailyMax = 10;

  // ── Public API ────────────────────────────────────────────────────────────

  /// Call once at app start (after MobileAds.instance.initialize()).
  void preloadAll() {
    _loadRewarded();
    _loadInterstitial();
  }

  /// Returns how many rewarded ads the user can still watch today.
  Future<int> remainingToday() async {
    final prefs = await SharedPreferences.getInstance();
    final today = _today();
    final saved = prefs.getString('ad_date') ?? '';
    if (saved != today) return _dailyMax;
    return (_dailyMax - (prefs.getInt('ad_count') ?? 0)).clamp(0, _dailyMax);
  }

  /// Shows a rewarded ad if one is loaded and daily limit not reached.
  ///
  /// [onRewarded] is called ONLY when the user completes the full video.
  /// Returns true if the ad was shown, false if not ready or limit reached.
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
      await _incrementDailyCount();
      await onRewarded();
      await _incrementPrizePool();
    });

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

  // ── Private — daily tracking ──────────────────────────────────────────────

  String _today() => DateTime.now().toIso8601String().substring(0, 10);

  Future<void> _incrementDailyCount() async {
    final prefs = await SharedPreferences.getInstance();
    final today = _today();
    await prefs.setString('ad_date', today);
    final count = prefs.getInt('ad_count') ?? 0;
    await prefs.setInt('ad_count', count + 1);
  }

  // ── Private — prize pool increment via Cloud Function ─────────────────────

  Future<void> _incrementPrizePool() async {
    try {
      final fn = FirebaseFunctions.instance.httpsCallable('incrementPrizePool');
      await fn.call({'nairaAmount': 2.0});
    } catch (_) {
      // Silently fail — prize pool miss is non-critical
    }
  }
}