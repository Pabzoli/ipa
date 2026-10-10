import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../services/firestore_service.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../widgets/insufficient_coins_sheet.dart'; // for InsufficientCoinsException

// =============================================================================
// Quick Match runs 24/7 on a daily token budget (free 5/day, premium 8/day,
// +1 via rewarded ad, resetting at WAT midnight). The old WAT time-window
// schedule was removed with the ghost-only matchmaking change — tokens are
// the only gate, enforced server-side in functions/index.js.
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

  // ── P-05: Premium status ──────────────────────────────────────────────────
  bool _premiumActive           = false;

  // ── Challenge daily counter ───────────────────────────────────────────────
  int  _challengesCreatedToday  = 0;

  // ── P-05: Session quiz counter ────────────────────────────────────────────
  int  _sessionQuizCount        = 0;

  // ── Quick Match token state ───────────────────────────────────────────────
  int  _qmTokens                = 0;
  bool _qmAdTokenUsed           = false;

  // ── Cooldown Skip Counter ────────────────────────────────────────────────
  int  _cooldownSkipsToday       = 0;

  // ── Daily Challenge state ─────────────────────────────────────────────────
  // Streamed from users/{uid}.dailyChallengeUsed / dailyChallengeDate.
  // True when the user has already consumed their free Daily Challenge today
  // (WAT). Resets to false locally at WAT midnight (stream handles this).
  // Used by HomePage to toggle the DC badge appearance, and by
  // _startDailyChallenge to decide whether to prompt the 40 AC retry payment.
  bool _dailyChallengeUsedToday = false;

  // ── Coin reservation system ──────────────────────────────────────────────
  final Map<int, int> _pendingCoinReservations = <int, int>{};
  int _nextCoinReservationId = 0;

  // ── WP (WeebPoints) Fields ──────────────────────────────────────────────────
  int  _wpStakedToday           = 0;
  String _wpStakedDate          = '';
  DateTime? _lastRivalChallenge;
  String? _lastRivalUid;

  // ── Leaderboard entry eligibility (leaderboard_entry codes) ──────────────
  String? _leaderboardEntryWeekId;

  // ── Initialization Guard ─────────────────────────────────────────────────
  bool _isInitialized           = false;

  // ── Getters ──────────────────────────────────────────────────────────────────

  int  get score                    => _score;
  // Anime Coins getters with reservation awareness
  int get animeCoins => spendableAnimeCoins;
  int get committedAnimeCoins => _animeCoins;
  int get pendingAnimeCoins =>
      _pendingCoinReservations.values.fold(0, (sum, value) => sum + value);
  int get spendableAnimeCoins {
    final value = _animeCoins - pendingAnimeCoins;
    return value < 0 ? 0 : value;
  }
  bool canAffordCoins(int amount) => spendableAnimeCoins >= amount;

  int  get weeklyPoints             => _weeklyPoints;
  int  get dailyAdWatched           => _dailyAdWatched;
  int  get adsRemainingToday        => (10 - _dailyAdWatched).clamp(0, 10);
  bool get loading                  => _loading;
  bool get isOnline                 => _isOnline;
  bool get connectivityChecked      => _connectivityChecked;
  bool get premiumActive            => _premiumActive;
  int  get challengesCreatedToday   => _challengesCreatedToday;
  int  get sessionQuizCount         => _sessionQuizCount;
  int  get qmTokens                 => _qmTokens;
  bool get qmAdTokenUsed            => _qmAdTokenUsed;
  int  get cooldownSkipsToday       => _cooldownSkipsToday;

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

  // ── WP Getters ───────────────────────────────────────────────────────────────

  int get wpStakedToday => _wpStakedToday;
  String get wpStakedDate => _wpStakedDate;
  DateTime? get lastRivalChallenge => _lastRivalChallenge;
  String? get lastRivalUid => _lastRivalUid;

  // ── Leaderboard entry getters ──────────────────────────────────────────────
  String? get leaderboardEntryWeekId => _leaderboardEntryWeekId;

  /// Whether the user has an active leaderboard entry for the CURRENT weekly
  /// cycle. Stored week is intentionally left stale after reset (Decision D);
  /// this comparison naturally turns false when the Monday boundary advances.
  bool get isLeaderboardEligible =>
      _leaderboardEntryWeekId == FirestoreService.currentWeekId();

  /// Checks if the current user can challenge a specific rival.
  /// 
  /// Cooldown rules:
  /// - Different rival: always allowed (no cooldown)
  /// - Same rival: 12-hour cooldown (6 hours for premium users)
  bool canChallengeRival(String rivalUid) {
    if (_lastRivalUid != rivalUid) return true; // different rival, no cooldown
    if (_lastRivalChallenge == null) return true;
    final hours = DateTime.now().difference(_lastRivalChallenge!).inHours;
    final cooldown = _premiumActive ? 6 : 12;
    return hours >= cooldown;
  }

  /// Returns the remaining cooldown hours for a specific rival, or 0 if no cooldown.
  int getRivalCooldownHours(String rivalUid) {
    if (_lastRivalUid != rivalUid) return 0;
    if (_lastRivalChallenge == null) return 0;
    final hours = DateTime.now().difference(_lastRivalChallenge!).inHours;
    final cooldown = _premiumActive ? 6 : 12;
    final remaining = cooldown - hours;
    return remaining > 0 ? remaining : 0;
  }

  // ── Stream Subscriptions ────────────────────────────────────────────────────

  StreamSubscription<List<ConnectivityResult>>? _connectSub;
  StreamSubscription<User?>?                    _authSub;
  StreamSubscription<int>?                      _scoreSub;
  StreamSubscription<int>?                      _animeCoinsSub;
  StreamSubscription<int>?                      _weeklyPointsSub;
  StreamSubscription<int>?                      _dailyAdWatchedSub;
  StreamSubscription<bool>?                     _premiumActiveSub;
  StreamSubscription<int>?                      _challengesCreatedTodaySub;
  StreamSubscription<int>?                      _qmTokensSub;
  StreamSubscription<bool>?                     _qmAdTokenUsedSub;
  StreamSubscription<int>?                      _cooldownSkipsTodaySub;
  StreamSubscription<bool>?                     _dailyChallengeUsedSub;
  
  // ── WP Stream Subscriptions ─────────────────────────────────────────────────
  StreamSubscription<int>?                      _wpStakedTodaySub;
  StreamSubscription<String>?                   _wpStakedDateSub;
  StreamSubscription<Timestamp?>?               _lastRivalChallengeSub;
  StreamSubscription<String?>?                  _lastRivalUidSub;
  StreamSubscription<String?>?                  _leaderboardEntrySub;

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
    _premiumActive           = false;
    _challengesCreatedToday  = 0;
    _qmTokens                = 0;
    _qmAdTokenUsed           = false;
    _cooldownSkipsToday      = 0;
    _dailyChallengeUsedToday = false;
    
    // Reset WP fields
    _wpStakedToday           = 0;
    _wpStakedDate            = '';
    _lastRivalChallenge      = null;
    _lastRivalUid            = null;
    _leaderboardEntryWeekId  = null;
    
    // Reset coin reservations
    _pendingCoinReservations.clear();
    _nextCoinReservationId = 0;

    _loading                 = true;
  }

  void _cancelFirestoreStreams() {
    _scoreSub?.cancel();                   _scoreSub                   = null;
    _animeCoinsSub?.cancel();              _animeCoinsSub              = null;
    _weeklyPointsSub?.cancel();            _weeklyPointsSub            = null;
    _dailyAdWatchedSub?.cancel();          _dailyAdWatchedSub          = null;
    _premiumActiveSub?.cancel();           _premiumActiveSub           = null;
    _challengesCreatedTodaySub?.cancel();  _challengesCreatedTodaySub  = null;
    _qmTokensSub?.cancel();                _qmTokensSub                = null;
    _qmAdTokenUsedSub?.cancel();           _qmAdTokenUsedSub           = null;
    _cooldownSkipsTodaySub?.cancel();      _cooldownSkipsTodaySub      = null;
    _dailyChallengeUsedSub?.cancel();      _dailyChallengeUsedSub      = null;
    
    // Cancel WP subscriptions
    _wpStakedTodaySub?.cancel();           _wpStakedTodaySub           = null;
    _wpStakedDateSub?.cancel();            _wpStakedDateSub            = null;
    _lastRivalChallengeSub?.cancel();      _lastRivalChallengeSub      = null;
    _lastRivalUidSub?.cancel();            _lastRivalUidSub            = null;
    _leaderboardEntrySub?.cancel();        _leaderboardEntrySub        = null;
  }

  void _startFirestoreStreams() {
    _cancelFirestoreStreams();

    // One-time migrations — fire-and-forget.
    FirestoreService.instance.runMigrationIfNeeded().catchError((e) {
      debugPrint('[UserDataProvider] migration error (ignored): $e');
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
    FirestoreService.instance.ensureCooldownSkipsFields().catchError((e) {
      debugPrint('[UserDataProvider] ensureCooldownSkipsFields error (ignored): $e');
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

    // ── Cooldown Skips Today ──────────────────────────────────────────────────
    _cooldownSkipsTodaySub =
        FirestoreService.instance.cooldownSkipsTodayStream().listen(
      (count) {
        _cooldownSkipsToday = count;
        notifyListeners();
      },
      onError: (e) {
        debugPrint('[UserDataProvider] cooldownSkipsToday stream error (ignored): $e');
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

    // ── WP Staked Today ──────────────────────────────────────────────────────
    _wpStakedTodaySub = FirestoreService.instance.wpStakedTodayStream().listen(
      (count) {
        _wpStakedToday = count;
        notifyListeners();
      },
      onError: (e) {
        debugPrint('[UserDataProvider] wpStakedToday stream error (ignored): $e');
      },
    );

    // ── WP Staked Date ──────────────────────────────────────────────────────
    _wpStakedDateSub = FirestoreService.instance.wpStakedDateStream().listen(
      (date) {
        _wpStakedDate = date;
        notifyListeners();
      },
      onError: (e) {
        debugPrint('[UserDataProvider] wpStakedDate stream error (ignored): $e');
      },
    );

    // ── Last Rival Challenge ──────────────────────────────────────────────────
    _lastRivalChallengeSub = 
        FirestoreService.instance.lastRivalChallengeStream().listen(
      (ts) {
        _lastRivalChallenge = ts?.toDate();
        notifyListeners();
      },
      onError: (e) {
        debugPrint('[UserDataProvider] lastRivalChallenge stream error (ignored): $e');
      },
    );

    // ── Last Rival UID ─────────────────────────────────────────────────────────
    _lastRivalUidSub = FirestoreService.instance.lastRivalUidStream().listen(
      (uid) {
        _lastRivalUid = uid;
        notifyListeners();
      },
      onError: (e) {
        debugPrint('[UserDataProvider] lastRivalUid stream error (ignored): $e');
      },
    );

    // ── Leaderboard Entry Week ───────────────────────────────────────────────
    _leaderboardEntrySub =
        FirestoreService.instance.leaderboardEntryStream().listen(
      (weekId) {
        _leaderboardEntryWeekId = weekId;
        notifyListeners();
      },
      onError: (e) {
        debugPrint('[UserDataProvider] leaderboardEntry stream error (ignored): $e');
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

  // ── Reservation‑based coin spending ────────────────────────────────────────

  int reserveCoins(int amount) {
    if (!canAffordCoins(amount)) {
      throw InsufficientCoinsException(
        required: amount,
        available: spendableAnimeCoins,
      );
    }

    final id = ++_nextCoinReservationId;
    _pendingCoinReservations[id] = amount;
    notifyListeners();
    return id;
  }

  void rollbackReservedCoinSpend(int reservationId) {
    if (_pendingCoinReservations.remove(reservationId) != null) {
      notifyListeners();
    }
  }

  Future<int> commitReservedCoinSpend(int reservationId, String type) async {
    final amount = _pendingCoinReservations[reservationId];
    if (amount == null) {
      throw StateError('reservation_not_found');
    }

    try {
      final result = await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('spendCoins')
          .call(<String, dynamic>{
        'amount': amount,
        'type': type,
      });

      final data = Map<String, dynamic>.from(result.data as Map);

      if (data['success'] != true) {
        rollbackReservedCoinSpend(reservationId);

        if (data['error'] == 'insufficient_coins') {
          throw InsufficientCoinsException(
            required: amount,
            available: (data['balance'] as num?)?.toInt() ?? spendableAnimeCoins,
          );
        }

        throw Exception('spendCoins failed: ${data['error']}');
      }

      _pendingCoinReservations.remove(reservationId);
      _animeCoins = (data['newBalance'] as num).toInt();
      notifyListeners();
      return _animeCoins;
    } on FirebaseFunctionsException catch (e) {
      rollbackReservedCoinSpend(reservationId);

      final insufficient = e.code == 'resource-exhausted' ||
          (e.message ?? '').contains('insufficient_coins');

      if (insufficient) {
        throw InsufficientCoinsException(
          required: amount,
          available: spendableAnimeCoins,
        );
      }

      debugPrint(
        '[UserDataProvider] commitReservedCoinSpend CF error: ${e.code} ${e.message}',
      );
      rethrow;
    } catch (_) {
      rollbackReservedCoinSpend(reservationId);
      rethrow;
    }
  }

  /// Simple spend wrapper using the reservation system.
  Future<void> spendCoins(int amount, String type) async {
    final reservationId = reserveCoins(amount);
    await commitReservedCoinSpend(reservationId, type);
  }

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