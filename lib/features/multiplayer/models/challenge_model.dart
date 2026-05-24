// lib/features/multiplayer/models/challenge_model.dart

import 'package:cloud_firestore/cloud_firestore.dart';

// ─── Enums ────────────────────────────────────────────────────────────────────

enum ChallengeStatus { waiting, inProgress, completed, expired }

enum ChallengeOutcome { creatorWins, opponentWins, draw }

// ─── Parsing helpers (top-level, exported for use in FirestoreService) ────────

ChallengeStatus parseChallengeStatus(String? s) => switch (s) {
      'in_progress' => ChallengeStatus.inProgress,
      'completed'   => ChallengeStatus.completed,
      'expired'     => ChallengeStatus.expired,
      _             => ChallengeStatus.waiting,
    };

ChallengeOutcome? parseChallengeOutcome(String? s) => switch (s) {
      'creator_wins'  => ChallengeOutcome.creatorWins,
      'opponent_wins' => ChallengeOutcome.opponentWins,
      'draw'          => ChallengeOutcome.draw,
      _               => null,
    };

// ─── Extensions: Firestore string representation ─────────────────────────────

extension ChallengeStatusX on ChallengeStatus {
  String get raw => switch (this) {
        ChallengeStatus.waiting    => 'waiting',
        ChallengeStatus.inProgress => 'in_progress',
        ChallengeStatus.completed  => 'completed',
        ChallengeStatus.expired    => 'expired',
      };
}

extension ChallengeOutcomeX on ChallengeOutcome {
  String get raw => switch (this) {
        ChallengeOutcome.creatorWins  => 'creator_wins',
        ChallengeOutcome.opponentWins => 'opponent_wins',
        ChallengeOutcome.draw         => 'draw',
      };
}

// ─── Model ────────────────────────────────────────────────────────────────────

class ChallengeModel {
  /// Firestore auto-generated document ID.
  final String challengeId;

  /// Human-readable 6-character share code, e.g. "KEN24X".
  final String code;

  final String  creatorUid;
  final String  creatorUsername;
  final String? opponentUid;
  final String? opponentUsername;
  final int     betAmount;
  final String  animeTitle;

  /// Ordered list of Firestore question document IDs (length == 10).
  final List<String> questionIds;

  final int?             creatorScore;
  final int?             opponentScore;
  final ChallengeStatus  status;
  final DateTime         createdAt;
  final DateTime         expiresAt;
  final ChallengeOutcome? outcome;

  const ChallengeModel({
    required this.challengeId,
    required this.code,
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

  // ── Firestore deserialisation ───────────────────────────────────────────────

  factory ChallengeModel.fromDoc(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    return ChallengeModel(
      challengeId:      doc.id,
      code:             (d['code']            as String?) ?? '',
      creatorUid:       (d['creatorUid']       as String?) ?? '',
      creatorUsername:  (d['creatorUsername']  as String?) ?? 'Challenger',
      opponentUid:      d['opponentUid']       as String?,
      opponentUsername: d['opponentUsername']  as String?,
      betAmount:        ((d['betAmount']       as num?)?.toInt()) ?? 0,
      animeTitle:       (d['animeTitle']       as String?) ?? '',
      questionIds:      List<String>.from((d['questionIds'] as List?) ?? []),
      creatorScore:     (d['creatorScore']     as num?)?.toInt(),
      opponentScore:    (d['opponentScore']    as num?)?.toInt(),
      status:           parseChallengeStatus(d['status'] as String?),
      createdAt:        (d['createdAt']  as Timestamp?)?.toDate() ?? DateTime.now(),
      expiresAt:        (d['expiresAt']  as Timestamp?)?.toDate() ??
                        DateTime.now().add(const Duration(hours: 24)),
      outcome:          parseChallengeOutcome(d['outcome'] as String?),
    );
  }

  // ── Convenience getters ─────────────────────────────────────────────────────

  bool get isExpired         => DateTime.now().isAfter(expiresAt);
  bool get hasOpponent       => opponentUid != null;
  bool get creatorHasPlayed  => creatorScore != null;
  bool get opponentHasPlayed => opponentScore != null;
  bool get isComplete        => status == ChallengeStatus.completed;
  bool get isWaiting         => status == ChallengeStatus.waiting;
  bool get isInProgress      => status == ChallengeStatus.inProgress;
  bool get bothHavePlayed    => creatorHasPlayed && opponentHasPlayed;

  /// Remaining time before expiry as a human-readable string.
  String get expiryLabel {
    final diff = expiresAt.difference(DateTime.now());
    if (diff.isNegative) return 'Expired';
    if (diff.inHours >= 1) return 'Expires in ${diff.inHours}h';
    return 'Expires in ${diff.inMinutes}m';
  }
}