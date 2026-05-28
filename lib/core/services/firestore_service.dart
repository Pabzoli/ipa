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
  ///   'spend_shield' | 'spend_timer' | 'iap'
  ///
  /// Throws [InsufficientCoinsException] if the resulting balance would be < 0.
  Future<void> updateAnimeCoins(int delta, String type) async {
    if (_uid == null) throw Exception('Not authenticated');

    await _db.runTransaction((tx) async {
      final snap    = await tx.get(_userDoc);
      final current = (snap.data()?['animeCoins'] as int?) ?? 0;
      final after   = current + delta;

      if (after < 0) {
        throw InsufficientCoinsException(
          required:  delta.abs(),
          available: current,
        );
      }

      // 1. Update balance field atomically.
      tx.update(_userDoc, {'animeCoins': after});

      // 2. Append an immutable transaction log entry.
      final logRef = _userDoc.collection('coinTransactions').doc();
      tx.set(logRef, {
        'type':         type,
        'delta':        delta,
        'balanceAfter': after,
        'timestamp':    FieldValue.serverTimestamp(),
      });
    });
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
  /// Call from UserDataProvider._startFirestoreStreams() alongside the other
  /// patch calls so every existing user is healed on their next sign-in.
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
  // FIX: These two methods were missing, causing a compile error because
  // UserDataProvider calls them. Added here.

  /// Live stream of users/{uid}.streakShieldActive.
  /// Emits false if the field is absent (safe default).
  Stream<bool> streakShieldStream() {
    if (_uid == null) return Stream.value(false);
    return _userDoc.snapshots().map(
      (s) => (s.data()?['streakShieldActive'] as bool?) ?? false,
    );
  }

  /// Writes [value] to users/{uid}.streakShieldActive.
  /// Pass `true` to activate, `false` to consume (deactivate) the shield.
  Future<void> setStreakShieldActive(bool value) async {
    if (_uid == null) return;
    await _userDoc.update({'streakShieldActive': value});
  }

  // ─── Daily Ad Watched stream (P-04) ──────────────────────────────────────

  /// Live stream of how many rewarded ads the signed-in user has watched today.
  ///
  /// Emits 0 when:
  ///   • [lastAdWatchDate] is absent (new account / first open).
  ///   • [lastAdWatchDate] is from a prior WAT day — the UI resets immediately
  ///     without needing a server write, matching the Cloud Function's logic.
  ///   • The user is not authenticated.
  ///
  /// [dailyAdWatched] and [lastAdWatchDate] are written ONLY by the
  /// [recordAdWatch] Cloud Function — never by the client directly.
  /// Firestore rules enforce this at the document level.
  Stream<int> dailyAdWatchedStream() {
    if (_uid == null) return Stream.value(0);
    return _userDoc.snapshots().map((snap) {
      final data = snap.data();
      if (data == null) return 0;

      // ── WAT midnight reset check ─────────────────────────────────────────
      // WAT = UTC+1. If the stored date is from a prior WAT day, return 0 so
      // the cap display resets at midnight without waiting for the next CF call.
      final lastWatchTs = data['lastAdWatchDate'] as Timestamp?;
      if (lastWatchTs == null) return 0;

      final lastWAT = lastWatchTs.toDate().toUtc().add(const Duration(hours: 1));
      final nowWAT  = DateTime.now().toUtc().add(const Duration(hours: 1));
      final sameDay = lastWAT.year  == nowWAT.year  &&
                      lastWAT.month == nowWAT.month &&
                      lastWAT.day   == nowWAT.day;

      if (!sameDay) return 0; // new WAT day → show fresh count
      return (data['dailyAdWatched'] as int?) ?? 0;
    });
  }

  /// Adds [dailyAdWatched: 0] and [lastAdWatchDate: null] to docs that
  /// predate P-04. No-ops on accounts that already have the fields.
  /// Call alongside the other ensure* patches in UserDataProvider.
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
  ///
  /// Emits `false` when:
  ///   • The field is absent (pre-P-05 accounts / free users).
  ///   • The user is not authenticated.
  ///
  /// Written server-side only by the purchase-verification Cloud Function
  /// (Google Play Billing). Firestore rules block all client writes to this
  /// field. Used by [UserDataProvider.premiumActive] to gate regular
  /// interstitial ads on result screens.
  Stream<bool> premiumActiveStream() {
    if (_uid == null) return Stream.value(false);
    return _userDoc.snapshots().map(
      (s) => (s.data()?['premiumActive'] as bool?) ?? false,
    );
  }

  // ─── Early Anime Unlock ────────────────────────────────────────────────────
  // FIX: New method required by Surface 4 in home_page.dart.

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
        .map((doc) => AnimeQuestion.fromMap(doc.data()))
        .toList();
  }

  Future<List<AnimeQuestion>> fetchQuestionsForTitles(
      List<String> titles) async {
    final normalised = titles.map((t) => t.toLowerCase()).toSet();
    final all        = await fetchQuestions();
    final filtered   = all
        .where((q) => normalised.contains(q.animeTitle.toLowerCase()))
        .toList();

    if (filtered.isEmpty) {
      throw Exception(
        'No questions found for the selected anime. '
        'More content is coming soon!',
      );
    }

    return filtered;
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

  Future<void> addWeeklyPoints(int amount) async {
    if (_uid == null) return;
    await _userDoc.update({'weeklyPoints': FieldValue.increment(amount)});
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
          'weeklyPoints':  (data['weeklyPoints'] as int?)    ?? 0,
          'isCurrentUser': entry.value.id == _uid,
        };
      }).toList();
    });
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

  Future<ChallengeCreationResult> createChallenge({
    required String animeTitle,
    required int    betAmount,
  }) async {
    if (_uid == null) throw Exception('Not authenticated');
    final username    = await getUsername();
    final questionIds = await _pickRandomQuestionIds(animeTitle, 10);
    if (questionIds.length < 10) {
      throw Exception(
        'Not enough questions for "$animeTitle" yet. Need at least 10.',
      );
    }

    String code;
    bool   exists;
    do {
      code  = _generateChallengeCode();
      final snap = await _challenges.doc(code).get();
      exists = snap.exists;
    } while (exists);

    final now       = DateTime.now();
    final expiresAt = now.add(const Duration(hours: 24));

    final batch = _db.batch();
    batch.set(_challenges.doc(code), {
      'challengeId':      code,
      'creatorUid':       _uid,
      'creatorUsername':  username,
      'opponentUid':      null,
      'opponentUsername': null,
      'betAmount':        betAmount,
      'animeTitle':       animeTitle,
      'questionIds':      questionIds,
      'creatorScore':     null,
      'opponentScore':    null,
      'status':           'waiting',
      'createdAt':        Timestamp.fromDate(now),
      'expiresAt':        Timestamp.fromDate(expiresAt),
      'outcome':          null,
    });
    batch.update(_userDoc, {'totalScore': FieldValue.increment(-betAmount)});
    await batch.commit();

    return ChallengeCreationResult(challengeId: code, questionIds: questionIds);
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

  Future<void> joinChallenge(String challengeId) async {
    if (_uid == null) throw Exception('Not authenticated');
    final username = await getUsername();
    await _db.runTransaction((tx) async {
      final ref  = _challenges.doc(challengeId);
      final snap = await tx.get(ref);
      if (!snap.exists) throw Exception('Challenge not found.');

      final data      = snap.data()!;
      final status    = data['status'] as String;
      final betAmount = (data['betAmount'] as num).toInt();
      final expiresAt = (data['expiresAt'] as Timestamp).toDate();

      if (data['creatorUid'] == _uid) {
        throw Exception("You can't join your own challenge.");
      }
      if (status != 'waiting') {
        throw Exception('This challenge is no longer available.');
      }
      if (DateTime.now().isAfter(expiresAt)) {
        throw Exception('This challenge has expired.');
      }

      final userRef  = _db.collection('users').doc(_uid);
      final userSnap = await tx.get(userRef);
      final balance  = (userSnap.data()?['totalScore'] as num?)?.toInt() ?? 0;

      if (balance < betAmount) {
        throw Exception(
          'You need at least $betAmount pts to accept this challenge.',
        );
      }

      tx.update(ref, {
        'opponentUid':      _uid,
        'opponentUsername': username,
        'status':           'opponent_joined',
      });
      tx.update(userRef, {
        'totalScore': FieldValue.increment(-betAmount),
      });
    });
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