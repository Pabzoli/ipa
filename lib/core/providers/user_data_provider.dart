import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../services/firestore_service.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../widgets/insufficient_coins_sheet.dart'; // for InsufficientCoinsException

// =============================================================================
// ── Quick Match Window Schedule ────────────────────────────────────────────────
// =============================================================================

/// Describes a single named Quick Match availability window.
class QMWindow {
  final String name;     // 'Morning Rush', 'Afternoon', 'Night Battle'
  final int    startUTC; // window open hour in UTC (inclusive)
  final int    endUTC;   // window close hour in UTC (exclusive)

  const QMWindow(this.name, this.startUTC, this.endUTC);
}

/// Utility for client-side window checks and countdown display.
///
/// All three windows run in WAT (UTC+1):
///   Morning Rush  07:00–10:00 WAT  →  06:00–09:00 UTC
///   Afternoon     13:00–16:00 WAT  →  12:00–15:00 UTC
///   Night Battle  19:00–23:00 WAT  →  18:00–22:00 UTC
class QMWindowSchedule {
  static const List<QMWindow> windows = [
    QMWindow('Morning Rush',  6,  9),  // WAT 07:00–10:00
    QMWindow('Afternoon',    12, 15),  // WAT 13:00–16:00
    QMWindow('Night Battle', 18, 22),  // WAT 19:00–23:00
  ];

  /// Returns the currently active window, or null if outside all windows.
  static QMWindow? currentWindow() {
    final nowUTC = DateTime.now().toUtc();
    for (final w in windows) {
      if (nowUTC.hour >= w.startUTC && nowUTC.hour < w.endUTC) return w;
    }
    return null;
  }

  /// Returns the DateTime (UTC) when the next window opens.
  /// If all windows have passed today, returns tomorrow's first window start.
  static DateTime nextWindowStart() {
    final nowUTC = DateTime.now().toUtc();
    for (final w in windows) {
      final start = DateTime.utc(
        nowUTC.year, nowUTC.month, nowUTC.day, w.startUTC,
      );
      if (start.isAfter(nowUTC)) return start;
    }
    // All windows have passed for today — return tomorrow's first window.
    final tomorrow = DateTime.utc(nowUTC.year, nowUTC.month, nowUTC.day + 1);
    return DateTime.utc(
      tomorrow.year, tomorrow.month, tomorrow.day, windows.first.startUTC,
    );
  }
}

// =============================================================================

///
/// [coinsAwarded] is the daily login bonus (20 AC, or 0 if already claimed today).
/// [wpAwarded]    is the streak-WP milestone bonus (0 if no milestone reached).
/// [wpMilestone]  is the streak day-count that triggered the WP award (0 if none).
class DailyLoginResult {
  final int coinsAwarded;
  final int wpAwarded;
  final int wpMilestone;

  const DailyLoginResult({
    required this.coinsAwarded,
    required this.wpAwarded,
    required this.wpMilestone,
  });

  /// Convenience: true when a streak-WP milestone was awarded.
  bool get hasStreakWPBonus => wpAwarded > 0;

  @override
  String toString() =>
      'DailyLoginResult(coins=$coinsAwarded, wp=$wpAwarded, milestone=$wpMilestone)';
}

class UserDataProvider extends ChangeNotifier {
  // ── Defaults are 0 / false, NOT fake values.
  // The streams replace these with real Firestore values as soon as
  // the user is authenticated and online.
  int  _score                   = 0;
  int  _animeCoins              = 0;
  int  _weeklyPoints            = 0;
  int  _dailyAdWatched          = 0;
  bool _loading                 = true;
  bool _isOnline                = false;
  bool _connectivityChecked     = false;

  // ── Streak Shield ─────────────────────────────────────────────────────────
  bool _streakShieldActive      = false;

  // ── P-05: Premium status ──────────────────────────────────────────────────
  bool _premiumActive           = false;

  // ── Challenge daily counter ───────────────────────────────────────────────
  int  _challengesCreatedToday  = 0;

  // ── P-05: Session quiz counter ────────────────────────────────────────────
  int  _sessionQuizCount        = 0;

  // ── Quick Match token state ───────────────────────────────────────────────
  int  _qmTokens                = 0;
  bool _qmAdTokenUsed           = false;

  // ── Daily Challenge state ─────────────────────────────────────────────────
  // Streamed from users/{uid}.dailyChallengeUsed / dailyChallengeDate.
  // True when the user has already consumed their free Daily Challenge today
  // (WAT). Resets to false locally at WAT midnight (stream handles this).
  // Used by HomePage to toggle the DC badge appearance, and by
  // _startDailyChallenge to decide whether to prompt the 40 AC retry payment.
  bool _dailyChallengeUsedToday = false;

  // ── Initialization Guard ─────────────────────────────────────────────────
  bool _isInitialized           = false;

  int  get score                    => _score;
  int  get animeCoins               => _animeCoins;
  int  get weeklyPoints             => _weeklyPoints;
  int  get dailyAdWatched           => _dailyAdWatched;
  int  get adsRemainingToday        => (10 - _dailyAdWatched).clamp(0, 10);
  bool get loading                  => _loading;
  bool get isOnline                 => _isOnline;
  bool get connectivityChecked      => _connectivityChecked;
  bool get streakShieldActive       => _streakShieldActive;
  bool get premiumActive            => _premiumActive;
  int  get challengesCreatedToday   => _challengesCreatedToday;
  int  get sessionQuizCount         => _sessionQuizCount;
  int  get qmTokens                 => _qmTokens;
  bool get qmAdTokenUsed            => _qmAdTokenUsed;

  /// Whether the signed-in user has already used their free Daily Challenge
  /// today (WAT timezone). Sourced from users/{uid} via Firestore stream.
  ///
  /// `false` (not yet used) when:
  ///   • Field is absent (new account or fresh install).
  ///   • The stored [dailyChallengeDate] is from a prior WAT day.
  ///   • [dailyChallengeUsed] is false.
  ///
  /// Used by [HomePage._DailyChallengeButton] to show "Used" vs "Available"
  /// states, and by [_startDailyChallenge] to decide whether to prompt the
  /// 40 AC second-attempt payment.
  bool get dailyChallengeUsedToday  => _dailyChallengeUsedToday;

  StreamSubscription<List<ConnectivityResult>>? _connectSub;
  StreamSubscription<User?>?                    _authSub;
  StreamSubscription<int>?                      _scoreSub;
  StreamSubscription<int>?                      _animeCoinsSub;
  StreamSubscription<int>?                      _weeklyPointsSub;
  StreamSubscription<bool>?                     _shieldSub;
  StreamSubscription<int>?                      _dailyAdWatchedSub;
  StreamSubscription<bool>?                     _premiumActiveSub;
  StreamSubscription<int>?                      _challengesCreatedTodaySub;
  StreamSubscription<int>?                      _qmTokensSub;
  StreamSubscription<bool>?                     _qmAdTokenUsedSub;
  StreamSubscription<bool>?                     _dailyChallengeUsedSub;  // ← DC

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
    _score                   = 0;
    _animeCoins              = 0;
    _weeklyPoints            = 0;
    _dailyAdWatched          = 0;
    _streakShieldActive      = false;
    _premiumActive           = false;
    _challengesCreatedToday  = 0;
    _qmTokens                = 0;
    _qmAdTokenUsed           = false;
    _dailyChallengeUsedToday = false;  // ← DC: reset on sign-out
    // _sessionQuizCount is intentionally NOT reset here — it survives
    // sign-out within the same app session.
    _loading                 = true;
  }

  void _cancelFirestoreStreams() {
    _scoreSub?.cancel();                   _scoreSub                   = null;
    _animeCoinsSub?.cancel();              _animeCoinsSub              = null;
    _weeklyPointsSub?.cancel();            _weeklyPointsSub            = null;
    _shieldSub?.cancel();                  _shieldSub                  = null;
    _dailyAdWatchedSub?.cancel();          _dailyAdWatchedSub          = null;
    _premiumActiveSub?.cancel();           _premiumActiveSub           = null;
    _challengesCreatedTodaySub?.cancel();  _challengesCreatedTodaySub  = null;
    _qmTokensSub?.cancel();                _qmTokensSub                = null;
    _qmAdTokenUsedSub?.cancel();           _qmAdTokenUsedSub           = null;
    _dailyChallengeUsedSub?.cancel();      _dailyChallengeUsedSub      = null; // ← DC
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
    FirestoreService.instance.ensureChallengesCreatedTodayField().catchError((e) {
      debugPrint('[UserDataProvider] ensureChallengesCreatedTodayField error (ignored): $e');
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
    _dailyAdWatchedSub = FirestoreService.instance.dailyAdWatchedStream().listen(
      (count) {
        _dailyAdWatched = count;
        notifyListeners();
      },
      onError: (e) {
        debugPrint('[UserDataProvider] dailyAdWatched stream error (ignored): $e');
      },
    );

    // ── Premium Active (P-05) ─────────────────────────────────────────────────
    _premiumActiveSub = FirestoreService.instance.premiumActiveStream().listen(
      (active) {
        _premiumActive = active;
        notifyListeners();
      },
      onError: (e) {
        debugPrint('[UserDataProvider] premiumActive stream error (ignored): $e');
      },
    );

    // ── Challenges Created Today ──────────────────────────────────────────────
    _challengesCreatedTodaySub =
        FirestoreService.instance.challengesCreatedTodayStream().listen(
      (count) {
        _challengesCreatedToday = count;
        notifyListeners();
      },
      onError: (e) {
        debugPrint(
          '[UserDataProvider] challengesCreatedToday stream error (ignored): $e',
        );
      },
    );

    // ── Quick Match Tokens ────────────────────────────────────────────────────
    _qmTokensSub = FirestoreService.instance.qmTokensStream().listen(
      (tokens) {
        _qmTokens = tokens;
        notifyListeners();
      },
      onError: (e) {
        debugPrint('[UserDataProvider] qmTokens stream error (ignored): $e');
      },
    );

    // ── Quick Match Ad Token Used ─────────────────────────────────────────────
    _qmAdTokenUsedSub = FirestoreService.instance.qmAdTokenUsedStream().listen(
      (used) {
        _qmAdTokenUsed = used;
        notifyListeners();
      },
      onError: (e) {
        debugPrint('[UserDataProvider] qmAdTokenUsed stream error (ignored): $e');
      },
    );

    // ── Daily Challenge Used Today ────────────────────────────────────────────
    // Watches users/{uid}.dailyChallengeDate + dailyChallengeUsed to keep the
    // DC badge in sync with whether the free attempt has been consumed today
    // (WAT timezone). Emits true once markDailyChallengeUsed() is called by
    // the quiz controller, and resets to false at the WAT midnight boundary
    // without requiring a server write (the stream performs the date comparison
    // locally, same pattern as dailyAdWatchedStream).
    _dailyChallengeUsedSub =
        FirestoreService.instance.dailyChallengeUsedTodayStream().listen(
      (used) {
        _dailyChallengeUsedToday = used;
        notifyListeners();
      },
      onError: (e) {
        debugPrint('[UserDataProvider] dailyChallengeUsed stream error (ignored): $e');
        // Non-fatal — defaults to false (shows DC as available), which is the
        // safer direction: worst case the user sees the DC button enabled when
        // it has already been used (the CF enforces the actual 1.5× grant, so
        // they won't get a second free bonus).
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

  Future<void> awardCoins(int amount, String type) =>
      FirestoreService.instance.updateAnimeCoins(amount, type);

  Future<void> spendCoins(int amount, String type) async {
    try {
      final result = await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('spendCoins')
          .call<Map<Object?, Object?>>({'amount': amount, 'type': type});

      final data = Map<String, dynamic>.from(result.data);

      if (data['success'] != true) {
        if (data['error'] == 'insufficient_coins') {
          throw InsufficientCoinsException(
            required:  amount,
            available: _animeCoins,
          );
        }
        throw Exception('spendCoins failed: ${data['error']}');
      }

      // Sync local cache immediately so the UI doesn't wait for the stream.
      _animeCoins = (data['newBalance'] as num).toInt();
      notifyListeners();
    } on FirebaseFunctionsException catch (e) {
      debugPrint('[UserDataProvider] spendCoins CF error: ${e.code} ${e.message}');
      rethrow;
    }
  }

  Future<void> setStreakShieldActive(bool value) =>
      FirestoreService.instance.setStreakShieldActive(value);

  // ── P-05: Session quiz counter ────────────────────────────────────────────
  void incrementSessionQuizCount() {
    _sessionQuizCount++;
    // No notifyListeners() — no widget reads this value for display.
  }

  // ── Daily Login Bonus (+20 AC) + Streak WP Milestones ───────────────────────
  Future<DailyLoginResult> checkAndAwardDailyLogin() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return const DailyLoginResult(coinsAwarded: 0, wpAwarded: 0, wpMilestone: 0);
    }

    try {
      final loginResult = await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('recordDailyLogin')
          .call<Map<Object?, Object?>>({});

      final loginData    = Map<String, dynamic>.from(loginResult.data);
      final coinsAwarded = (loginData['coinsAwarded'] as num).toInt();

      if (coinsAwarded == 0) {
        return const DailyLoginResult(coinsAwarded: 0, wpAwarded: 0, wpMilestone: 0);
      }

      int wpAwarded   = 0;
      int wpMilestone = 0;
      try {
        final cfResult = await FirebaseFunctions.instanceFor(region: 'us-central1')
            .httpsCallable('awardLoginStreakWP')
            .call<Map<Object?, Object?>>({});

        final data = Map<String, dynamic>.from(cfResult.data);
        if (data['awarded'] == true) {
          wpAwarded   = (data['wpAwarded']  as num).toInt();
          wpMilestone = (data['milestone']  as num).toInt();
          debugPrint(
            '[UserDataProvider] awardLoginStreakWP: '
            '+$wpAwarded WP (milestone $wpMilestone)',
          );
        }
      } catch (cfError) {
        debugPrint(
          '[UserDataProvider] awardLoginStreakWP CF error (ignored): $cfError',
        );
      }

      return DailyLoginResult(
        coinsAwarded: coinsAwarded,
        wpAwarded:    wpAwarded,
        wpMilestone:  wpMilestone,
      );
    } catch (e) {
      debugPrint('[UserDataProvider] checkAndAwardDailyLogin error (ignored): $e');
      return const DailyLoginResult(coinsAwarded: 0, wpAwarded: 0, wpMilestone: 0);
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