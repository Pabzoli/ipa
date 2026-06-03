import 'package:cloud_firestore/cloud_firestore.dart';

// ─── Status enum ──────────────────────────────────────────────────────────────
enum ChallengeStatus {
  waiting,
  opponentJoined,
  creatorSubmitted,
  opponentSubmitted,
  completed,
  expired,
  expiredRefunded,
  ghost,
}

extension ChallengeStatusX on ChallengeStatus {
  static ChallengeStatus parse(String? s) => switch (s) {
        'opponent_joined'    => ChallengeStatus.opponentJoined,
        'creator_submitted'  => ChallengeStatus.creatorSubmitted,
        'opponent_submitted' => ChallengeStatus.opponentSubmitted,
        'completed'          => ChallengeStatus.completed,
        'expired'            => ChallengeStatus.expired,
        'expired_refunded'   => ChallengeStatus.expiredRefunded,
        'ghost'              => ChallengeStatus.ghost,
        _                    => ChallengeStatus.waiting,
      };
}

// ─── Model ────────────────────────────────────────────────────────────────────
class ChallengeModel {
  final String challengeId;
  final String creatorUid;
  final String creatorUsername;
  final String? opponentUid;
  final String? opponentUsername;
  final int stakeAmount;
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
    required this.stakeAmount,
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
  bool get isExpired =>
      status == ChallengeStatus.expired ||
      status == ChallengeStatus.expiredRefunded ||
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

  // ── Payout helpers ───────────────────────────────────────────────────────
  // These mirror the formulas in resolveChallengeOutcome (index.js) and are
  // used by StakeScreen (preview) and ChallengeResultPage (display).
  //
  //   Win:  own stake returned + 80% of opponent's stake
  //   Draw: own stake returned minus 5% house fee
  //   Lose: 0  (stake already deducted at join time)

  /// Total AC received by the winner (own stake + 80% of loser's stake).
  static int payoutWin(int stake) => stake + (stake * 0.8).floor();

  /// AC returned to each player on a draw (stake minus 5% fee).
  static int payoutDraw(int stake) => stake - (stake * 0.05).floor();

  /// Loser receives nothing — their stake was deducted at challenge join.
  static int payoutLose(int stake) => 0;

  /// House fee retained on a win outcome (20% of the loser's stake).
  static int houseFeeWin(int stake) => (stake * 0.2).floor();

  /// House fee retained on a draw outcome (5% from each player).
  static int houseFeeDraw(int stake) => (stake * 0.05).floor() * 2;

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
      stakeAmount: ((d['stakeAmount'] as num?)?.toInt()) ?? 0,
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