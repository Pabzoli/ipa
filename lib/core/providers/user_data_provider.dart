import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../services/firestore_service.dart';
import 'package:cloud_functions/cloud_functions.dart';

class UserDataProvider extends ChangeNotifier {
  // ── Defaults are 0 / false, NOT fake values.
  // The streams replace these with real Firestore values as soon as
  // the user is authenticated and online.
  int  _score               = 0;
  int  _animeCoins          = 0;
  int  _weeklyPoints        = 0;
  int  _dailyAdWatched      = 0;   // ← P-04: how many rewarded ads watched today
  bool _loading             = true;
  bool _isOnline            = false;
  bool _connectivityChecked = false;

  // ── Streak Shield ─────────────────────────────────────────────────────────
  bool _streakShieldActive  = false;

  // ── P-05: Premium status ──────────────────────────────────────────────────
  // Streamed from users/{uid}.premiumActive via FirestoreService.
  // Controls whether regular interstitials are shown at result screens.
  // Server-written only — never set client-side.
  bool _premiumActive       = false;

  // ── P-05: Session quiz counter ────────────────────────────────────────────
  // In-memory only. Never persisted to disk or Firestore.
  // Incremented by result pages each time any quiz (solo / challenge /
  // quick match) completes. Reset to 0 on app restart (hot-restart clears it
  // because the provider is reconstructed).
  // Used by AdService.showInterstitialIfDue to fire on every 3rd quiz.
  int _sessionQuizCount     = 0;

  // ── Initialization Guard ─────────────────────────────────────────────────
  bool _isInitialized       = false;

  int  get score               => _score;
  int  get animeCoins          => _animeCoins;
  int  get weeklyPoints        => _weeklyPoints;
  /// How many rewarded ads the signed-in user has watched today (WAT).
  /// Server-reset to 0 on date change by the recordAdWatch Cloud Function.
  /// Resets to 0 locally on sign-out. READ-ONLY on the client.
  int  get dailyAdWatched      => _dailyAdWatched;
  /// Remaining rewarded ads the user can watch today.
  int  get adsRemainingToday   => (10 - _dailyAdWatched).clamp(0, 10);
  bool get loading             => _loading;
  bool get isOnline            => _isOnline;
  bool get connectivityChecked => _connectivityChecked;
  bool get streakShieldActive  => _streakShieldActive;

  // ── P-05 getters ─────────────────────────────────────────────────────────
  /// Whether the current user has an active premium subscription.
  /// Sourced from users/{uid}.premiumActive via Firestore stream.
  /// Used by result pages to gate the regular interstitial ad.
  bool get premiumActive     => _premiumActive;

  /// Number of quizzes completed in the current app session.
  /// Never persisted — resets to 0 on app restart.
  /// Incremented by result pages (solo + challenge + quick match) via
  /// [incrementSessionQuizCount]. Read by [AdService.showInterstitialIfDue].
  int  get sessionQuizCount  => _sessionQuizCount;

  StreamSubscription<List<ConnectivityResult>>? _connectSub;
  StreamSubscription<User?>?                    _authSub;
  StreamSubscription<int>?                      _scoreSub;
  StreamSubscription<int>?                      _animeCoinsSub;
  StreamSubscription<int>?                      _weeklyPointsSub;
  StreamSubscription<bool>?                     _shieldSub;
  StreamSubscription<int>?                      _dailyAdWatchedSub; // ← P-04
  StreamSubscription<bool>?                     _premiumActiveSub;  // ← P-05

  /// Constructor triggers self-initialization instantly when created
  UserDataProvider() {
    init();
  }

  void init() {
    if (_isInitialized) return;
    _isInitialized = true;

    // ── 1. Connectivity Check ────────────────────────────────────────────────
    try {
      Connectivity()
          .checkConnectivity()
          .timeout(
            const Duration(seconds: 3),
            onTimeout: () => [ConnectivityResult.wifi],
          )
          .then((results) {
            _isOnline = _hasConnection(results);
          })
          .catchError((_) {
            _isOnline = true;
          })
          .whenComplete(() {
            _connectivityChecked = true;
            notifyListeners();
          });
    } catch (e) {
      _isOnline            = true;
      _connectivityChecked = true;
      notifyListeners();
    }

    // ── 2. Live Connection Listener ──────────────────────────────────────────
    try {
      _connectSub = Connectivity().onConnectivityChanged.listen(
        (results) {
          final online = _hasConnection(results);
          if (online != _isOnline) {
            _isOnline = online;
            notifyListeners();
            if (online && FirebaseAuth.instance.currentUser != null) {
              _startFirestoreStreams();
            }
          }
        },
        onError: (error) {
          debugPrint('Connectivity stream error ignored on iOS: $error');
        },
      );
    } catch (e) {
      debugPrint('Failed to bind connectivity stream on iOS: $e');
    }

    // ── 3. Auth State Listener ───────────────────────────────────────────────
    try {
      _authSub = FirebaseAuth.instance.authStateChanges().listen(
        (user) {
          if (user == null) {
            _cancelFirestoreStreams();
            _resetLocalState();
            notifyListeners();
          } else {
            _startFirestoreStreams();
          }
        },
        onError: (error) {
          _connectivityChecked = true;
          notifyListeners();
        },
      );
    } catch (e) {
      _connectivityChecked = true;
      notifyListeners();
    }
  }

  // ── Private helpers ──────────────────────────────────────────────────────────

  bool _hasConnection(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);

  void _resetLocalState() {
    _score              = 0;
    _animeCoins         = 0;
    _weeklyPoints       = 0;
    _dailyAdWatched     = 0;   // ← P-04
    _streakShieldActive = false;
    _premiumActive      = false; // ← P-05
    // _sessionQuizCount is intentionally NOT reset here — it survives
    // sign-out within the same app session. This matches the spec
    // ("in-memory counter, not persisted"). If you want it reset on
    // sign-out instead, uncomment the line below.
    // _sessionQuizCount = 0;
    _loading            = true;
  }

  void _cancelFirestoreStreams() {
    _scoreSub?.cancel();           _scoreSub           = null;
    _animeCoinsSub?.cancel();      _animeCoinsSub      = null;
    _weeklyPointsSub?.cancel();    _weeklyPointsSub    = null;
    _shieldSub?.cancel();          _shieldSub          = null;
    _dailyAdWatchedSub?.cancel();  _dailyAdWatchedSub  = null; // ← P-04
    _premiumActiveSub?.cancel();   _premiumActiveSub   = null; // ← P-05
  }

  void _startFirestoreStreams() {
    _cancelFirestoreStreams();

    // One-time migrations — fire-and-forget.
    FirestoreService.instance.runMigrationIfNeeded().catchError((e) {
      debugPrint('[UserDataProvider] migration error (ignored): $e');
    });
    FirestoreService.instance.ensureStreakShieldFields().catchError((e) {
      debugPrint('[UserDataProvider] ensureStreakShieldFields error (ignored): $e');
    });
    FirestoreService.instance.ensureAnimeCoinField().catchError((e) {
      debugPrint('[UserDataProvider] ensureAnimeCoinField error (ignored): $e');
    });
    FirestoreService.instance.ensureDailyAdWatchedFields().catchError((e) {
      debugPrint('[UserDataProvider] ensureDailyAdWatchedFields error (ignored): $e');
    });

    // ── Score ────────────────────────────────────────────────────────────────
    _scoreSub = FirestoreService.instance.scoreStream().listen(
      (s) {
        _score   = s;
        _loading = false;
        notifyListeners();
      },
      onError: (_) {
        _loading = false;
        notifyListeners();
      },
    );

    // ── Anime Coins ──────────────────────────────────────────────────────────
    _animeCoinsSub = FirestoreService.instance.animeCoinsStream().listen(
      (c) {
        _animeCoins = c;
        notifyListeners();
      },
      onError: (e) {
        debugPrint('[UserDataProvider] animeCoins stream error: $e');
        _loading = false;
        notifyListeners();
      },
    );

    // ── Weekly Points ────────────────────────────────────────────────────────
    _weeklyPointsSub = FirestoreService.instance.weeklyPointsStream().listen(
      (wp) {
        _weeklyPoints = wp;
        notifyListeners();
      },
    );

    // ── Streak Shield ─────────────────────────────────────────────────────────
    _shieldSub = FirestoreService.instance.streakShieldStream().listen(
      (active) {
        _streakShieldActive = active;
        notifyListeners();
      },
      onError: (_) {},
    );

    // ── Daily Ad Watched (P-04) ───────────────────────────────────────────────
    // Watches users/{uid}.dailyAdWatched for real-time cap display.
    // The value is written ONLY by the recordAdWatch Cloud Function (server-side).
    // Firestore rules block all client writes to this field.
    _dailyAdWatchedSub = FirestoreService.instance.dailyAdWatchedStream().listen(
      (count) {
        _dailyAdWatched = count;
        notifyListeners();
      },
      onError: (e) {
        debugPrint('[UserDataProvider] dailyAdWatched stream error (ignored): $e');
        // Non-fatal — UI falls back to local SharedPreferences count in AdService.
      },
    );

    // ── Premium Active (P-05) ─────────────────────────────────────────────────
    // Watches users/{uid}.premiumActive to gate regular interstitial ads.
    // Written server-side by purchase verification (Google Play Billing).
    // Firestore rules block all client writes to this field.
    _premiumActiveSub = FirestoreService.instance.premiumActiveStream().listen(
      (active) {
        _premiumActive = active;
        notifyListeners();
      },
      onError: (e) {
        debugPrint('[UserDataProvider] premiumActive stream error (ignored): $e');
        // Non-fatal — defaults to false (non-premium), which is the safe direction.
        // A false negative (treating a premium user as non-premium) just means
        // they see an extra interstitial — not a billing issue.
      },
    );
  }

  @override
  void dispose() {
    _connectSub?.cancel();
    _authSub?.cancel();
    _cancelFirestoreStreams();
    super.dispose();
  }

  // ── Public API ───────────────────────────────────────────────────────────────

  Future<void> addScore(int amount) =>
      FirestoreService.instance.addToScore(amount);

  Future<void> subtractScore(int amount) =>
      FirestoreService.instance.subtractFromScore(amount);

  Future<void> addWeeklyPoints(int amount) =>
      FirestoreService.instance.addWeeklyPoints(amount);

  Future<void> updateAnimeCoins(int delta, String type) =>
      FirestoreService.instance.updateAnimeCoins(delta, type);

  Future<void> setStreakShieldActive(bool value) =>
      FirestoreService.instance.setStreakShieldActive(value);

  // ── P-05: Session quiz counter ────────────────────────────────────────────
  /// Increments the in-memory session quiz counter by 1.
  ///
  /// Call this from every quiz result page (solo / challenge / quick match)
  /// immediately before the ad sequence fires. The count is used by
  /// [AdService.showInterstitialIfDue] to show a regular interstitial every
  /// 3rd completion for non-Premium users.
  ///
  /// This method is synchronous and does NOT write to Firestore or disk.
  void incrementSessionQuizCount() {
    _sessionQuizCount++;
    // No notifyListeners() — no widget reads this value for display.
    // AdService reads it via a direct getter call, not via a Consumer.
  }

  // ── Daily Login Bonus (+5 AC) ────────────────────────────────────────────────
  Future<int> checkAndAwardDailyLogin() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return 0;

    try {
      final todayWAT = _watDateString();
      final userRef  = FirebaseFirestore.instance.collection('users').doc(uid);
      final snap     = await userRef.get();

      final lastLogin = (snap.data() ?? {})['lastLoginDate'] as String?;
      if (lastLogin == todayWAT) return 0;

      await FirestoreService.instance.updateAnimeCoins(5, 'earn_daily');
      await userRef.update({'lastLoginDate': todayWAT});
      return 5;
    } catch (e) {
      debugPrint('[UserDataProvider] checkAndAwardDailyLogin error (ignored): $e');
      return 0;
    }
  }

  // ── Referral Bonus ───────────────────────────────────────────────────────────
  Future<void> claimReferralBonusIfEligible() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      final userRef = FirebaseFirestore.instance.collection('users').doc(uid);
      final snap    = await userRef.get();
      final data    = snap.data() ?? {};

      final alreadyClaimed = data['referralBonusClaimed'] as bool? ?? false;
      final firstQuizDone  = data['firstQuizCompleted']   as bool? ?? false;
      final referredBy     = data['referredBy']            as String?;

      if (alreadyClaimed || firstQuizDone || referredBy == null) return;

      await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('claimReferralBonus')
          .call<void>({'referredBy': referredBy});

      debugPrint('[UserDataProvider] claimReferralBonus callable succeeded for referrer $referredBy');
    } catch (e) {
      debugPrint('[UserDataProvider] claimReferralBonusIfEligible error (ignored): $e');
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  static String _watDateString() {
    final wat = DateTime.now().toUtc().add(const Duration(hours: 1));
    final m   = wat.month.toString().padLeft(2, '0');
    final d   = wat.day.toString().padLeft(2, '0');
    return '${wat.year}-$m-$d';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ADD TO FirestoreService (firestore_service.dart):
//
// ── P-04 ──────────────────────────────────────────────────────────────────────
//   Stream<int> dailyAdWatchedStream() {
//     final uid = FirebaseAuth.instance.currentUser!.uid;
//     return FirebaseFirestore.instance
//         .collection('users')
//         .doc(uid)
//         .snapshots()
//         .map((snap) {
//           final data = snap.data() ?? {};
//           // Reset check: if lastAdWatchDate is a prior WAT day, count is 0.
//           final lastWatchTs = data['lastAdWatchDate'] as Timestamp?;
//           if (lastWatchTs == null) return 0;
//           final lastWatDate = lastWatchTs.toDate().toUtc().add(const Duration(hours: 1));
//           final now         = DateTime.now().toUtc().add(const Duration(hours: 1));
//           final sameDay     = lastWatDate.year  == now.year  &&
//                               lastWatDate.month == now.month &&
//                               lastWatDate.day   == now.day;
//           if (!sameDay) return 0;
//           return (data['dailyAdWatched'] as int?) ?? 0;
//         });
//   }
//
// ── P-05 ──────────────────────────────────────────────────────────────────────
//   Stream<bool> premiumActiveStream() {
//     final uid = FirebaseAuth.instance.currentUser!.uid;
//     return FirebaseFirestore.instance
//         .collection('users')
//         .doc(uid)
//         .snapshots()
//         .map((snap) => (snap.data() ?? {})['premiumActive'] as bool? ?? false);
//   }
// ─────────────────────────────────────────────────────────────────────────────