import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../features/quiz/questions.dart';
import '../../features/multiplayer/challenge_model.dart';

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

/// A lightweight model returned by [FirestoreService.getTopUniversities].
class UniversityTotal {
  final String university;
  final int    total;
  const UniversityTotal({required this.university, required this.total});
}

// ─── Prize Winner Model ───────────────────────────────────────────────────────
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
        uid:         (map['uid']          as String?) ?? '',
        username:    (map['username']     as String?) ?? 'Anonymous',
        rank:        ((map['rank']        as num?)?.toInt()) ?? 0,
        prizeAmount: ((map['prize'] as num?)?.toDouble()) ?? 0.0,
        university:  (map['university']   as String?) ?? '',
      );
}

// ─── Last Week Result Model ───────────────────────────────────────────────────
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

  String? get _uid => _auth.currentUser?.uid;
  String? get currentUid => _uid;

  DocumentReference<Map<String, dynamic>> get _userDoc =>
      _db.collection('users').doc(_uid);

  // ─── Score ──────────────────────────────────────────────────────────────────
  Stream<int> scoreStream() {
    if (_uid == null) return Stream.value(0); // FIX: Fallback to 0 instead of 500
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

  // ─── Hints ──────────────────────────────────────────────────────────────────
  Stream<int> hintStream() {
    if (_uid == null) return Stream.value(0);
    return _userDoc.snapshots().map(
          (s) => (s.data()?['hintCount'] as int?) ?? 5,
        );
  }

  Future<void> deductHint() async {
    if (_uid == null) return;
    final snap    = await _userDoc.get();
    final current = (snap.data()?['hintCount'] as int?) ?? 0;
    if (current <= 0) return;
    await _userDoc.update({'hintCount': FieldValue.increment(-1)});
  }

  Future<void> addHint() async {
    if (_uid == null) return;
    await _userDoc.update({'hintCount': FieldValue.increment(1)});
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
    required String outcome, // 'win' | 'lose' | 'draw'
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
  /// Streams the top 50 players from [university] sorted by weeklyPoints.
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
  DateTime?          _topUniCacheTime;

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
    final daysSince = DateTime.now().difference(lastChange.toDate()).inDays;
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
    final rand = Random();
    return List.generate(6, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  /// Creates a new challenge, deducts the bet from creator's score, and returns
  /// the challengeId + the 10 questionIds to play immediately.
  /// Uses a batch write so the score deduction and challenge creation are atomic.
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

    // Generate a unique code — use it as the Firestore document ID for O(1) lookup
    String code;
    bool exists;
    do {
      code  = _generateChallengeCode();
      final snap = await _challenges.doc(code).get();
      exists = snap.exists;
    } while (exists);

    final now       = DateTime.now();
    final expiresAt = now.add(const Duration(hours: 24));

    // Atomic: create challenge + deduct bet in one batch
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

  /// Streams the challenge doc in real time.
  Stream<ChallengeModel?> challengeStream(String challengeId) {
    return _challenges
        .doc(challengeId)
        .snapshots()
        .map((s) => s.exists ? ChallengeModel.fromDoc(s) : null);
  }

  /// Looks up a challenge by its 6-char code.
  Future<ChallengeModel?> getChallengeByCode(String code) async {
    final snap = await _challenges
        .doc(code.trim().toUpperCase())
        .get(const GetOptions(source: Source.server));
    return snap.exists ? ChallengeModel.fromDoc(snap) : null;
  }

  /// Opponent accepts the challenge: validates state, deducts their bet,
  /// and sets their uid/username atomically inside a transaction so two
  /// players can't join the same challenge simultaneously.
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

  /// Fetches [AnimeQuestion] objects by their Firestore document IDs,
  /// preserving the original order from [ids].
  Future<List<AnimeQuestion>> fetchQuestionsByIds(List<String> ids) async {
    final futures = ids.map(
      (id) => _db.collection('questions').doc(id).get(),
    );
    final results = await Future.wait(futures);
    return results
        .where((s) => s.exists)
        .map((s) => AnimeQuestion.fromDoc(s))
        .toList();
  }

  /// Internal: picks [count] random question IDs for the given anime title.
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