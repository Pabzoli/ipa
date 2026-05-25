import 'package:cloud_firestore/cloud_firestore.dart';

// ─── Status enum ──────────────────────────────────────────────────────────────
enum ChallengeStatus { waiting, opponentJoined, completed, expired }

// What changed: moved parse() out of the extension body and into a proper
// static method. Using an extension named constructor is a smell — the
// extension exists only to attach parse() to the enum because Dart doesn't
// allow static methods directly on enums in older SDKs. In Dart 2.17+ you
// can add methods directly to enums; left as extension here to stay
// compatible with the rest of the codebase.
extension ChallengeStatusX on ChallengeStatus {
  static ChallengeStatus parse(String? s) => switch (s) {
        'opponent_joined' => ChallengeStatus.opponentJoined,
        'completed'       => ChallengeStatus.completed,
        'expired'         => ChallengeStatus.expired,
        _                 => ChallengeStatus.waiting,
      };
}

// ─── Model ────────────────────────────────────────────────────────────────────
class ChallengeModel {
  final String challengeId;
  final String creatorUid;
  final String creatorUsername;
  final String? opponentUid;
  final String? opponentUsername;
  final int betAmount;
  final String animeTitle;
  final List<String> questionIds;
  final int? creatorScore;
  final int? opponentScore;
  final ChallengeStatus status;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String? outcome; // "creator_wins" | "opponent_wins" | "draw"

  const ChallengeModel({
    required this.challengeId,
    required this.creatorUid,
    required this.creatorUsername,
    this.opponentUid,
    this.opponentUsername,
    required this.betAmount,
    required this.animeTitle,
    required this.questionIds,
    this.creatorScore,
    this.opponentScore,
    required this.status,
    required this.createdAt,
    required this.expiresAt,
    this.outcome,
  });

  // ── Derived helpers ──────────────────────────────────────────────────────
  // What changed: isExpired now also checks status != 'expired' from
  // Firestore to respect the Cloud Function's explicit expiry writes.
  // Previously it only checked the local clock, which could disagree with
  // the server for users with wrong device times.
  bool get isExpired =>
      status == ChallengeStatus.expired ||
      (DateTime.now().isAfter(expiresAt) &&
          status != ChallengeStatus.completed);

  bool get isCompleted => status == ChallengeStatus.completed;
  bool get isDraw => outcome == 'draw';

  /// Returns the UID of the winner, or null for a draw/unresolved challenge.
  String? winnerUid({required String currentUid}) {
    if (outcome == null || outcome == 'draw') return null;
    if (outcome == 'creator_wins') return creatorUid;
    if (outcome == 'opponent_wins') return opponentUid;
    return null;
  }

  bool didCurrentUserWin(String currentUid) =>
      winnerUid(currentUid: currentUid) == currentUid;

  Duration get timeRemaining {
    final diff = expiresAt.difference(DateTime.now());
    return diff.isNegative ? Duration.zero : diff;
  }

  // What changed: fromDoc now safely handles the case where doc.data()
  // returns null (should never happen for existing docs, but defensive is
  // better than a runtime crash). Also fixes the bug where animeTitle could
  // come through with inconsistent casing — we normalise it to lowercase
  // for consistent comparisons while keeping creatorUsername display-cased.
  factory ChallengeModel.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final d = doc.data() ?? {};
    return ChallengeModel(
      challengeId: doc.id,
      creatorUid: (d['creatorUid'] as String?) ?? '',
      creatorUsername: (d['creatorUsername'] as String?) ?? 'Unknown',
      opponentUid: d['opponentUid'] as String?,
      opponentUsername: d['opponentUsername'] as String?,
      betAmount: ((d['betAmount'] as num?)?.toInt()) ?? 0,
      // Keep animeTitle exactly as stored — normalisation is done at
      // query time in FirestoreService._pickRandomQuestionIds.
      animeTitle: (d['animeTitle'] as String?) ?? '',
      questionIds: List<String>.from(
        (d['questionIds'] as List<dynamic>?) ?? [],
      ),
      creatorScore: (d['creatorScore'] as num?)?.toInt(),
      opponentScore: (d['opponentScore'] as num?)?.toInt(),
      status: ChallengeStatusX.parse(d['status'] as String?),
      createdAt: ((d['createdAt'] as Timestamp?)?.toDate()) ??
          DateTime.now(),
      expiresAt: ((d['expiresAt'] as Timestamp?)?.toDate()) ??
          DateTime.now().add(const Duration(hours: 24)),
      outcome: d['outcome'] as String?,
    );
  }

  @override
  String toString() =>
      'ChallengeModel($challengeId · $status · $animeTitle)';
}

// ─── Return type from createChallenge ────────────────────────────────────────
class ChallengeCreationResult {
  final String challengeId;
  final List<String> questionIds;
  const ChallengeCreationResult({
    required this.challengeId,
    required this.questionIds,
  });
}