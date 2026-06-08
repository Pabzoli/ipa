import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../features/quiz/questions.dart';
import '../../features/multiplayer/challenge_model.dart';

// ─── Exceptions ───────────────────────────────────────────────────────────────

/// Thrown by [FirestoreService.updateAnimeCoins] when a spend would push the
/// balance below zero. Carry [required] and [available] so the UI can render
/// a precise "you need X more coins" message without doing maths itself.
class InsufficientCoinsException implements Exception {
  final int required;
  final int available;

  const InsufficientCoinsException({
    required this.required,
    required this.available,
  });

  @override
  String toString() =>
      'InsufficientCoinsException: need ${required.abs()} coins, '
      'only $available available.';
}

// ─── University Constants ─────────────────────────────────────────────────────

/// Canonical list used in signup dropdown and campus leaderboard queries.
const List<String> kNigerianUniversities = [
  'UNILAG',
  'UI (University of Ibadan)',
  'OAU',
  'FUTA',
  'UNIABUJA',
  'UNIBEN',
  'ABU Zaria',
  'UNIPORT',
  'NOUN',
  'Other',
];

// ─── Lightweight Models ───────────────────────────────────────────────────────

/// Returned by [FirestoreService.getTopUniversities].
class UniversityTotal {
  final String university;
  final int    total;
  const UniversityTotal({required this.university, required this.total});
}

/// A single winner entry from a [prize_pool] document's `winners` array.
class PrizeWinner {
  final String uid;
  final String username;
  final int    rank;
  final double prizeAmount;
  final String university;

  const PrizeWinner({
    required this.uid,
    required this.username,
    required this.rank,
    required this.prizeAmount,
    required this.university,
  });

  factory PrizeWinner.fromMap(Map<String, dynamic> map) => PrizeWinner(
        uid:         (map['uid']       as String?) ?? '',
        username:    (map['username']  as String?) ?? 'Anonymous',
        rank:        ((map['rank']     as num?)?.toInt()) ?? 0,
        prizeAmount: ((map['prize']    as num?)?.toDouble()) ?? 0.0,
        university:  (map['university'] as String?) ?? '',
      );
}

/// The payload returned by [FirestoreService.getLastWeekWinners].
///
/// [weekId] is the Monday date string of the completed week, e.g. "2025-05-19".
/// [winners] is sorted ascending by rank (1st → last).
class LastWeekResult {
  final String            weekId;
  final double            totalNaira;
  final List<PrizeWinner> winners;

  const LastWeekResult({
    required this.weekId,
    required this.totalNaira,
    required this.winners,
  });
}

// ─── Firestore Service ────────────────────────────────────────────────────────

class FirestoreService {
  FirestoreService._();
  static final FirestoreService instance = FirestoreService._();

  final _db   = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  String? get _uid       => _auth.currentUser?.uid;
  String? get currentUid => _uid;

  DocumentReference<Map<String, dynamic>> get _userDoc =>
      _db.collection('users').doc(_uid);

  // ─── WAT date helper ──────────────────────────────────────────────────────

  /// Returns today's date in WAT (UTC+1) as 'YYYY-MM-DD'.
  static String _watDateString() {
    final wat = DateTime.now().toUtc().add(const Duration(hours: 1));
    final m   = wat.month.toString().padLeft(2, '0');
    final d   = wat.day.toString().padLeft(2, '0');
    return '${wat.year}-$m-$d';
  }

  // ─── Score ──────────────────────────────────────────────────────────────────

  Stream<int> scoreStream() {
    if (_uid == null) return Stream.value(0);
    return _userDoc.snapshots().map(
      (s) => (s.data()?['totalScore'] as int?) ?? 0,
    );
  }

  Future<void> addToScore(int amount) async {
    if (_uid == null) return;
    await _userDoc.update({'totalScore': FieldValue.increment(amount)});
  }

  Future<void> subtractFromScore(int amount) async {
    if (_uid == null) return;
    await _userDoc.update({'totalScore': FieldValue.increment(-amount)});
  }

  // ─── Anime Coins ─────────────────────────────────────────────────────────────

  /// Live stream of the current user's [animeCoins] balance.
  Stream<int> animeCoinsStream() {
    if (_uid == null) return Stream.value(0);
    return _userDoc.snapshots().map(
      (s) => (s.data()?['animeCoins'] as int?) ?? 0,
    );
  }

  /// Atomically adjusts [animeCoins] by [delta] (positive = earn, negative = spend)
  /// and appends an immutable entry to the [coinTransactions] subcollection.
  ///
  /// [type] must match the coinTransactions schema:
  ///   'earn_daily' | 'earn_quiz' | 'earn_ad' | 'earn_referral' |
  ///   'spend_hint' | 'spend_cooldown' | 'spend_unlock' |
  ///   'spend_shield' | 'spend_timer' | 'spend_retry' | 'iap'
  ///
  /// Throws [InsufficientCoinsException] if the resulting balance would be < 0.
  ///
  /// ⛔ DEAD PATH — animeCoins is blacklisted for direct client writes in
  /// Firestore security rules. All coin mutations go through Cloud Functions
  /// (submitQuizAnswers, spendCoins, recordAdWatch, etc.).  Calling this
  /// method will always result in a Firestore Permission-Denied error.
  /// Kept here to surface the call site clearly; throws immediately so any
  /// accidental call fails fast and loudly.
  @Deprecated(
    'animeCoins is server-only. Use the appropriate Cloud Function instead.',
  )
  Future<void> updateAnimeCoins(int delta, String type) async {
    throw UnsupportedError(
      'updateAnimeCoins() is disabled: animeCoins is a server-only field '
      'protected by Firestore security rules. '
      'Use the spendCoins / submitQuizAnswers / recordAdWatch CF instead.',
    );
  }

  // ─── One-time migration: hintCount → animeCoins ───────────────────────────

  /// Converts any legacy [hintCount] field into [animeCoins] (× 2 exchange rate)
  /// and deletes the old field — all in a single atomic transaction.
  Future<void> runMigrationIfNeeded() async {
    if (_uid == null) return;
    try {
      await _db.runTransaction((tx) async {
        final snap = await tx.get(_userDoc);
        final data = snap.data();
        if (data == null || !data.containsKey('hintCount')) return;

        final hintCount = (data['hintCount'] as int?) ?? 0;

        final animeCoins = data.containsKey('animeCoins')
            ? (data['animeCoins'] as int?) ?? 0
            : hintCount * 2;

        tx.update(_userDoc, {
          'animeCoins': animeCoins,
          'hintCount':  FieldValue.delete(),
        });
      });
    } catch (e) {
      debugPrint('[FirestoreService] migration error (ignored): $e');
    }
  }

  // ─── Streak Shield fields (additive patch) ────────────────────────────────

  /// Adds [streakShieldActive] and [lastStreakShieldUsed] to docs that predate
  /// the field. No-ops on accounts that already have both fields.
  Future<void> ensureStreakShieldFields() async {
    if (_uid == null) return;
    try {
      final snap = await _userDoc.get();
      final data = snap.data();
      if (data == null) return;

      final updates = <String, dynamic>{};
      if (!data.containsKey('streakShieldActive')) {
        updates['streakShieldActive'] = false;
      }
      if (!data.containsKey('lastStreakShieldUsed')) {
        updates['lastStreakShieldUsed'] = null;
      }
      if (updates.isNotEmpty) await _userDoc.update(updates);
    } catch (e) {
      debugPrint('[FirestoreService] ensureStreakShieldFields error (ignored): $e');
    }
  }

  // ─── Anime Coins field patch (additive) ──────────────────────────────────

  /// Adds [animeCoins: 0] to docs that predate the field.
  /// No-ops on accounts that already have it.
  Future<void> ensureAnimeCoinField() async {
    if (_uid == null) return;
    try {
      final snap = await _userDoc.get();
      final data = snap.data();
      if (data == null) return;
      if (!data.containsKey('animeCoins')) {
        await _userDoc.update({'animeCoins': 0});
      }
    } catch (e) {
      debugPrint('[FirestoreService] ensureAnimeCoinField error (ignored): $e');
    }
  }

  // ─── Streak Shield stream + write ─────────────────────────────────────────

  /// Live stream of users/{uid}.streakShieldActive.
  Stream<bool> streakShieldStream() {
    if (_uid == null) return Stream.value(false);
    return _userDoc.snapshots().map(
      (s) => (s.data()?['streakShieldActive'] as bool?) ?? false,
    );
  }

  /// Writes [value] to users/{uid}.streakShieldActive.
  Future<void> setStreakShieldActive(bool value) async {
    if (_uid == null) return;
    await _userDoc.update({'streakShieldActive': value});
  }

  // ─── Daily Ad Watched stream (P-04) ──────────────────────────────────────

  /// Live stream of how many rewarded ads the signed-in user has watched today.
  Stream<int> dailyAdWatchedStream() {
    if (_uid == null) return Stream.value(0);
    return _userDoc.snapshots().map((snap) {
      final data = snap.data();
      if (data == null) return 0;

      final lastWatchTs = data['lastAdWatchDate'] as Timestamp?;
      if (lastWatchTs == null) return 0;

      final lastWAT = lastWatchTs.toDate().toUtc().add(const Duration(hours: 1));
      final nowWAT  = DateTime.now().toUtc().add(const Duration(hours: 1));
      final sameDay = lastWAT.year  == nowWAT.year  &&
                      lastWAT.month == nowWAT.month &&
                      lastWAT.day   == nowWAT.day;

      if (!sameDay) return 0;
      return (data['dailyAdWatched'] as int?) ?? 0;
    });
  }

  Future<void> ensureDailyAdWatchedFields() async {
    if (_uid == null) return;
    try {
      final snap = await _userDoc.get();
      final data = snap.data();
      if (data == null) return;

      final updates = <String, dynamic>{};
      if (!data.containsKey('dailyAdWatched')) {
        updates['dailyAdWatched'] = 0;
      }
      if (!data.containsKey('lastAdWatchDate')) {
        updates['lastAdWatchDate'] = null;
      }
      if (updates.isNotEmpty) await _userDoc.update(updates);
    } catch (e) {
      debugPrint('[FirestoreService] ensureDailyAdWatchedFields error (ignored): $e');
    }
  }

  // ─── Premium Active stream (P-05) ────────────────────────────────────────

  /// Live stream of users/{uid}.premiumActive.
  Stream<bool> premiumActiveStream() {
    if (_uid == null) return Stream.value(false);
    return _userDoc.snapshots().map(
      (s) => (s.data()?['premiumActive'] as bool?) ?? false,
    );
  }

  // ─── Challenges Created Today stream ─────────────────────────────────────

  Stream<int> challengesCreatedTodayStream() {
    if (_uid == null) return Stream.value(0);
    return _userDoc.snapshots().map((snap) {
      final data = snap.data();
      if (data == null) return 0;

      // CF writes challengesCreatedDate as a 'YYYY-MM-DD' String (WAT).
      final dateStr = data['challengesCreatedDate'] as String?;
      if (dateStr == null || dateStr != _watDateString()) return 0;
      return (data['challengesCreatedToday'] as int?) ?? 0;
    });
  }

  Future<void> ensureChallengesCreatedTodayField() async {
    if (_uid == null) return;
    try {
      final snap = await _userDoc.get();
      final data = snap.data();
      if (data == null) return;

      final updates = <String, dynamic>{};
      if (!data.containsKey('challengesCreatedToday')) {
        updates['challengesCreatedToday'] = 0;
      }
      if (!data.containsKey('challengesCreatedDate')) {
        updates['challengesCreatedDate'] = null;
      }
      if (updates.isNotEmpty) await _userDoc.update(updates);
    } catch (e) {
      debugPrint(
        '[FirestoreService] ensureChallengesCreatedTodayField error (ignored): $e',
      );
    }
  }

  // ─── Challenges Joined Today stream ──────────────────────────────────────

  /// Live stream emitting how many challenges the signed-in user has joined
  /// during the current WAT day.  Resets to 0 at the start of each new day
  /// (when [challengesJoinedDate] no longer matches today's WAT date string).
  ///
  /// Mirrors [challengesCreatedTodayStream] — the CF writes
  /// [challengesJoinedDate] as a 'YYYY-MM-DD' WAT string and increments
  /// [challengesJoinedToday] atomically on each successful join.
  Stream<int> challengesJoinedTodayStream() {
    if (_uid == null) return Stream.value(0);
    return _userDoc.snapshots().map((snap) {
      final data = snap.data();
      if (data == null) return 0;

      // CF writes challengesJoinedDate as a 'YYYY-MM-DD' String (WAT).
      final dateStr = data['challengesJoinedDate'] as String?;
      if (dateStr == null || dateStr != _watDateString()) return 0;
      return (data['challengesJoinedToday'] as int?) ?? 0;
    });
  }

  // ─── Quick Match token streams ────────────────────────────────────────────

  Stream<int> qmTokensStream() {
    if (_uid == null) return Stream.value(0);
    return _userDoc.snapshots().map(
      (s) => (s.data()?['qmTokens'] as int?) ?? 0,
    );
  }

  Stream<bool> qmAdTokenUsedStream() {
    if (_uid == null) return Stream.value(false);
    return _userDoc.snapshots().map(
      (s) => (s.data()?['qmAdTokenUsed'] as bool?) ?? false,
    );
  }

  // ─── Daily Challenge ──────────────────────────────────────────────────────
  //
  // Implements the "once per WAT day, 1.5× WP multiplier" feature.
  //
  // Firestore fields on users/{uid}:
  //   dailyChallengeDate : String?  — WAT date 'YYYY-MM-DD' of last use
  //   dailyChallengeUsed : bool     — whether used on [dailyChallengeDate]
  //
  // The client writes these fields directly after a successful CF submission.
  // The actual 1.5× multiplier is applied server-side in submitQuizAnswers CF
  // when the isDailyChallenge flag is present and true.

  /// Live stream emitting `true` when the signed-in user has already consumed
  /// their Daily Challenge for today (WAT), `false` otherwise.
  ///
  /// Emits `false` when:
  ///   • [dailyChallengeDate] is absent (new account / first open).
  ///   • [dailyChallengeDate] differs from today in WAT (new day — auto-reset).
  ///   • [dailyChallengeUsed] is false.
  ///   • The user is not authenticated.
  Stream<bool> dailyChallengeUsedTodayStream() {
    if (_uid == null) return Stream.value(false);
    return _userDoc.snapshots().map((snap) {
      final data = snap.data();
      if (data == null) return false;
      final dateStr = data['dailyChallengeDate'] as String?;
      if (dateStr == null) return false;
      if (dateStr != _watDateString()) return false; // new WAT day → not used
      return (data['dailyChallengeUsed'] as bool?) ?? false;
    });
  }

  /// Returns `true` if the signed-in user has NOT yet used their Daily
  /// Challenge today (WAT). Safe to call before the stream has emitted.
  ///
  /// Returns `true` for brand-new accounts and at the start of every new WAT day.
  Future<bool> isDailyChallengeAvailable() async {
    if (_uid == null) return false;
    final snap    = await _userDoc.get();
    final data    = snap.data();
    if (data == null) return true; // brand-new account
    final dateStr = data['dailyChallengeDate'] as String?;
    if (dateStr == null) return true;
    if (dateStr != _watDateString()) return true; // new WAT day
    return !((data['dailyChallengeUsed'] as bool?) ?? false);
  }

  /// No-op — retained so callers compile without changes.
  ///
  /// Both [dailyChallengeDate] and [dailyChallengeUsed] are blacklisted from
  /// direct client writes in Firestore security rules, so the previous
  /// implementation fired a guaranteed-to-fail write on every app launch for
  /// pre-DC accounts. Those fields are now populated by the [submitQuizAnswers]
  /// CF on the user's first Daily Challenge submission. The stream already
  /// handles absent fields correctly (returns false / "not used").
  Future<void> ensureDailyChallengeFields() async {}

  // ─── Early Anime Unlock ────────────────────────────────────────────────────

  /// Appends [animeTitle] to users/{uid}.unlockedAnimes (array-union so it is
  /// idempotent and safe to call more than once).
  Future<void> unlockAnimeEarly(String animeTitle) async {
    if (_uid == null) return;
    await _userDoc.update({
      'unlockedAnimes': FieldValue.arrayUnion([animeTitle]),
    });
  }

  // ─── Questions ──────────────────────────────────────────────────────────────

  Future<List<AnimeQuestion>> fetchQuestions() async {
    final snap = await _db
        .collection('questions')
        .get(const GetOptions(source: Source.server));

    if (snap.docs.isEmpty) {
      throw Exception(
        'No questions found. Please check your internet connection '
        'or make sure questions have been added to Firestore.',
      );
    }

    return snap.docs
        .map((doc) => AnimeQuestion.fromDoc(doc))
        .toList();
  }

  Future<List<AnimeQuestion>> fetchQuestionsForTitles(
      List<String> titles) async {
    if (titles.isEmpty) {
      throw Exception('No anime titles provided.');
    }

    // Use a server-side whereIn filter so we only download questions for the
    // requested titles — never the full collection.
    // Firestore whereIn supports up to 30 values, more than enough here.
    final snap = await _db
        .collection('questions')
        .where('animeTitle', whereIn: titles)
        .get(const GetOptions(source: Source.server));

    if (snap.docs.isEmpty) {
      throw Exception(
        'No questions found for the selected anime. '
        'More content is coming soon!',
      );
    }

    return snap.docs.map((doc) => AnimeQuestion.fromDoc(doc)).toList();
  }

  // ─── Anime Titles ────────────────────────────────────────────────────────────

  Future<List<String>> fetchAnimeTitles() async {
    try {
      final snap = await _db
          .collection('questions')
          .get(const GetOptions(source: Source.server));

      if (snap.docs.isEmpty) return [];

      final titles = snap.docs
          .map((d) => (d.data()['animeTitle'] as String?) ?? '')
          .where((t) => t.isNotEmpty)
          .toSet()
          .toList()
        ..sort();

      return titles;
    } catch (e) {
      throw Exception('Failed to load anime list: $e');
    }
  }

  // ─── Stats ──────────────────────────────────────────────────────────────────

  Future<void> updateStats(Map<String, dynamic> stats) async {
    if (_uid == null) return;
    await _userDoc.set({'stats': stats}, SetOptions(merge: true));
  }

  Future<Map<String, dynamic>> loadUserStats() async {
    if (_uid == null) return {};
    final doc = await _userDoc.get();
    return (doc.data()?['stats'] as Map<String, dynamic>?) ?? {};
  }

  // ─── Match History ───────────────────────────────────────────────────────────

  Future<void> saveMatchHistory({
    required String opponent,
    required int    playerScore,
    required int    opponentScore,
    required int    betScore,
    required String outcome,
  }) async {
    if (_uid == null) return;
    final int pointsChange;
    switch (outcome) {
      case 'win':
        pointsChange = betScore;
      case 'draw':
        pointsChange = 0;
      default:
        pointsChange = -betScore;
    }
    await _userDoc.collection('matches').add({
      'opponent':      opponent,
      'playerScore':   playerScore,
      'opponentScore': opponentScore,
      'betScore':      betScore,
      'outcome':       outcome,
      'pointsChange':  pointsChange,
      'timestamp':     FieldValue.serverTimestamp(),
    });
  }

  Stream<List<Map<String, dynamic>>> matchHistoryStream() {
    if (_uid == null) return Stream.value([]);
    return _userDoc
        .collection('matches')
        .orderBy('timestamp', descending: true)
        .limit(20)
        .snapshots()
        .map((snap) => snap.docs
            .map((doc) => {...doc.data(), 'id': doc.id})
            .toList());
  }

  // ─── Leaderboard ────────────────────────────────────────────────────────────

  Stream<List<Map<String, dynamic>>> leaderboardStream() {
    return _db
        .collection('users')
        .orderBy('totalScore', descending: true)
        .limit(100)
        .snapshots()
        .map((snap) {
      return snap.docs.asMap().entries.map((entry) {
        final data = entry.value.data();
        return {
          'rank':          entry.key + 1,
          'uid':           entry.value.id,
          'username':      (data['username']   as String?) ?? 'Anonymous',
          'totalScore':    (data['totalScore'] as int?)    ?? 0,
          'isCurrentUser': entry.value.id == _uid,
        };
      }).toList();
    });
  }

  Future<int> getCurrentUserRank() async {
    if (_uid == null) return -1;
    final myDoc   = await _userDoc.get();
    final myScore = (myDoc.data()?['totalScore'] as int?) ?? 0;

    final above = await _db
        .collection('users')
        .where('totalScore', isGreaterThan: myScore)
        .count()
        .get();

    return (above.count ?? 0) + 1;
  }

  // ─── Weekly Points ───────────────────────────────────────────────────────────

  Stream<int> weeklyPointsStream() {
    if (_uid == null) return Stream.value(0);
    return _userDoc.snapshots().map(
      (s) => (s.data()?['weeklyPoints'] as int?) ?? 0,
    );
  }

  /// ⛔ DEAD PATH — weeklyPoints is blacklisted for direct client writes in
  /// Firestore security rules. All WP awards are made server-side by
  /// submitQuizAnswers, submitQuickMatchResult, and resolveChallengeOutcome CFs.
  @Deprecated(
    'weeklyPoints is server-only. Awarded by Cloud Functions only.',
  )
  Future<void> addWeeklyPoints(int amount) async {
    throw UnsupportedError(
      'addWeeklyPoints() is disabled: weeklyPoints is a server-only field '
      'protected by Firestore security rules. '
      'It is awarded automatically by the submitQuizAnswers and '
      'resolveChallengeOutcome Cloud Functions.',
    );
  }

  Stream<List<Map<String, dynamic>>> weeklyLeaderboardStream() {
    return _db
        .collection('users')
        .orderBy('weeklyPoints', descending: true)
        .limit(100)
        .snapshots()
        .map((snap) {
      return snap.docs.asMap().entries.map((entry) {
        final data = entry.value.data();
        return {
          'rank':          entry.key + 1,
          'uid':           entry.value.id,
          'username':      (data['username']     as String?) ?? 'Anonymous',
          'university':    (data['university']   as String?) ?? '',
          'weeklyPoints':  (data['weeklyPoints'] as int?)    ?? 0,
          'isCurrentUser': entry.value.id == _uid,
        };
      }).toList();
    });
  }

  // ─── Weekly Player Count (Stage 19 — percentile display) ──────────────────

  /// Cached result of [getWeeklyPlayerCount].
  static int?      _weeklyPlayerCountCache;
  static DateTime? _weeklyPlayerCountCacheTime;

  /// Returns the number of users who have earned at least 1 weekly point
  /// this week (i.e. they have competed and should appear on the board).
  ///
  /// Uses a Firestore COUNT aggregation — no documents are downloaded.
  /// The result is cached in a static variable for up to 5 minutes so that
  /// repeated calls during a single session (e.g. stream rebuilds) never
  /// fire more than one Firestore read every 5 minutes.
  Future<int> getWeeklyPlayerCount() async {
    final now = DateTime.now();
    if (_weeklyPlayerCountCache != null &&
        _weeklyPlayerCountCacheTime != null &&
        now.difference(_weeklyPlayerCountCacheTime!).inMinutes < 5) {
      return _weeklyPlayerCountCache!;
    }

    try {
      final snap = await _db
          .collection('users')
          .where('weeklyPoints', isGreaterThan: 0)
          .count()
          .get();

      final count = snap.count ?? 0;
      _weeklyPlayerCountCache     = count;
      _weeklyPlayerCountCacheTime = now;
      return count;
    } catch (e) {
      debugPrint('[FirestoreService] getWeeklyPlayerCount error: $e');
      // Return cache even if stale rather than surfacing an error to the UI.
      return _weeklyPlayerCountCache ?? 0;
    }
  }

  /// Returns the leaderboard entry for the user ranked exactly one position
  /// above the current user — their "Rival" — or `null` if:
  ///   • the user is not authenticated
  ///   • the user has 0 weeklyPoints (not on the board yet)
  ///   • the user is already rank 1
  ///   • the user is outside the visible top-100 window
  ///
  /// Implementation notes:
  ///   1. A COUNT aggregation cheaply tells us how many users have strictly
  ///      more weeklyPoints than the current user (`countAbove`).
  ///   2. The rival sits at position `countAbove` in the desc-ordered list,
  ///      so we fetch exactly `countAbove` docs and take the last one.
  ///   3. We cap at 99 — a user outside the top-100 leaderboard widget has
  ///      no visible rival row to tap, so there is nothing to tag.
  Future<Map<String, dynamic>?> getRivalForUser() async {
    if (_uid == null) return null;

    // 1. Read current user's weekly points.
    final mySnap = await _userDoc.get();
    final myPts  = (mySnap.data()?['weeklyPoints'] as int?) ?? 0;

    // Not on the board yet.
    if (myPts == 0) return null;

    // 2. Count users with strictly higher points.
    final countSnap = await _db
        .collection('users')
        .where('weeklyPoints', isGreaterThan: myPts)
        .count()
        .get();

    final countAbove = countSnap.count ?? 0;

    // Already rank 1 — no one to rival.
    if (countAbove == 0) return null;

    // Outside the visible top-100 — no rival shown in the leaderboard widget.
    if (countAbove >= 100) return null;

    // 3. Fetch the top `countAbove` users; the last document is the rival
    //    (the person ranked immediately above the current user).
    final snap = await _db
        .collection('users')
        .orderBy('weeklyPoints', descending: true)
        .limit(countAbove)
        .get();

    if (snap.docs.isEmpty) return null;

    final rivalDoc  = snap.docs.last;
    final rivalData = rivalDoc.data();

    return {
      'uid':          rivalDoc.id,
      'username':     (rivalData['username']     as String?) ?? 'Anonymous',
      'university':   (rivalData['university']   as String?) ?? '',
      'weeklyPoints': (rivalData['weeklyPoints'] as int?)    ?? 0,
      'rank':         countAbove, // their rank equals countAbove
    };
  }

  // ─── Campus Leaderboard ──────────────────────────────────────────────────────

  Stream<List<Map<String, dynamic>>> weeklyCampusLeaderboardStream(
      String university) {
    if (university.isEmpty) return Stream.value([]);

    return _db
        .collection('users')
        .where('university', isEqualTo: university)
        .orderBy('weeklyPoints', descending: true)
        .limit(50)
        .snapshots()
        .map((snap) {
      return snap.docs.asMap().entries.map((entry) {
        final data = entry.value.data();
        return {
          'rank':          entry.key + 1,
          'uid':           entry.value.id,
          'username':      (data['username']     as String?) ?? 'Anonymous',
          'weeklyPoints':  (data['weeklyPoints'] as int?)    ?? 0,
          'isCurrentUser': entry.value.id == _uid,
        };
      }).toList();
    });
  }

  // ─── University Helpers ──────────────────────────────────────────────────────

  Future<String?> getCurrentUserUniversity() async {
    if (_uid == null) return null;
    final doc = await _userDoc.get();
    final raw = doc.data()?['university'] as String?;
    return (raw == null || raw.isEmpty) ? null : raw;
  }

  Future<void> updateUniversity(String university) async {
    if (_uid == null) return;
    await _userDoc.update({'university': university});
  }

  // ─── Top Universities (5-minute in-memory cache) ─────────────────────────────

  Map<String, int>? _topUniCache;
  DateTime?         _topUniCacheTime;

  Future<List<UniversityTotal>> getTopUniversities() async {
    if (_topUniCache != null &&
        _topUniCacheTime != null &&
        DateTime.now().difference(_topUniCacheTime!).inMinutes < 5) {
      return _buildTopTwo(_topUniCache!);
    }

    final snap = await _db
        .collection('users')
        .orderBy('weeklyPoints', descending: true)
        .limit(500)
        .get();

    final totals = <String, int>{};
    for (final doc in snap.docs) {
      final data = doc.data();
      final uni  = data['university'] as String?;
      final pts  = (data['weeklyPoints'] as int?) ?? 0;
      if (uni != null && uni.isNotEmpty && uni != 'Other') {
        totals[uni] = (totals[uni] ?? 0) + pts;
      }
    }

    _topUniCache     = totals;
    _topUniCacheTime = DateTime.now();
    return _buildTopTwo(totals);
  }

  void invalidateTopUniCache() {
    _topUniCache     = null;
    _topUniCacheTime = null;
  }

  List<UniversityTotal> _buildTopTwo(Map<String, int> totals) {
    final sorted = totals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted
        .take(2)
        .map((e) => UniversityTotal(university: e.key, total: e.value))
        .toList();
  }

  // ─── Prize Pool ──────────────────────────────────────────────────────────────

  static String currentWeekId() {
    final now    = DateTime.now().toUtc();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final d      = DateTime(monday.year, monday.month, monday.day);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  Stream<Map<String, dynamic>> prizePoolStream() {
    return _db
        .collection('prize_pool')
        .doc(currentWeekId())
        .snapshots()
        .map((s) => s.data() ??
            {'totalNaira': 0.0, 'weekId': currentWeekId(), 'status': 'active'});
  }

  Future<void> incrementPrizePool(double nairaPerView) async {
    final ref = _db.collection('prize_pool').doc(currentWeekId());
    await ref.set({
      'totalNaira':  FieldValue.increment(nairaPerView),
      'adViewCount': FieldValue.increment(1),
      'weekId':      currentWeekId(),
      'status':      'active',
    }, SetOptions(merge: true));
  }

  // ─── Last Week Winners ───────────────────────────────────────────────────────

  Future<LastWeekResult?> getLastWeekWinners() async {
    try {
      final snap = await _db
          .collection('prize_pool')
          .where('status', isEqualTo: 'paid')
          .orderBy('weekId', descending: true)
          .limit(1)
          .get(const GetOptions(source: Source.server));

      if (snap.docs.isEmpty) return null;

      final data    = snap.docs.first.data();
      final weekId  = (data['weekId']      as String?) ?? '';
      final total   = ((data['totalNaira'] as num?)?.toDouble()) ?? 0.0;
      final rawList = (data['winners']     as List<dynamic>?) ?? [];

      if (rawList.isEmpty) return null;

      final winners = rawList
          .map((w) => PrizeWinner.fromMap(Map<String, dynamic>.from(w as Map)))
          .toList()
        ..sort((a, b) => a.rank.compareTo(b.rank));

      return LastWeekResult(
        weekId:     weekId,
        totalNaira: total,
        winners:    winners,
      );
    } catch (_) {
      return null;
    }
  }

  // ─── Username ────────────────────────────────────────────────────────────────

  Future<bool> canChangeUsername() async {
    if (_uid == null) return false;
    final doc        = await _userDoc.get();
    final lastChange = doc.data()?['lastUsernameChange'] as Timestamp?;
    if (lastChange == null) return true;
    final daysSince  = DateTime.now().difference(lastChange.toDate()).inDays;
    return daysSince >= 7;
  }

  Future<DateTime?> nextUsernameChangeDate() async {
    if (_uid == null) return null;
    final doc        = await _userDoc.get();
    final lastChange = doc.data()?['lastUsernameChange'] as Timestamp?;
    if (lastChange == null) return null;
    final nextAllowed = lastChange.toDate().add(const Duration(days: 7));
    if (DateTime.now().isAfter(nextAllowed)) return null;
    return nextAllowed;
  }

  Future<void> updateUsername(String newUsername) async {
    if (_uid == null) return;
    final canChange = await canChangeUsername();
    if (!canChange) {
      throw Exception('Username can only be changed once every 7 days.');
    }
    await _auth.currentUser!.updateDisplayName(newUsername.trim());
    await _userDoc.update({
      'username':           newUsername.trim(),
      'lastUsernameChange': FieldValue.serverTimestamp(),
    });
  }

  Future<String> getUsername() async {
    if (_uid == null) return 'Trainer';
    final doc = await _userDoc.get();
    return (doc.data()?['username'] as String?) ??
        _auth.currentUser?.displayName ??
        'Trainer';
  }

  // ─── Challenges ───────────────────────────────────────────────────────────────

  CollectionReference<Map<String, dynamic>> get _challenges =>
      _db.collection('challenges');

  String _generateChallengeCode() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rand  = Random();
    return List.generate(6, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  /// ⚠️ DO NOT USE — BYPASSES ALL CLOUD FUNCTIONS VALIDATION
  ///
  /// This method is DEAD CODE and only exists for backwards compatibility.
  /// It does NOT:
  ///   - Deduct coins from the creator
  ///   - Check daily challenge creation limits
  ///   - Validate the active-challenge cap
  ///   - Trigger any CF-side payouts/refunds
  ///
  /// All challenge creation MUST go through Cloud Functions instead.
  /// This method will throw [Exception] to prevent accidental misuse.
  @Deprecated('Use Cloud Functions instead — never call this directly')
  Future<ChallengeCreationResult> createChallenge({
    required String animeTitle,
    required int    stakeAmount,
    String?         opponentUid,
    String?         opponentUsername,
  }) async {
    throw Exception(
      'createChallenge() is DEAD CODE and bypasses all CF validation. '
      'Use Cloud Functions createChallenge instead.',
    );
  }

  Stream<ChallengeModel?> challengeStream(String challengeId) {
    return _challenges
        .doc(challengeId)
        .snapshots()
        .map((s) => s.exists ? ChallengeModel.fromDoc(s) : null);
  }

  Future<ChallengeModel?> getChallengeByCode(String code) async {
    final snap = await _challenges
        .doc(code.trim().toUpperCase())
        .get(const GetOptions(source: Source.server));
    return snap.exists ? ChallengeModel.fromDoc(snap) : null;
  }

  /// ⚠️ DO NOT USE — BYPASSES ALL CLOUD FUNCTIONS VALIDATION
  ///
  /// This method is DEAD CODE and only exists for backwards compatibility.
  /// It does NOT:
  ///   - Deduct coins from the opponent
  ///   - Check opponent's daily challenge join limits
  ///   - Validate the active-challenge cap
  ///   - Trigger any CF-side coin locking or escrow
  ///   - Execute payout logic on completion
  ///
  /// All challenge joins MUST go through Cloud Functions instead.
  /// This method will throw [Exception] to prevent accidental misuse.
  @Deprecated('Use Cloud Functions instead — never call this directly')
  Future<void> joinChallenge(String challengeId) async {
    throw Exception(
      'joinChallenge() is DEAD CODE and bypasses all CF validation. '
      'Use Cloud Functions joinChallenge instead.',
    );
  }

  Future<void> submitCreatorScore(String challengeId, int score) async {
    if (_uid == null) return;
    await _challenges.doc(challengeId).update({'creatorScore': score});
  }

  Future<void> submitOpponentScore(String challengeId, int score) async {
    if (_uid == null) return;
    await _challenges.doc(challengeId).update({'opponentScore': score});
  }

  Future<List<AnimeQuestion>> fetchQuestionsByIds(List<String> ids) async {
    if (ids.isEmpty) return [];

    final chunks = <List<String>>[];
    for (int i = 0; i < ids.length; i += 30) {
      chunks.add(ids.sublist(i, (i + 30).clamp(0, ids.length)));
    }

    final results = <AnimeQuestion>[];
    for (final chunk in chunks) {
      final snap = await _db
          .collection('questions')
          .where(FieldPath.documentId, whereIn: chunk)
          .get(const GetOptions(source: Source.server));
      results.addAll(snap.docs.map((d) => AnimeQuestion.fromDoc(d)));
    }

    final byId = {for (final q in results) q.id: q};
    return ids.map((id) => byId[id]).whereType<AnimeQuestion>().toList();
  }

  Future<List<String>> _pickRandomQuestionIds(
    String animeTitle,
    int    count,
  ) async {
    final snap = await _db
        .collection('questions')
        .where('animeTitle', isEqualTo: animeTitle)
        .get(const GetOptions(source: Source.server));

    if (snap.docs.isEmpty) {
      throw Exception('No questions found for "$animeTitle".');
    }

    final docs = List.of(snap.docs)..shuffle(Random());
    return docs.take(count).map((d) => d.id).toList();
  }
}