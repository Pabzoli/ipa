// lib/core/services/firestore_service.dart

import 'dart:math';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../features/quiz/questions.dart';
import '../../features/multiplayer/models/challenge_model.dart';

// ─── University Constants ─────────────────────────────────────────────────────
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

class UniversityTotal {
  final String university;
  final int    total;
  const UniversityTotal({required this.university, required this.total});
}

// ─── Prize Winner Model ───────────────────────────────────────────────────────
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
        uid:         (map['uid']        as String?)  ?? '',
        username:    (map['username']   as String?)  ?? 'Anonymous',
        rank:        ((map['rank']      as num?)?.toInt()) ?? 0,
        prizeAmount: ((map['prize']     as num?)?.toDouble()) ?? 0.0,
        university:  (map['university'] as String?)  ?? '',
      );
}

// ─── Last Week Result Model ───────────────────────────────────────────────────
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

  DocumentReference<Map<String, dynamic>> get _userDoc =>
      _db.collection('users').doc(_uid);

  // ─── Score ──────────────────────────────────────────────────────────────────
  Stream<int> scoreStream() {
    if (_uid == null) return Stream.value(500);
    return _userDoc.snapshots().map(
          (s) => (s.data()?['totalScore'] as int?) ?? 500,
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

  /// Returns all available anime titles from the questions collection.
  Future<List<String>> fetchAvailableAnime() async {
    final snap = await _db
        .collection('questions')
        .get(const GetOptions(source: Source.server));
    final titles = snap.docs
        .map((d) => d.data()['animeTitle'] as String?)
        .whereType<String>()
        .toSet()
        .toList()
      ..sort();
    return titles;
  }

  /// Fetches questions for a specific anime title with their Firestore doc IDs.
  Future<List<MapEntry<String, AnimeQuestion>>> _fetchQuestionsForChallenge(
      String animeTitle) async {
    final snap = await _db
        .collection('questions')
        .get(const GetOptions(source: Source.server));
    final normalised = animeTitle.toLowerCase();
    return snap.docs
        .where((d) =>
            (d.data()['animeTitle'] as String?)?.toLowerCase() == normalised)
        .map((d) => MapEntry(d.id, AnimeQuestion.fromMap(d.data())))
        .toList();
  }

  /// Fetches up to 10 questions by their Firestore document IDs, preserving order.
  /// Uses `whereIn` — safe up to 30 items (Firestore SDK limit).
  Future<List<AnimeQuestion>> fetchQuestionsByIds(List<String> ids) async {
    if (ids.isEmpty) return [];
    final snap = await _db
        .collection('questions')
        .where(FieldPath.documentId, whereIn: ids)
        .get(const GetOptions(source: Source.server));
    final map = {
      for (final d in snap.docs) d.id: AnimeQuestion.fromMap(d.data())
    };
    // Restore the original seeded order from the challenge document.
    final result = ids.map((id) => map[id]).whereType<AnimeQuestion>().toList();

    // FIX: Throw a descriptive error if questions couldn't be resolved.
    // Previously this would silently return [] causing the start button
    // to show with onTap: null and appear "frozen."
    if (result.isEmpty && ids.isNotEmpty) {
      throw Exception(
        'Could not load the quiz questions. '
        'Please check your connection and try again.',
      );
    }
    return result;
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

  Stream<Map<String, dynamic>> statsStream() {
    if (_uid == null) return Stream.value({});
    return _userDoc.snapshots().map(
      (s) => (s.data()?['stats'] as Map<String, dynamic>?) ?? {},
    );
  }

  // ─── Challenges ──────────────────────────────────────────────────────────────

  static String _generateChallengeCode() {
    // Omit O/0 and I/1 to avoid visual confusion.
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng   = Random.secure();
    return String.fromCharCodes(
      List.generate(6, (_) => chars.codeUnitAt(rng.nextInt(chars.length))),
    );
  }

  /// Creates a new challenge, selects 10 seeded questions, and returns the model.
  /// Does NOT deduct the bet yet — deduction happens atomically when opponent joins.
  Future<ChallengeModel> createChallenge({
    required String animeTitle,
    required int    betAmount,
  }) async {
    if (_uid == null) throw Exception('Not authenticated');

    final username = await getUsername();
    final allQ     = await _fetchQuestionsForChallenge(animeTitle);

    if (allQ.length < 10) {
      throw Exception(
          'Not enough questions for "$animeTitle" yet. Try another anime!');
    }

    allQ.shuffle(Random.secure());
    final questionIds = allQ.take(10).map((e) => e.key).toList();
    final code        = _generateChallengeCode();
    final now         = DateTime.now();

    final ref = await _db.collection('challenges').add({
      'code':             code,
      'creatorUid':       _uid,
      'creatorUsername':  username,
      'opponentUid':      null,
      'opponentUsername': null,
      'betAmount':        betAmount,
      'animeTitle':       animeTitle,
      'questionIds':      questionIds,
      'creatorScore':     null,
      'opponentScore':    null,
      'status':           ChallengeStatus.waiting.raw,
      'createdAt':        FieldValue.serverTimestamp(),
      'expiresAt':        Timestamp.fromDate(now.add(const Duration(hours: 24))),
      'outcome':          null,
    });

    final snap = await ref.get();
    return ChallengeModel.fromDoc(snap);
  }

  /// Looks up a challenge by its 6-character share code.
  /// Throws descriptive exceptions for expired / completed / missing challenges.
  Future<ChallengeModel?> getChallengeByCode(String code) async {
    final snap = await _db
        .collection('challenges')
        .where('code', isEqualTo: code.toUpperCase().trim())
        .limit(1)
        .get(const GetOptions(source: Source.server));

    if (snap.docs.isEmpty) return null;

    final model = ChallengeModel.fromDoc(snap.docs.first);
    if (model.isExpired)  throw Exception('This challenge has expired.');
    if (model.isComplete) throw Exception('This challenge has already been completed.');
    return model;
  }

  /// Opponent accepts a challenge.
  /// Atomically deducts BOTH players' bets and sets status to [in_progress].
  Future<void> joinChallenge(String challengeId) async {
    if (_uid == null) throw Exception('Not authenticated');

    final username     = await getUsername();
    final challengeRef = _db.collection('challenges').doc(challengeId);

    await _db.runTransaction((tx) async {
      final cSnap = await tx.get(challengeRef);
      if (!cSnap.exists) throw Exception('Challenge not found.');

      final challenge = ChallengeModel.fromDoc(cSnap);

      if (challenge.isExpired)          throw Exception('This challenge has expired.');
      if (challenge.creatorUid == _uid) throw Exception('You cannot join your own challenge.');
      if (challenge.hasOpponent)        throw Exception('This challenge already has an opponent.');
      if (challenge.isComplete)         throw Exception('This challenge is already completed.');

      final creatorDocRef  = _db.collection('users').doc(challenge.creatorUid);
      final opponentDocRef = _db.collection('users').doc(_uid);

      final cUserSnap = await tx.get(creatorDocRef);
      final oUserSnap = await tx.get(opponentDocRef);

      final creatorBal  = ((cUserSnap.data()?['totalScore']  as num?)?.toInt()) ?? 0;
      final opponentBal = ((oUserSnap.data()?['totalScore']  as num?)?.toInt()) ?? 0;

      if (creatorBal < challenge.betAmount) {
        throw Exception("The challenger no longer has enough points for this bet.");
      }
      if (opponentBal < challenge.betAmount) {
        throw Exception(
            "You need ${challenge.betAmount} pts for this bet (you have $opponentBal pts).");
      }

      // Deduct both bets atomically — the winner gets them back after.
      tx.update(creatorDocRef,  {'totalScore': FieldValue.increment(-challenge.betAmount)});
      tx.update(opponentDocRef, {'totalScore': FieldValue.increment(-challenge.betAmount)});
      tx.update(challengeRef, {
        'opponentUid':      _uid,
        'opponentUsername': username,
        'status':           ChallengeStatus.inProgress.raw,
      });
    });
  }

  /// Saves the current user's quiz score.
  /// If the OTHER player has already scored, resolves the challenge:
  ///   - determines winner
  ///   - transfers bets (winner gets 2× back; draw refunds both)
  ///   - sets status to [completed]
  ///
  /// Returns the [ChallengeOutcome] when resolved, or null when still waiting.
  Future<ChallengeOutcome?> saveScoreAndMaybeResolve({
    required String challengeId,
    required int    score,
    required bool   isCreator,
  }) async {
    if (_uid == null) throw Exception('Not authenticated');

    final challengeRef = _db.collection('challenges').doc(challengeId);
    ChallengeOutcome? resolved;

    await _db.runTransaction((tx) async {
      final snap = await tx.get(challengeRef);
      if (!snap.exists) throw Exception('Challenge not found.');
      final data = snap.data()!;

      // Idempotency guard — score already saved for this player.
      final alreadySaved = isCreator
          ? data['creatorScore']  != null
          : data['opponentScore'] != null;
      if (alreadySaved) {
        resolved = parseChallengeOutcome(data['outcome'] as String?);
        return;
      }

      final Map<String, dynamic> updates = isCreator
          ? {'creatorScore':  score}
          : {'opponentScore': score};

      // Check whether the other player has already scored.
      final int? otherScore = isCreator
          ? (data['opponentScore'] as num?)?.toInt()
          : (data['creatorScore']  as num?)?.toInt();

      if (otherScore != null) {
        // Both scores present — resolve now.
        final int cScore = isCreator ? score     : otherScore;
        final int oScore = isCreator ? otherScore : score;

        final ChallengeOutcome outcome = cScore > oScore
            ? ChallengeOutcome.creatorWins
            : oScore > cScore
                ? ChallengeOutcome.opponentWins
                : ChallengeOutcome.draw;

        resolved               = outcome;
        updates['outcome']     = outcome.raw;
        updates['status']      = ChallengeStatus.completed.raw;

        final creatorUid  = data['creatorUid']  as String;
        final opponentUid = data['opponentUid'] as String;
        final betAmount   = (data['betAmount']  as num).toInt();

        final cRef = _db.collection('users').doc(creatorUid);
        final oRef = _db.collection('users').doc(opponentUid);

        switch (outcome) {
          case ChallengeOutcome.creatorWins:
            tx.update(cRef, {
              'totalScore':        FieldValue.increment(betAmount * 2),
              'stats.gamesWon':    FieldValue.increment(1),
              'stats.gamesPlayed': FieldValue.increment(1),
              'stats.hseStaked':   FieldValue.increment(betAmount),
              'stats.hseWon':      FieldValue.increment(betAmount),
            });
            tx.update(oRef, {
              'stats.gamesLost':   FieldValue.increment(1),
              'stats.gamesPlayed': FieldValue.increment(1),
              'stats.hseStaked':   FieldValue.increment(betAmount),
              'stats.hseLost':     FieldValue.increment(betAmount),
            });
          case ChallengeOutcome.opponentWins:
            tx.update(oRef, {
              'totalScore':        FieldValue.increment(betAmount * 2),
              'stats.gamesWon':    FieldValue.increment(1),
              'stats.gamesPlayed': FieldValue.increment(1),
              'stats.hseStaked':   FieldValue.increment(betAmount),
              'stats.hseWon':      FieldValue.increment(betAmount),
            });
            tx.update(cRef, {
              'stats.gamesLost':   FieldValue.increment(1),
              'stats.gamesPlayed': FieldValue.increment(1),
              'stats.hseStaked':   FieldValue.increment(betAmount),
              'stats.hseLost':     FieldValue.increment(betAmount),
            });
          case ChallengeOutcome.draw:
            tx.update(cRef, {
              'totalScore':        FieldValue.increment(betAmount),
              'stats.gamesDraw':   FieldValue.increment(1),
              'stats.gamesPlayed': FieldValue.increment(1),
              'stats.hseStaked':   FieldValue.increment(betAmount),
            });
            tx.update(oRef, {
              'totalScore':        FieldValue.increment(betAmount),
              'stats.gamesDraw':   FieldValue.increment(1),
              'stats.gamesPlayed': FieldValue.increment(1),
              'stats.hseStaked':   FieldValue.increment(betAmount),
            });
        }
      }

      tx.update(challengeRef, updates);
    });

    // Non-critical: save match history in the background after the transaction.
    if (resolved != null) {
      _saveMatchHistoryForChallenge(challengeId, score, isCreator, resolved!)
          .catchError((_) {});
    }

    return resolved;
  }

  Future<void> _saveMatchHistoryForChallenge(
    String           challengeId,
    int              myScore,
    bool             isCreator,
    ChallengeOutcome outcome,
  ) async {
    if (_uid == null) return;
    final snap = await _db.collection('challenges').doc(challengeId).get();
    if (!snap.exists) return;
    final data = snap.data()!;

    final betAmount     = (data['betAmount'] as num).toInt();
    final theirName     = isCreator
        ? (data['opponentUsername'] as String? ?? 'Opponent')
        : (data['creatorUsername']  as String? ?? 'Challenger');
    final myFinalScore  = ((isCreator ? data['creatorScore']  : data['opponentScore']) as num?)
            ?.toInt() ?? myScore;
    final theirScore    = ((isCreator ? data['opponentScore'] : data['creatorScore'])  as num?)
            ?.toInt() ?? 0;

    final outcomeStr = switch (outcome) {
      ChallengeOutcome.creatorWins  => isCreator ? 'win'  : 'lose',
      ChallengeOutcome.opponentWins => isCreator ? 'lose' : 'win',
      ChallengeOutcome.draw         => 'draw',
    };
    final pointsChange = switch (outcomeStr) {
      'win'  => betAmount,
      'lose' => -betAmount,
      _      => 0,
    };

    await _userDoc.collection('matches').add({
      'opponent':      theirName,
      'playerScore':   myFinalScore,
      'opponentScore': theirScore,
      'betScore':      betAmount,
      'outcome':       outcomeStr,
      'pointsChange':  pointsChange,
      'timestamp':     FieldValue.serverTimestamp(),
      'challengeId':   challengeId,
    });
  }

  /// Live stream of a challenge document. Filters out non-existent snapshots.
  Stream<ChallengeModel> challengeStream(String challengeId) => _db
      .collection('challenges')
      .doc(challengeId)
      .snapshots()
      .where((s) => s.exists)
      .map(ChallengeModel.fromDoc);

  // ─── BUG FIX: myChallengesStream ─────────────────────────────────────────────
  // BEFORE: Used StreamController() — single-subscription stream.
  //         TabBarView disposes hidden tabs, so switching Active ↔ Completed
  //         caused StreamBuilder to cancel then re-subscribe, throwing
  //         "Bad state: Stream has already been listened to."
  //
  // AFTER:  Uses StreamController.broadcast() with onListen/onCancel so:
  //   - The Firestore subscriptions start fresh each time a listener subscribes.
  //   - The Firestore subscriptions cancel when the last listener unsubscribes.
  //   - Multiple listeners (or re-subscribes after dispose) all work correctly.
  /// Returns a live stream of all challenges the current user is involved in.
  /// Merges two queries (as creator, as opponent) client-side.
  /// [activeOnly] = true → only waiting/in_progress; false → include completed.
  Stream<List<ChallengeModel>> myChallengesStream({bool activeOnly = false}) {
    if (_uid == null) return Stream.value([]);

    final statuses = activeOnly
        ? ['waiting', 'in_progress']
        : ['waiting', 'in_progress', 'completed'];

    var asCreator  = <ChallengeModel>[];
    var asOpponent = <ChallengeModel>[];

    StreamSubscription? sub1;
    StreamSubscription? sub2;
    StreamController<List<ChallengeModel>>? ctrl;

    void emit() {
      if (ctrl == null || ctrl!.isClosed) return;
      final seen     = <String>{};
      final combined = [...asCreator, ...asOpponent]
          .where((c) => seen.add(c.challengeId))
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      ctrl!.add(combined);
    }

    void startListening() {
      // Reset state on each fresh subscription so stale data isn't emitted.
      asCreator  = [];
      asOpponent = [];

      sub1 = _db
          .collection('challenges')
          .where('creatorUid', isEqualTo: _uid)
          .where('status', whereIn: statuses)
          .orderBy('createdAt', descending: true)
          .limit(30)
          .snapshots()
          .listen(
            (s) { asCreator = s.docs.map(ChallengeModel.fromDoc).toList(); emit(); },
            onError: (_) {},
          );

      sub2 = _db
          .collection('challenges')
          .where('opponentUid', isEqualTo: _uid)
          .where('status', whereIn: statuses)
          .orderBy('createdAt', descending: true)
          .limit(30)
          .snapshots()
          .listen(
            (s) { asOpponent = s.docs.map(ChallengeModel.fromDoc).toList(); emit(); },
            onError: (_) {},
          );
    }

    void stopListening() {
      sub1?.cancel(); sub1 = null;
      sub2?.cancel(); sub2 = null;
    }

    // broadcast() → can be listened to, cancelled, and re-listened to any
    // number of times. onListen/onCancel manage the underlying Firestore subs.
    ctrl = StreamController<List<ChallengeModel>>.broadcast(
      onListen: startListening,
      onCancel: stopListening,
    );

    return ctrl!.stream;
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

      return LastWeekResult(weekId: weekId, totalNaira: total, winners: winners);
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
    return DateTime.now().difference(lastChange.toDate()).inDays >= 7;
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
}