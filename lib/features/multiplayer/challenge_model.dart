import 'package:cloud_firestore/cloud_firestore.dart';

// ─── Status enum ──────────────────────────────────────────────────────────────
enum ChallengeStatus { waiting, opponentJoined, completed, expired }

extension ChallengeStatusX on ChallengeStatus {
  static ChallengeStatus parse(String? s) {
    switch (s) {
      case 'opponent_joined': return ChallengeStatus.opponentJoined;
      case 'completed':       return ChallengeStatus.completed;
      case 'expired':         return ChallengeStatus.expired;
      default:                return ChallengeStatus.waiting;
    }
  }
}

// ─── Model ────────────────────────────────────────────────────────────────────
class ChallengeModel {
  final String          challengeId;
  final String          creatorUid;
  final String          creatorUsername;
  final String?         opponentUid;
  final String?         opponentUsername;
  final int             betAmount;
  final String          animeTitle;
  final List<String>    questionIds;
  final int?            creatorScore;
  final int?            opponentScore;
  final ChallengeStatus status;
  final DateTime        createdAt;
  final DateTime        expiresAt;
  final String?         outcome; // "creator_wins" | "opponent_wins" | "draw"

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
  bool get isExpired   => DateTime.now().isAfter(expiresAt) &&
                          status != ChallengeStatus.completed;
  bool get isCompleted => status == ChallengeStatus.completed;
  bool get isDraw      => outcome == 'draw';

  String? winnerUid({required String currentUid}) {
    if (outcome == null) return null;
    if (outcome == 'draw') return null;
    if (outcome == 'creator_wins')  return creatorUid;
    if (outcome == 'opponent_wins') return opponentUid;
    return null;
  }

  bool didCurrentUserWin(String currentUid) =>
      winnerUid(currentUid: currentUid) == currentUid;

  Duration get timeRemaining {
    final diff = expiresAt.difference(DateTime.now());
    return diff.isNegative ? Duration.zero : diff;
  }

  factory ChallengeModel.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final d = doc.data()!;
    return ChallengeModel(
      challengeId:      doc.id,
      creatorUid:       (d['creatorUid']       as String?) ?? '',
      creatorUsername:  (d['creatorUsername']  as String?) ?? 'Unknown',
      opponentUid:       d['opponentUid']      as String?,
      opponentUsername:  d['opponentUsername'] as String?,
      betAmount:        ((d['betAmount']       as num?)?.toInt()) ?? 0,
      animeTitle:       (d['animeTitle']       as String?) ?? '',
      questionIds:      List<String>.from(
          (d['questionIds'] as List<dynamic>?) ?? []),
      creatorScore:     (d['creatorScore']     as num?)?.toInt(),
      opponentScore:    (d['opponentScore']    as num?)?.toInt(),
      status:           ChallengeStatusX.parse(d['status'] as String?),
      createdAt:        ((d['createdAt']       as Timestamp?)?.toDate()) ??
                        DateTime.now(),
      expiresAt:        ((d['expiresAt']       as Timestamp?)?.toDate()) ??
                        DateTime.now().add(const Duration(hours: 24)),
      outcome:           d['outcome']          as String?,
    );
  }
}

// ─── Return type from createChallenge ────────────────────────────────────────
class ChallengeCreationResult {
  final String       challengeId;
  final List<String> questionIds;
  const ChallengeCreationResult({
    required this.challengeId,
    required this.questionIds,
  });
}